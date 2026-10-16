import Foundation

/// Which messages a message list shows (used for export, rules and tests).
public enum MailFilter: Hashable, Sendable {
    case inbox
    case category(MailCategory)
    case needsReply
    case flagged
    case sent
    case archive
    case all
    case space(UUID)
    case thread(String)
}

/// A message as parsed from the server, ready to be stored.
public struct IncomingMessage: Sendable {
    public var accountID: UUID
    public var folder: String
    public var folderRole: FolderRole
    public var uid: UInt32
    public var flags: Set<String>
    public var parsed: ParsedMail
    public var rawPath: String
    /// Found in the archive (Gmail's All Mail): stored as done, and skipped if the account already has it.
    public var archived = false
    /// Gmail's conversation id, a second way to find the conversation besides the headers.
    public var gmailThread = ""

    public init(accountID: UUID, folder: String, folderRole: FolderRole, uid: UInt32, flags: Set<String>,
                parsed: ParsedMail, rawPath: String, archived: Bool = false, gmailThread: String = "") {
        self.accountID = accountID
        self.folder = folder
        self.folderRole = folderRole
        self.uid = uid
        self.flags = flags
        self.parsed = parsed
        self.rawPath = rawPath
        self.archived = archived
        self.gmailThread = gmailThread
    }
}

/// Local message database. All access is serialized with a lock, so it can be used from any task.
public final class MailStore: @unchecked Sendable {
    private let db: SQLiteDB
    private let lock = NSLock()

    public init(url: URL = Paths.database) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        db = try SQLiteDB(path: url.path)
        try migrate()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY,
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            folder_role TEXT NOT NULL,
            uid INTEGER NOT NULL,
            message_id TEXT NOT NULL DEFAULT '',
            in_reply_to TEXT NOT NULL DEFAULT '',
            refs TEXT NOT NULL DEFAULT '',
            subject TEXT NOT NULL DEFAULT '',
            from_json TEXT NOT NULL DEFAULT '{}',
            to_json TEXT NOT NULL DEFAULT '[]',
            cc_json TEXT NOT NULL DEFAULT '[]',
            reply_to_json TEXT NOT NULL DEFAULT '[]',
            search_text TEXT NOT NULL DEFAULT '',
            date REAL NOT NULL,
            snippet TEXT NOT NULL DEFAULT '',
            body_text TEXT NOT NULL DEFAULT '',
            body_html TEXT,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            is_bulk INTEGER NOT NULL DEFAULT 0,
            is_read INTEGER NOT NULL DEFAULT 0,
            is_flagged INTEGER NOT NULL DEFAULT 0,
            is_archived INTEGER NOT NULL DEFAULT 0,
            category TEXT,
            category_source TEXT,
            summary TEXT,
            needs_reply INTEGER NOT NULL DEFAULT 0,
            ai_done INTEGER NOT NULL DEFAULT 0,
            rules_done INTEGER NOT NULL DEFAULT 0,
            raw_path TEXT NOT NULL DEFAULT '',
            UNIQUE(account_id, folder, uid)
        );
        CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC);
        CREATE TABLE IF NOT EXISTS message_spaces(
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            space_id TEXT NOT NULL,
            PRIMARY KEY(message_id, space_id)
        );
        CREATE TABLE IF NOT EXISTS sync_state(
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid_validity INTEGER NOT NULL,
            PRIMARY KEY(account_id, folder)
        );
        CREATE TABLE IF NOT EXISTS threads(
            thread_id TEXT PRIMARY KEY,
            space_id TEXT,
            snoozed_until REAL,
            waiting_dismissed INTEGER NOT NULL DEFAULT 0
        );
        """)
        let columns = try db.query("PRAGMA table_info(messages)").compactMap { $0.string("name") }
        if !columns.contains("topic") {
            try db.exec("ALTER TABLE messages ADD COLUMN topic TEXT")
        }
        if !columns.contains("ask") {
            try db.exec("ALTER TABLE messages ADD COLUMN ask TEXT")
            // "Reply" used to mean any personal mail; open ones get asked again what the user is asked to do.
            try db.exec("UPDATE messages SET ai_done=0 WHERE needs_reply=1 AND folder_role='inbox' AND is_archived=0")
        }
        // Mail the model summarized before it also wrote a keyword gets sorted again (the model always writes one now).
        try db.exec("UPDATE messages SET ai_done=0 WHERE ai_done=1 AND summary IS NOT NULL AND topic IS NULL")
        if !columns.contains("thread_id") {
            try db.exec("ALTER TABLE messages ADD COLUMN thread_id TEXT NOT NULL DEFAULT ''")
            try db.exec("ALTER TABLE messages ADD COLUMN norm_subject TEXT NOT NULL DEFAULT ''")
        }
        try db.exec("""
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id);
        CREATE INDEX IF NOT EXISTS messages_message_id ON messages(message_id);
        CREATE INDEX IF NOT EXISTS messages_in_reply_to ON messages(in_reply_to);
        CREATE INDEX IF NOT EXISTS messages_norm_subject ON messages(norm_subject);
        """)
        let threadColumns = try db.query("PRAGMA table_info(threads)").compactMap { $0.string("name") }
        if !threadColumns.contains("todo_since") {
            try db.exec("ALTER TABLE threads ADD COLUMN todo_since REAL")
            try db.exec("ALTER TABLE threads ADD COLUMN todo_note TEXT")
        }
        if !threadColumns.contains("project_id") {
            try db.exec("ALTER TABLE threads ADD COLUMN project_id TEXT")
        }
        // How a conversation got its court: "you", "rule", "infos", "suggestion", "sorting", "topic" (moved with a topic).
        if !threadColumns.contains("place") {
            try db.exec("ALTER TABLE threads ADD COLUMN place TEXT")
        }
        // A topic (matter) holds one or more conversations; a conversation without one is a topic of its own.
        if !threadColumns.contains("matter_id") {
            try db.exec("ALTER TABLE threads ADD COLUMN matter_id TEXT")
        }
        try db.exec("CREATE TABLE IF NOT EXISTS matters(id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', created REAL)")
        try db.exec("CREATE INDEX IF NOT EXISTS threads_matter ON threads(matter_id)")
        // Gmail's conversation id and the reference numbers a mail mentions ("075920"), for finding conversations
        // that belong together; how far the archive folder has been looked through.
        if !columns.contains("bcc_json") {
            try db.exec("ALTER TABLE messages ADD COLUMN bcc_json TEXT NOT NULL DEFAULT '[]'")
        }
        if !columns.contains("gm_thread") {
            try db.exec("ALTER TABLE messages ADD COLUMN gm_thread TEXT NOT NULL DEFAULT ''")
            try db.exec("ALTER TABLE messages ADD COLUMN ref_tokens TEXT NOT NULL DEFAULT ''")
        }
        try db.exec("CREATE INDEX IF NOT EXISTS messages_gm_thread ON messages(gm_thread)")
        let syncColumns = try db.query("PRAGMA table_info(sync_state)").compactMap { $0.string("name") }
        if !syncColumns.contains("seen_uid") {
            try db.exec("ALTER TABLE sync_state ADD COLUMN seen_uid INTEGER NOT NULL DEFAULT 0")
        }
        try backfillThreads()
        if (try db.query("PRAGMA user_version").first?.int("user_version") ?? 0) < 1 {
            try backfillReferences()
            try db.exec("PRAGMA user_version = 1")
        }
        if (try db.query("PRAGMA user_version").first?.int("user_version") ?? 0) < 2 {
            try groupRepeatedSubjects()
            try db.exec("PRAGMA user_version = 2")
        }
        if (try db.query("PRAGMA user_version").first?.int("user_version") ?? 0) < 3 {
            try backfillBcc()
            try db.exec("PRAGMA user_version = 3")
        }
        if (try db.query("PRAGMA user_version").first?.int("user_version") ?? 0) < 4 {
            try recountAttachments()
            try db.exec("PRAGMA user_version = 4")
        }
        // Tasks: things to do outside mail, which a reply does not finish (see `MailTask`).
        try db.exec("""
        CREATE TABLE IF NOT EXISTS tasks(
            id INTEGER PRIMARY KEY,
            thread_id TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL,
            message_id INTEGER,
            created REAL NOT NULL,
            done_at REAL,
            done_suggested_by INTEGER
        );
        CREATE INDEX IF NOT EXISTS tasks_thread ON tasks(thread_id);
        """)
        if (try db.query("PRAGMA user_version").first?.int("user_version") ?? 0) < 5 {
            // To-dos become tasks the user set; a sent mail no longer clears them.
            for row in try db.query("SELECT thread_id, todo_since, todo_note FROM threads WHERE todo_since IS NOT NULL") {
                try db.run("INSERT INTO tasks(thread_id, text, source, created) VALUES(?,?,?,?)",
                           [row.string("thread_id"), row.string("todo_note") ?? "", MailTask.Source.manual.rawValue, row.double("todo_since")])
            }
            try db.exec("UPDATE threads SET todo_since=NULL, todo_note=NULL")
            // Recent open mail and the user's recent replies are read again, for the tasks in them.
            let month = Date().timeIntervalSince1970 - 30 * 86400
            try db.run("UPDATE messages SET ai_done=0 WHERE folder_role='inbox' AND is_archived=0 AND date > ? AND IFNULL(category,'') IN ('primary','updates','')", [month])
            try db.run("UPDATE messages SET ai_done=0 WHERE folder_role='sent' AND date > ?", [month])
            try db.exec("PRAGMA user_version = 5")
        }
        if (try db.query("PRAGMA user_version").first?.int("user_version") ?? 0) < 6 {
            // Soft line breaks of format=flowed mail are joined now; conversations with the same subject and
            // people within two weeks (people) become one topic.
            try reparseFlowed()
            try groupRepeatedSubjects()
            try db.exec("PRAGMA user_version = 6")
        }
    }

    /// Once: mail sent as format=flowed gets its text read again, with the soft line breaks joined.
    private func reparseFlowed() throws {
        for row in try db.query("SELECT id, raw_path FROM messages WHERE raw_path != ''") {
            guard let path = row.string("raw_path"), let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = String(decoding: handle.readData(ofLength: 32_768), as: UTF8.self).lowercased()
            try? handle.close()
            guard head.contains("format=flowed"), let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            let parsed = MIME.parse(raw)
            guard let text = parsed.text else { continue }
            try db.run("UPDATE messages SET body_text=? WHERE id=?", [text, row.int("id")])
        }
    }

    /// Once: conversations that started fresh with the same subject and the same people within three days of each
    /// other (sent twice, or followed up without "Re:") become one topic. New mail joins the conversation itself
    /// (`threadID`, step 5); existing conversations are put together as a topic, so courts and to-dos stay as they
    /// are. Conversations already in a topic are left where they are.
    private func groupRepeatedSubjects() throws {
        let own = try ownAddresses()
        let rows = try db.query("""
        SELECT m.thread_id, m.subject, m.norm_subject, m.date, m.from_json, m.to_json, m.cc_json, m.category, t.matter_id, t.space_id
        FROM messages m LEFT JOIN threads t ON t.thread_id = m.thread_id
        WHERE m.is_bulk=0 AND IFNULL(m.category,'') NOT IN ('newsletters','spam') AND length(m.norm_subject) >= 3
            AND m.thread_id != '' AND m.date = (SELECT MIN(f.date) FROM messages f WHERE f.thread_id = m.thread_id)
        ORDER BY m.date
        """)
        // Per subject, oldest first: a conversation joins the newest group it fits (same people, at most three days
        // after that group's last one), else starts its own.
        var bySubject: [String: [[Row]]] = [:]
        var seen = Set<String>()
        for row in rows {
            guard let thread = row.string("thread_id"), seen.insert(thread).inserted else { continue }
            let subject = row.string("norm_subject") ?? ""
            let people = Self.addresses(row).subtracting(own)
            let mine = own.contains(Self.sender(row))
            let personal = row.string("category") != "updates"
                && Heuristics.category(from: EmailAddress(name: "", address: Self.sender(row)), isBulk: false, subject: subject) == .primary
            let window = personal ? Self.sameSubjectWindow : Self.sameSubjectWindowCompany
            var groups = bySubject[subject] ?? []
            if let index = groups.lastIndex(where: { group in
                guard let last = group.last else { return false }
                return (row.double("date") ?? 0) - (last.double("date") ?? 0) <= window
                    && group.contains { Self.samePeople(people, mine, Self.addresses($0).subtracting(own), own.contains(Self.sender($0))) }
            }) {
                groups[index].append(row)
            } else {
                groups.append([row])
            }
            bySubject[subject] = groups
        }
        for groups in bySubject.values {
            for group in groups { try joinAsTopic(group) }
        }
    }

    private func joinAsTopic(_ cluster: [Row]) throws {
        guard cluster.count >= 2, let oldest = cluster.first else { return }
        let matter: String
        if let existing = cluster.compactMap({ $0.string("matter_id") }).first {
            matter = existing
        } else {
            matter = UUID().uuidString
            try db.run("INSERT OR IGNORE INTO matters(id, title, created) VALUES(?,?,?)",
                       [matter, Threading.normalizedSubject(oldest.string("subject") ?? ""), Date().timeIntervalSince1970])
        }
        let space = cluster.compactMap { $0.string("space_id") }.first
        for row in cluster {
            guard let thread = row.string("thread_id") else { continue }
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET matter_id=? WHERE thread_id=? AND matter_id IS NULL", [matter, thread])
            if let space { try db.run("UPDATE threads SET space_id=? WHERE thread_id=? AND space_id IS NULL", [space, thread]) }
        }
    }

    /// Once: pictures the text shows itself no longer count as attachments (see `MIME.parse`).
    private func recountAttachments() throws {
        let encoder = JSONEncoder()
        for row in try db.query("SELECT id, raw_path FROM messages WHERE attachments_json != '[]' AND raw_path != ''") {
            guard let path = row.string("raw_path"), let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            let attachments = MIME.parse(raw).attachments.filter { !$0.isInline }.map {
                AttachmentInfo(filename: $0.filename, mimeType: $0.mimeType, size: $0.data.count)
            }
            guard let json = try? encoder.encode(attachments) else { continue }
            try db.run("UPDATE messages SET attachments_json=? WHERE id=?", [String(decoding: json, as: UTF8.self), row.int("id")])
        }
    }

    /// Once: Bcc recipients of sent mail, read from the stored original (only the sender's copy has them).
    private func backfillBcc() throws {
        let encoder = JSONEncoder()
        for row in try db.query("SELECT id, raw_path FROM messages WHERE folder_role='sent' AND raw_path != ''") {
            guard let path = row.string("raw_path"), let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            let bcc = MIME.parse(raw).bcc
            guard !bcc.isEmpty, let json = try? encoder.encode(bcc) else { continue }
            try db.run("UPDATE messages SET bcc_json=? WHERE id=?", [String(decoding: json, as: UTF8.self), row.int("id")])
        }
    }

    /// Once: subjects are compared without gateway tags like "[External]", and every mail gets its reference numbers.
    private func backfillReferences() throws {
        for row in try db.query("SELECT id, subject, body_text, body_html FROM messages") {
            let subject = row.string("subject") ?? ""
            try db.run("UPDATE messages SET norm_subject=?, ref_tokens=? WHERE id=?", [
                Threading.normalizedSubject(subject).lowercased(),
                Self.referenceTokens(subject: subject, text: row.string("body_text") ?? "", html: row.string("body_html")),
                row.int("id"),
            ])
        }
    }

    /// Case, order and invoice numbers in the subject and in what the sender wrote (not the quote, not the signature).
    static func referenceTokens(subject: String, text: String, html: String?) -> String {
        let own = MailSegmenter.segment(text: text, html: html, subject: subject).text
        var seen = Set<String>()
        return MatterSuggestions.references(subject + "\n" + own).filter { seen.insert($0).inserted }.joined(separator: " ")
    }

    /// Databases from before conversations existed get their thread ids and space membership computed once.
    private func backfillThreads() throws {
        let rows = try db.query("""
        SELECT id, message_id, in_reply_to, refs, subject, from_json, to_json, cc_json, date, account_id, folder, uid
        FROM messages WHERE thread_id='' ORDER BY date ASC
        """)
        guard !rows.isEmpty else { return }
        let decoder = JSONDecoder()
        for row in rows {
            let people = ["from_json", "to_json", "cc_json"].flatMap { key -> [EmailAddress] in
                guard let json = row.string(key), let data = json.data(using: .utf8) else { return [] }
                if let list = try? decoder.decode([EmailAddress].self, from: data) { return list }
                if let one = try? decoder.decode(EmailAddress.self, from: data) { return [one] }
                return []
            }
            let subject = row.string("subject") ?? ""
            let fallback = "\(row.string("account_id") ?? "")/\(row.string("folder") ?? "")/\(row.int("uid") ?? 0)"
            let thread = try threadID(messageID: row.string("message_id") ?? "", inReplyTo: row.string("in_reply_to") ?? "",
                                      references: row.string("refs") ?? "", subject: subject, participants: people,
                                      date: Date(timeIntervalSince1970: row.double("date") ?? 0), fallback: fallback)
            try db.run("UPDATE messages SET thread_id=?, norm_subject=? WHERE id=?",
                       [thread, Threading.normalizedSubject(subject).lowercased(), row.int("id")])
        }
        // Space membership used to be per mail; a conversation now has one space.
        for row in try db.query("""
        SELECT m.thread_id, s.space_id FROM message_spaces s JOIN messages m ON m.id = s.message_id
        GROUP BY m.thread_id ORDER BY MIN(m.date)
        """) {
            try db.run("INSERT OR IGNORE INTO threads(thread_id, space_id) VALUES(?,?)", [row.string("thread_id"), row.string("space_id")])
            try db.run("UPDATE threads SET space_id=? WHERE thread_id=? AND space_id IS NULL", [row.string("space_id"), row.string("thread_id")])
        }
        try db.run("DELETE FROM message_spaces")
    }

    // MARK: Threading

    /// Finds the conversation a message belongs to. Must be called with the lock held.
    private func threadID(messageID: String, inReplyTo: String, references: String, subject: String,
                          participants: [EmailAddress], date: Date, fallback: String, gmailThread: String = "",
                          isBulk: Bool = false) throws -> String {
        let referenced = Threading.referencedIDs(references: references, inReplyTo: inReplyTo)
        // 1. A message we already know is named in the headers: join its conversation.
        if !referenced.isEmpty {
            let marks = Array(repeating: "?", count: referenced.count).joined(separator: ",")
            if let known = try db.query("SELECT thread_id FROM messages WHERE message_id IN (\(marks)) OR thread_id IN (\(marks)) LIMIT 1",
                                        referenced + referenced).first?.string("thread_id"), !known.isEmpty {
                return known
            }
        }
        // 2. A reply to this message arrived earlier (sync fetches newest first): adopt its conversation.
        if !messageID.isEmpty,
           let child = try db.query("SELECT thread_id FROM messages WHERE in_reply_to=? OR refs LIKE ? LIMIT 1",
                                    [messageID, "%\(messageID)%"]).first?.string("thread_id"), !child.isEmpty {
            return child
        }
        // 2b. Gmail put it in a conversation we already have (it also groups mails whose headers got lost).
        if !gmailThread.isEmpty,
           let known = try db.query("SELECT thread_id FROM messages WHERE gm_thread=? AND thread_id != '' LIMIT 1", [gmailThread])
            .first?.string("thread_id") {
            return known
        }
        // 3. A mail with the same subject to the same people shortly before or after (sent twice, or followed up
        //    without "Re:"): the same conversation. Two weeks for mail from people, three days for companies and
        //    machines, which repeat subjects all the time. Not for mass mail.
        let normalized = Threading.normalizedSubject(subject).lowercased()
        let personal = !isBulk && Heuristics.category(from: participants.first, isBulk: false, subject: subject) == .primary
        if !isBulk, normalized.count >= 3 {
            let own = try ownAddresses()
            let people = Set(participants.map { $0.address.lowercased() }).subtracting(own)
            let mine = participants.first.map { own.contains($0.address.lowercased()) } ?? false
            let window = personal ? Self.sameSubjectWindow : Self.sameSubjectWindowCompany
            let candidates = try db.query("""
            SELECT thread_id, from_json, to_json, cc_json FROM messages
            WHERE norm_subject=? AND is_bulk=0 AND IFNULL(category,'') NOT IN ('newsletters','spam') AND thread_id != ''
                AND ABS(date - ?) < ? ORDER BY ABS(date - ?) LIMIT 20
            """, [normalized, date.timeIntervalSince1970, window, date.timeIntervalSince1970])
            for candidate in candidates where Self.samePeople(people, mine, Self.addresses(candidate).subtracting(own),
                                                              own.contains(Self.sender(candidate))) {
                if let thread = candidate.string("thread_id") { return thread }
            }
        }
        // 4. Replies without headers (some web mailers), or whose parent we never got: same subject and a shared
        //    person within half a year, or six weeks when a parent is named.
        if Threading.isReplySubject(subject) {
            let addresses = Set(participants.map { $0.address.lowercased() })
            let window: TimeInterval = (referenced.isEmpty ? 180.0 : 45.0) * 86400
            let candidates = try db.query("""
            SELECT thread_id, from_json, to_json, cc_json FROM messages
            WHERE norm_subject=? AND ABS(date - ?) < ? ORDER BY ABS(date - ?) LIMIT 20
            """, [normalized, date.timeIntervalSince1970, window, date.timeIntervalSince1970])
            for candidate in candidates {
                let text = [candidate.string("from_json"), candidate.string("to_json"), candidate.string("cc_json")].compactMap { $0 }.joined().lowercased()
                if addresses.contains(where: { !$0.isEmpty && text.contains($0) }), let thread = candidate.string("thread_id"), !thread.isEmpty {
                    return thread
                }
            }
        }
        // 5. Well-formed chains all name the same root: use it, so order of arrival does not matter.
        if let root = referenced.first { return root }
        return messageID.isEmpty ? "local:" + StableHash.hex(fallback, length: 16) : messageID
    }

    /// How far apart two new mails with the same subject and people may be to count as one conversation.
    static let sameSubjectWindow: TimeInterval = 14 * 86400
    static let sameSubjectWindowCompany: TimeInterval = 3 * 86400

    /// The same people besides the user, or one of two mails from the user has no visible recipients (only Bcc).
    static func samePeople(_ a: Set<String>, _ aMine: Bool, _ b: Set<String>, _ bMine: Bool) -> Bool {
        a == b || aMine && bMine && (a.isEmpty || b.isEmpty)
    }

    static func sender(_ row: Row) -> String {
        guard let json = row.string("from_json"), let data = json.data(using: .utf8),
              let from = try? JSONDecoder().decode(EmailAddress.self, from: data) else { return "" }
        return from.address.lowercased()
    }

    /// Addresses the app knows to be the user's (accounts and aliases from the config), set by the app.
    public var knownOwnAddresses: Set<String> = []

    /// The user's own addresses: whatever their sent mail came from, plus what the app told us.
    func ownAddresses() throws -> Set<String> {
        Set(try db.query("SELECT DISTINCT lower(json_extract(from_json, '$.address')) AS a FROM messages WHERE folder_role='sent'")
            .compactMap { $0.string("a") }).union(knownOwnAddresses)
    }

    /// Everyone on a stored mail, lowercased.
    static func addresses(_ row: Row) -> Set<String> {
        let decoder = JSONDecoder()
        return Set(["from_json", "to_json", "cc_json"].flatMap { key -> [EmailAddress] in
            guard let json = row.string(key), let data = json.data(using: .utf8) else { return [] }
            if let list = try? decoder.decode([EmailAddress].self, from: data) { return list }
            if let one = try? decoder.decode(EmailAddress.self, from: data) { return [one] }
            return []
        }.map { $0.address.lowercased() }.filter { !$0.isEmpty })
    }

    // MARK: Writing

    /// Inserts a message (ignores duplicates). Returns the row id of new messages.
    @discardableResult
    public func insert(_ incoming: IncomingMessage) throws -> Int64? {
        let mail = incoming.parsed
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) -> String {
            String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? ""
        }
        let text = mail.text ?? mail.html.map(HTMLText.plainText) ?? ""
        let people = [mail.from].compactMap { $0 } + mail.to + mail.cc
        let addresses = people.map(\.formatted).joined(separator: " ")
        let attachments = mail.attachments.filter { !$0.isInline }.map {
            AttachmentInfo(filename: $0.filename, mimeType: $0.mimeType, size: $0.data.count)
        }
        let search = [mail.subject, addresses, text, attachments.map(\.filename).joined(separator: " ")].joined(separator: "\n").lowercased()
        let category = incoming.folderRole == .inbox
            ? Heuristics.category(from: mail.from, isBulk: mail.isBulk, subject: mail.subject) : nil
        let references = Self.referenceTokens(subject: mail.subject, text: mail.text ?? "", html: mail.html)
        return try locked {
            let exists = try db.query("SELECT id FROM messages WHERE account_id=? AND folder=? AND uid=?",
                                      [incoming.accountID.uuidString, incoming.folder, incoming.uid]).first != nil
            if exists { return nil }
            if incoming.archived, !mail.messageID.isEmpty,
               try db.query("SELECT 1 FROM messages WHERE account_id=? AND message_id=? LIMIT 1",
                            [incoming.accountID.uuidString, mail.messageID]).first != nil {
                return nil
            }
            // A mail that was done (archived) came back to the inbox: move the row we have instead of adding it twice.
            if incoming.folderRole == .inbox, !incoming.archived, !mail.messageID.isEmpty,
               let row = try db.query("""
               SELECT id FROM messages WHERE account_id=? AND message_id=? AND folder_role='inbox' AND is_archived=1 LIMIT 1
               """, [incoming.accountID.uuidString, mail.messageID]).first, let id = row.int("id") {
                try db.run("UPDATE OR REPLACE messages SET folder=?, uid=?, is_archived=0, raw_path=? WHERE id=?",
                           [incoming.folder, incoming.uid, incoming.rawPath, id])
                return nil
            }
            let fallback = "\(incoming.accountID.uuidString)/\(incoming.folder)/\(incoming.uid)"
            let thread = try threadID(messageID: mail.messageID, inReplyTo: mail.inReplyTo, references: mail.references,
                                      subject: mail.subject, participants: people, date: mail.date, fallback: fallback,
                                      gmailThread: incoming.gmailThread, isBulk: mail.isBulk || category == .newsletters)
            try db.run("""
            INSERT OR IGNORE INTO messages(account_id, folder, folder_role, uid, message_id, in_reply_to, refs,
                subject, from_json, to_json, cc_json, reply_to_json, search_text, date, snippet, body_text, body_html,
                attachments_json, is_bulk, is_read, is_flagged, raw_path, category, category_source, thread_id, norm_subject,
                is_archived, gm_thread, ref_tokens, bcc_json)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                incoming.accountID.uuidString, incoming.folder, incoming.folderRole.rawValue, incoming.uid,
                mail.messageID, mail.inReplyTo, mail.references, mail.subject,
                json(mail.from ?? EmailAddress(address: "")), json(mail.to), json(mail.cc), json(mail.replyTo),
                search, mail.date, Snippet.make(text), text, mail.html, json(attachments), mail.isBulk,
                incoming.flags.contains("\\Seen") || incoming.folderRole == .sent || incoming.archived,
                incoming.flags.contains("\\Flagged"), incoming.rawPath,
                category?.rawValue, category == nil ? nil : ClassificationSource.heuristic.rawValue,
                thread, Threading.normalizedSubject(mail.subject).lowercased(),
                incoming.archived && incoming.folderRole == .inbox, incoming.gmailThread, references, json(mail.bcc),
            ])
            guard db.changes > 0 else { return nil }
            // New mail in a conversation that was put off for later brings it back now.
            if incoming.folderRole == .inbox, !incoming.archived {
                try db.run("UPDATE threads SET snoozed_until=NULL, waiting_dismissed=0 WHERE thread_id=?", [thread])
            }
            return db.lastInsertID
        }
    }

    public func uids(account: UUID, folder: String) throws -> [UInt32: Int64] {
        try locked {
            // Rows with a placeholder uid (<= 0) have no known server location.
            let rows = try db.query("SELECT id, uid FROM messages WHERE account_id=? AND folder=? AND uid > 0",
                                    [account.uuidString, folder])
            var result: [UInt32: Int64] = [:]
            for row in rows { result[UInt32(row.int("uid") ?? 0)] = row.int("id") }
            return result
        }
    }

    public func uidValidity(account: UUID, folder: String) throws -> UInt32? {
        try locked {
            try db.query("SELECT uid_validity FROM sync_state WHERE account_id=? AND folder=?", [account.uuidString, folder])
                .first?.int("uid_validity").map { UInt32($0) }
        }
    }

    public func setUIDValidity(_ value: UInt32, account: UUID, folder: String) throws {
        try locked {
            // A renumbered folder starts over, also for how far it has been looked through.
            try db.run("""
            INSERT INTO sync_state(account_id, folder, uid_validity) VALUES(?,?,?)
            ON CONFLICT(account_id, folder) DO UPDATE SET
                seen_uid = CASE WHEN uid_validity = excluded.uid_validity THEN seen_uid ELSE 0 END,
                uid_validity = excluded.uid_validity
            """, [account.uuidString, folder, value])
        }
    }

    /// The highest uid of a folder that has been looked at, for folders where most mail is skipped (Gmail's
    /// All Mail holds the inbox and sent mail again).
    public func seenUID(account: UUID, folder: String) throws -> UInt32 {
        try locked {
            UInt32(try db.query("SELECT seen_uid FROM sync_state WHERE account_id=? AND folder=?", [account.uuidString, folder])
                .first?.int("seen_uid") ?? 0)
        }
    }

    public func setSeenUID(_ uid: UInt32, account: UUID, folder: String) throws {
        try locked {
            try db.run("UPDATE sync_state SET seen_uid=? WHERE account_id=? AND folder=?", [uid, account.uuidString, folder])
        }
    }

    /// The user's own mail stored from a folder, with the stored original: (row id, file path).
    public func ownCopies(account: UUID, folder: String) throws -> [(Int64, String)] {
        try locked {
            try db.query("SELECT id, raw_path FROM messages WHERE account_id=? AND folder=? AND folder_role='sent' AND raw_path != ''",
                         [account.uuidString, folder]).compactMap { row in
                guard let id = row.int("id"), let path = row.string("raw_path") else { return nil }
                return (id, path)
            }
        }
    }

    /// Which of these Message-IDs the account already has, in any folder.
    public func knownMessageIDs(account: UUID, among ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try locked {
            var known = Set<String>()
            for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try db.query("SELECT message_id FROM messages WHERE account_id=? AND message_id IN (\(marks))",
                                        [account.uuidString] + chunk) {
                    if let id = row.string("message_id") { known.insert(id) }
                }
            }
            return known
        }
    }

    /// Conversations the user wrote in.
    public func threadsWithSentMail() throws -> Set<String> {
        try locked {
            Set(try db.query("SELECT DISTINCT thread_id FROM messages WHERE folder_role='sent'").compactMap { $0.string("thread_id") })
        }
    }

    /// Reference numbers per conversation ("075920"), from subjects and what people wrote.
    public func referenceTokens() throws -> [String: Set<String>] {
        try locked {
            var result: [String: Set<String>] = [:]
            for row in try db.query("SELECT thread_id, ref_tokens FROM messages WHERE ref_tokens != ''") {
                guard let thread = row.string("thread_id"), let tokens = row.string("ref_tokens") else { continue }
                result[thread, default: []].formUnion(tokens.split(separator: " ").map(String.init))
            }
            return result
        }
    }

    /// Addresses that are probably the user too: recipients of this account's inbox mail and senders of its sent
    /// mail whose name part matches the account's name or address, seen at least twice. For Settings to offer.
    public func aliasCandidates(account: UUID, name: String, email: String) throws -> [String] {
        let words = Set((name + " " + (email.split(separator: "@").first.map(String.init) ?? ""))
            .lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 })
        guard !words.isEmpty else { return [] }
        return try locked {
            var counts: [String: Int] = [:]
            let rows = try db.query("""
            SELECT folder_role, from_json, to_json, cc_json FROM messages WHERE account_id=? ORDER BY date DESC LIMIT 3000
            """, [account.uuidString])
            for row in rows {
                let keys = row.string("folder_role") == "sent" ? ["from_json"] : ["to_json", "cc_json"]
                for key in keys {
                    guard let json = row.string(key), let data = json.data(using: .utf8) else { continue }
                    let list = (try? JSONDecoder().decode([EmailAddress].self, from: data))
                        ?? (try? JSONDecoder().decode(EmailAddress.self, from: data)).map { [$0] } ?? []
                    for address in list {
                        let lower = address.address.lowercased()
                        guard lower != email.lowercased(), lower.contains("@") else { continue }
                        let local = lower.split(separator: "@").first.map(String.init) ?? ""
                        let tokens = Set((local + " " + address.name.lowercased()).split { !$0.isLetter }.map(String.init))
                        if !tokens.isDisjoint(with: words) { counts[lower, default: 0] += 1 }
                    }
                }
            }
            return counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key)
        }
    }

    public func deleteFolder(account: UUID, folder: String) throws {
        try locked { try db.run("DELETE FROM messages WHERE account_id=? AND folder=?", [account.uuidString, folder]) }
    }

    public func deleteAccount(_ account: UUID) throws {
        try locked {
            try db.run("DELETE FROM messages WHERE account_id=?", [account.uuidString])
            try db.run("DELETE FROM sync_state WHERE account_id=?", [account.uuidString])
        }
    }

    public func delete(_ id: Int64) throws {
        try locked { try db.run("DELETE FROM messages WHERE id=?", [id]) }
    }

    public func update(_ id: Int64, read: Bool? = nil, flagged: Bool? = nil, archived: Bool? = nil) throws {
        try locked {
            if let read { try db.run("UPDATE messages SET is_read=? WHERE id=?", [read, id]) }
            if let flagged { try db.run("UPDATE messages SET is_flagged=? WHERE id=?", [flagged, id]) }
            if let archived { try db.run("UPDATE messages SET is_archived=? WHERE id=?", [archived, id]) }
        }
    }

    /// Updates the server location of a message after it was moved.
    public func move(_ id: Int64, toFolder folder: String, uid: UInt32?) throws {
        try locked {
            // A unique (folder, uid) is required; use a negative placeholder uid when the server did not report one.
            let newUID: Int64 = uid.map { Int64($0) } ?? -id
            try db.run("UPDATE OR REPLACE messages SET folder=?, uid=? WHERE id=?", [folder, newUID, id])
        }
    }

    public func setCategory(_ id: Int64, _ category: MailCategory, source: ClassificationSource) throws {
        try locked {
            try db.run("UPDATE messages SET category=?, category_source=? WHERE id=?", [category.rawValue, source.rawValue, id])
        }
    }

    /// Sets the category of every inbox message in a conversation (the user's word is final).
    public func setThreadCategory(_ thread: String, _ category: MailCategory) throws {
        try locked {
            try db.run("UPDATE messages SET category=?, category_source='manual' WHERE thread_id=? AND folder_role='inbox'",
                       [category.rawValue, thread])
        }
    }

    /// Sets the category of all mail received from one sender (the user's word is final).
    public func setSenderCategory(_ address: String, _ category: MailCategory) throws {
        try locked {
            try db.run("""
            UPDATE messages SET category=?, category_source='manual'
            WHERE folder_role='inbox' AND lower(json_extract(from_json, '$.address'))=?
            """, [category.rawValue, address.lowercased()])
        }
    }

    public func setTriage(_ id: Int64, category: MailCategory?, needsReply: Bool, summary: String?,
                          topic: String? = nil, ask: String? = nil) throws {
        try locked {
            if let category {
                // Never override decisions made by rules or by the user.
                try db.run("""
                UPDATE messages SET category=?, category_source='ai'
                WHERE id=? AND (category_source IS NULL OR category_source IN ('heuristic','ai'))
                """, [category.rawValue, id])
            }
            try db.run("UPDATE messages SET needs_reply=?, summary=?, topic=?, ask=?, ai_done=1 WHERE id=?",
                       [needsReply, summary, topic, needsReply ? ask : nil, id])
        }
    }

    public func setNeedsReply(_ id: Int64, _ value: Bool) throws {
        try locked { try db.run("UPDATE messages SET needs_reply=? WHERE id=?", [value, id]) }
    }

    public func clearNeedsReply(thread: String) throws {
        try locked { try db.run("UPDATE messages SET needs_reply=0 WHERE thread_id=?", [thread]) }
    }

    public func markRulesDone(_ id: Int64) throws {
        try locked { try db.run("UPDATE messages SET rules_done=1 WHERE id=?", [id]) }
    }

    // MARK: Conversation state

    /// Puts a conversation into a court (nil: none); `how` records who decided (see the `place` column).
    public func setSpace(thread: String, space: UUID?, how: String = "you") throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            // A project belongs to its court: moving to another court leaves the project.
            try db.run("""
            UPDATE threads SET space_id=?, project_id=CASE WHEN space_id IS ? THEN project_id ELSE NULL END,
                place=CASE WHEN space_id IS ? THEN place ELSE ? END WHERE thread_id=?
            """, [space?.uuidString, space?.uuidString, space?.uuidString, space == nil ? nil : how, thread])
        }
    }

    /// How each conversation got its court, by conversation id (only those that have a record).
    public func placements() throws -> [String: String] {
        try locked {
            var result: [String: String] = [:]
            for row in try db.query("SELECT thread_id, place FROM threads WHERE place IS NOT NULL AND space_id IS NOT NULL") {
                if let thread = row.string("thread_id"), let place = row.string("place") { result[thread] = place }
            }
            return result
        }
    }

    /// Received mail per month (spam left out), newest first: for jumping through the Inbox.
    public func monthCounts(space: UUID? = nil) throws -> [(month: Date, count: Int)] {
        var sql = """
        SELECT strftime('%Y-%m', m.date, 'unixepoch', 'localtime') AS month, count(*) AS n FROM messages m
        WHERE m.folder_role='inbox' AND IFNULL(m.category,'') != 'spam'
        """
        var params: [Any?] = []
        if let space {
            sql += " AND m.thread_id IN (SELECT thread_id FROM threads WHERE space_id=?)"
            params.append(space.uuidString)
        }
        sql += " GROUP BY month ORDER BY month DESC"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return try locked {
            try db.query(sql, params).compactMap { row in
                guard let text = row.string("month"), let month = formatter.date(from: text) else { return nil }
                return (month, Int(row.int("n") ?? 0))
            }
        }
    }

    /// Puts a conversation into a project of its court (nil: no project).
    public func setProject(thread: String, project: UUID?) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET project_id=? WHERE thread_id=?", [project?.uuidString, thread])
        }
    }

    /// Used by rules: sets the project unless the conversation has one, and only while it is in the project's court.
    public func setProjectIfNone(thread: String, project: UUID, space: UUID) throws {
        try locked {
            try db.run("UPDATE threads SET project_id=? WHERE thread_id=? AND project_id IS NULL AND space_id=?",
                       [project.uuidString, thread, space.uuidString])
        }
    }

    // MARK: Topics

    /// Makes sure a topic row exists (keeps its name if it does).
    public func ensureMatter(id: String, title: String, now: Date = Date()) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO matters(id, title, created) VALUES(?,?,?)", [id, title, now.timeIntervalSince1970])
        }
    }

    /// A new, empty topic; returns its id.
    @discardableResult
    public func createMatter(title: String) throws -> String {
        let id = UUID().uuidString
        try ensureMatter(id: id, title: title)
        return id
    }

    public func renameMatter(_ id: String, title: String) throws {
        try locked { try db.run("UPDATE matters SET title=? WHERE id=?", [title, id]) }
    }

    /// Puts conversations into a topic (nil: each becomes a topic of its own again).
    public func setMatter(threads: [String], matter: String?) throws {
        try locked {
            for thread in threads {
                try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
                try db.run("UPDATE threads SET matter_id=? WHERE thread_id=?", [matter, thread])
            }
        }
    }

    /// Used by automation: puts a conversation into a topic unless it is in one already.
    public func setMatterIfNone(thread: String, matter: String) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET matter_id=? WHERE thread_id=? AND matter_id IS NULL", [matter, thread])
        }
    }

    /// Projects become topics: every conversation of a project joins the topic with the project's id and name.
    public func adoptProject(_ project: UUID, title: String) throws {
        try ensureMatter(id: project.uuidString, title: title)
        try locked {
            try db.run("UPDATE threads SET matter_id=? WHERE project_id=? AND matter_id IS NULL", [project.uuidString, project.uuidString])
        }
    }

    /// The conversations of a topic (a topic of its own is just its conversation).
    public func threads(ofMatter id: String) throws -> [String] {
        try locked {
            let rows = try db.query("SELECT thread_id FROM threads WHERE matter_id=?", [id]).compactMap { $0.string("thread_id") }
            return rows.isEmpty ? [id] : rows
        }
    }

    /// Received mail, newest first: the Inbox. Spam is left out.
    public func feed(_ query: FeedQuery) throws -> [MailMessage] {
        var conditions = ["m.folder_role='inbox'", "IFNULL(m.category,'') != 'spam'"]
        var params: [Any?] = []
        if let space = query.space {
            conditions.append("m.thread_id IN (SELECT thread_id FROM threads WHERE space_id=?)")
            params.append(space.uuidString)
        }
        if query.unreadOnly { conditions.append("m.is_read=0") }
        if query.attachmentsOnly { conditions.append("m.attachments_json!='[]'") }
        if let before = query.before {
            conditions.append("m.date < ?")
            params.append(before.timeIntervalSince1970)
        }
        if let from = query.from {
            conditions.append("lower(json_extract(m.from_json, '$.address'))=?")
            params.append(from)
        }
        for term in query.search.lowercased().split(separator: " ") where !term.isEmpty {
            conditions.append("(m.search_text LIKE ? OR lower(IFNULL(m.summary,'')) LIKE ?)")
            params.append("%\(term)%")
            params.append("%\(term)%")
        }
        let sql = "SELECT \(Self.listColumns) FROM messages m WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.date DESC LIMIT \(query.limit)"
        return try locked { try db.query(sql, params).map(Self.message) }
    }

    /// A sender's newest mails in any folder, to learn their signature from.
    public func messages(from address: String, limit: Int) throws -> [MailMessage] {
        let sql = """
        SELECT \(Self.listColumns) FROM messages m WHERE lower(json_extract(m.from_json, '$.address'))=?
        ORDER BY m.date DESC LIMIT \(limit)
        """
        return try locked { try db.query(sql, [address.lowercased()]).map(Self.message) }
    }

    public func removeProject(_ project: UUID) throws {
        try locked { try db.run("UPDATE threads SET project_id=NULL WHERE project_id=?", [project.uuidString]) }
    }

    /// Puts a conversation into a space unless it already has one (used by rules).
    public func setSpaceIfNone(thread: String, space: UUID, how: String = "rule") throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET space_id=?, place=? WHERE thread_id=? AND space_id IS NULL", [space.uuidString, how, thread])
        }
    }

    public func spaceOf(thread: String) throws -> UUID? {
        try locked {
            try db.query("SELECT space_id FROM threads WHERE thread_id=?", [thread]).first?.string("space_id").flatMap(UUID.init)
        }
    }

    public func messageCount(space: UUID) throws -> Int {
        try locked {
            Int(try db.query("SELECT count(*) AS n FROM messages WHERE thread_id IN (SELECT thread_id FROM threads WHERE space_id=?)",
                             [space.uuidString]).first?.int("n") ?? 0)
        }
    }

    public func removeSpace(_ space: UUID) throws {
        try locked { try db.run("UPDATE threads SET space_id=NULL, project_id=NULL WHERE space_id=?", [space.uuidString]) }
    }

    public func snooze(thread: String, until date: Date?) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET snoozed_until=? WHERE thread_id=?", [date?.timeIntervalSince1970, thread])
        }
    }

    /// The user marks a topic as theirs: a task of their own, or a new note on it. It stays until ticked off;
    /// a sent mail can only suggest that it is done.
    public func setTodo(thread: String, note: String?, now: Date = Date()) throws {
        try locked {
            if let open = try db.query("SELECT id FROM tasks WHERE thread_id=? AND source='manual' AND done_at IS NULL LIMIT 1",
                                       [thread]).first?.int("id") {
                if let note { try db.run("UPDATE tasks SET text=? WHERE id=?", [note, open]) }
            } else {
                try db.run("INSERT INTO tasks(thread_id, text, source, created) VALUES(?,?,?,?)",
                           [thread, note ?? "", MailTask.Source.manual.rawValue, now.timeIntervalSince1970])
            }
        }
    }

    /// Nothing left to do in a conversation ("quiet", "not my turn"): all its open tasks count as done.
    public func clearTodo(thread: String, now: Date = Date()) throws {
        try locked { try db.run("UPDATE tasks SET done_at=? WHERE thread_id=? AND done_at IS NULL", [now.timeIntervalSince1970, thread]) }
    }

    /// A task the model found in a mail, unless the conversation already has the same open task or this mail
    /// already gave one.
    @discardableResult
    public func addTask(thread: String, text: String, message: Int64, date: Date) throws -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return try locked {
            let duplicate = try db.query("""
            SELECT 1 FROM tasks WHERE message_id=? OR (thread_id=? AND done_at IS NULL AND lower(text)=lower(?)) LIMIT 1
            """, [message, thread, text]).first != nil
            if duplicate { return nil }
            try db.run("INSERT INTO tasks(thread_id, text, source, message_id, created) VALUES(?,?,?,?,?)",
                       [thread, text, MailTask.Source.model.rawValue, message, date.timeIntervalSince1970])
            return db.lastInsertID
        }
    }

    public func completeTask(_ id: Int64, now: Date = Date()) throws {
        try locked { try db.run("UPDATE tasks SET done_at=? WHERE id=?", [now.timeIntervalSince1970, id]) }
    }

    /// Not a task after all: gone, and the mail it came from will not bring it back.
    public func dismissTask(_ id: Int64) throws {
        try locked { try db.run("UPDATE tasks SET done_at=-1 WHERE id=?", [id]) }
    }

    /// A sent mail sounds like the task is done; shown as a question, never done on its own.
    public func suggestDone(_ id: Int64, by message: Int64) throws {
        try locked { try db.run("UPDATE tasks SET done_suggested_by=? WHERE id=? AND done_at IS NULL", [message, id]) }
    }

    /// "Not yet": the suggestion goes away, the task stays.
    public func rejectDoneSuggestion(_ id: Int64) throws {
        try locked { try db.run("UPDATE tasks SET done_suggested_by=NULL WHERE id=?", [id]) }
    }

    /// Open tasks per conversation, oldest first.
    public func openTasks(threads: [String]? = nil) throws -> [String: [MailTask]] {
        try locked {
            var result: [String: [MailTask]] = [:]
            for row in try db.query("SELECT * FROM tasks WHERE done_at IS NULL ORDER BY created") {
                guard let id = row.int("id"), let thread = row.string("thread_id") else { continue }
                if let threads, !threads.contains(thread) { continue }
                result[thread, default: []].append(MailTask(
                    id: id, threadID: thread, text: row.string("text") ?? "",
                    source: MailTask.Source(rawValue: row.string("source") ?? "") ?? .model,
                    created: Date(timeIntervalSince1970: row.double("created") ?? 0),
                    doneSuggestedBy: row.int("done_suggested_by")))
            }
            return result
        }
    }

    /// Mail the user sent recently that has not been read for tasks yet, oldest first (so tasks build up in order).
    public func pendingReview(since: Date, limit: Int) throws -> [MailMessage] {
        try locked {
            try db.query("""
            SELECT \(Self.listColumns) FROM messages m WHERE m.ai_done=0 AND m.folder_role='sent' AND m.date > ?
            ORDER BY m.date ASC LIMIT \(limit)
            """, [since.timeIntervalSince1970]).map(Self.message)
        }
    }

    public func markReviewed(_ id: Int64) throws {
        try locked { try db.run("UPDATE messages SET ai_done=1 WHERE id=?", [id]) }
    }

    public func dismissWaiting(thread: String) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET waiting_dismissed=1 WHERE thread_id=?", [thread])
        }
    }

    // MARK: Reading messages

    private static let listColumns = """
    m.*, (SELECT t.space_id FROM threads t WHERE t.thread_id = m.thread_id) AS space_id,
    (SELECT t.matter_id FROM threads t WHERE t.thread_id = m.thread_id) AS matter_id
    """

    /// A message still asks something of the user: open in the inbox, and the user has not written in its thread since.
    static let stillAsked = """
    m.needs_reply=1 AND m.folder_role='inbox' AND m.is_archived=0 AND m.date > \
    IFNULL((SELECT MAX(x.date) FROM messages x WHERE x.thread_id=m.thread_id AND x.folder_role='sent'), 0)
    """

    public func messages(_ filter: MailFilter, search: String = "", account: UUID? = nil, limit: Int = 1000) throws -> [MailMessage] {
        var conditions: [String] = []
        var params: [Any?] = []
        switch filter {
        case .inbox:
            conditions.append("m.folder_role='inbox' AND m.is_archived=0 AND (m.category IS NULL OR m.category='primary')")
        case .category(.spam):
            // Spam stays visible here even after it was moved to the server's junk folder.
            conditions.append("m.folder_role='inbox' AND m.category='spam'")
        case .category(let category):
            conditions.append("m.folder_role='inbox' AND m.is_archived=0 AND m.category=?")
            params.append(category.rawValue)
        case .needsReply:
            conditions.append("\(Self.stillAsked) AND IFNULL(m.category,'') != 'spam'")
        case .flagged:
            conditions.append("m.is_flagged=1")
        case .sent:
            conditions.append("m.folder_role='sent'")
        case .archive:
            conditions.append("m.folder_role='inbox' AND m.is_archived=1 AND IFNULL(m.category,'') != 'spam'")
        case .all:
            break
        case .space(let space):
            conditions.append("m.thread_id IN (SELECT thread_id FROM threads WHERE space_id=?)")
            params.append(space.uuidString)
        case .thread(let thread):
            conditions.append("m.thread_id=?")
            params.append(thread)
        }
        if let account {
            conditions.append("m.account_id=?")
            params.append(account.uuidString)
        }
        for term in search.lowercased().split(separator: " ") where !term.isEmpty {
            conditions.append("m.search_text LIKE ?")
            params.append("%\(term)%")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let order = { if case .thread = filter { return "ASC" } else { return "DESC" } }()
        return try locked {
            try db.query("SELECT \(Self.listColumns) FROM messages m \(whereClause) ORDER BY m.date \(order) LIMIT \(limit)", params)
                .map(Self.message)
        }
    }

    public func message(_ id: Int64) throws -> MailMessage? {
        try locked {
            try db.query("SELECT \(Self.listColumns) FROM messages m WHERE m.id=?", [id]).first.map(Self.message)
        }
    }

    /// All messages of a conversation, oldest first.
    public func thread(_ id: String) throws -> [MailMessage] {
        try messages(.thread(id), limit: 5000)
    }

    /// All messages of several conversations (a chat), oldest first.
    public func messages(threads: [String]) throws -> [MailMessage] {
        guard !threads.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: threads.count).joined(separator: ",")
        return try locked {
            try db.query("SELECT \(Self.listColumns) FROM messages m WHERE m.thread_id IN (\(marks)) ORDER BY m.date ASC", threads)
                .map(Self.message)
        }
    }

    public func pendingRules() throws -> [MailMessage] {
        try locked {
            try db.query("SELECT \(Self.listColumns) FROM messages m WHERE m.rules_done=0").map(Self.message)
        }
    }

    public func pendingTriage(limit: Int) throws -> [MailMessage] {
        try locked {
            try db.query("""
            SELECT \(Self.listColumns) FROM messages m
            WHERE m.ai_done=0 AND m.folder_role='inbox' AND m.is_archived=0
            ORDER BY m.date DESC LIMIT \(limit)
            """).map(Self.message)
        }
    }

    public func resetTriage() throws {
        try locked { try db.run("UPDATE messages SET ai_done=0") }
    }

    /// Addresses the user has written to or received from, most frequent first (for the composer).
    public func knownAddresses(matching text: String, limit: Int = 8) throws -> [EmailAddress] {
        let needle = text.lowercased()
        return try locked {
            let rows = try db.query("""
            SELECT from_json AS j FROM messages WHERE folder_role='inbox' AND IFNULL(category,'primary')='primary'
            UNION ALL SELECT to_json FROM messages WHERE folder_role='sent'
            """)
            let decoder = JSONDecoder()
            var counts: [String: (EmailAddress, Int)] = [:]
            for row in rows {
                guard let json = row.string("j"), let data = json.data(using: .utf8) else { continue }
                let list = (try? decoder.decode([EmailAddress].self, from: data)) ?? (try? decoder.decode(EmailAddress.self, from: data)).map { [$0] } ?? []
                for address in list where !address.address.isEmpty {
                    let key = address.address.lowercased()
                    guard needle.isEmpty || key.contains(needle) || address.name.lowercased().contains(needle) else { continue }
                    let existing = counts[key]
                    counts[key] = (existing?.0.name.isEmpty == false ? existing!.0 : address, (existing?.1 ?? 0) + 1)
                }
            }
            return counts.values.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
    }

    // MARK: Conversations

    public func conversations(_ query: ConversationQuery) throws -> [Conversation] {
        var messageConditions: [String] = []
        var params: [Any?] = []
        if let space = query.space {
            messageConditions.append("m.thread_id IN (SELECT thread_id FROM threads WHERE space_id=?)")
            params.append(space.uuidString)
        }
        if let project = query.project {
            messageConditions.append("m.thread_id IN (SELECT thread_id FROM threads WHERE project_id=?)")
            params.append(project.uuidString)
        }
        for term in query.search.lowercased().split(separator: " ") where !term.isEmpty {
            messageConditions.append("m.search_text LIKE ?")
            params.append("%\(term)%")
        }
        let messageWhere = messageConditions.isEmpty ? "" : "WHERE " + messageConditions.joined(separator: " AND ")

        let now = query.now.timeIntervalSince1970
        var outer: [String] = []
        let openClause = "t.open_n > 0 AND (s.snoozed_until IS NULL OR s.snoozed_until <= ?)"
        switch query.scope {
        case .open:
            outer.append(openClause); params.append(now)
        case .earlier:
            outer.append("NOT (\(openClause))"); params.append(now)
        case .waiting(let olderThan):
            outer.append("l.folder_role='sent' AND t.last_date < ? AND IFNULL(s.waiting_dismissed,0)=0 AND t.open_n=0")
            params.append(olderThan.timeIntervalSince1970)
        case .all:
            break
        case .todo:
            outer.append("EXISTS (SELECT 1 FROM tasks k WHERE k.thread_id = t.thread_id AND k.done_at IS NULL)")
        }
        if query.peopleOnly { outer.append("IFNULL(l.category, IFNULL(t.any_category, 'primary')) = 'primary'") }
        if query.attachmentsOnly { outer.append("t.att_n > 0") }
        let outerWhere = outer.isEmpty ? "" : "WHERE " + outer.joined(separator: " AND ")

        let sql = """
        WITH t AS (
            SELECT m.thread_id,
                COUNT(*) AS n,
                MAX(m.date) AS last_date,
                MIN(m.date) AS first_date,
                SUM(CASE WHEN m.folder_role='inbox' AND m.is_archived=0 AND IFNULL(m.category,'')!='spam' THEN 1 ELSE 0 END) AS open_n,
                SUM(CASE WHEN \(Self.stillAsked) THEN 1 ELSE 0 END) AS reply_n,
                MAX(CASE WHEN \(Self.stillAsked) THEN m.ask END) AS ask,
                SUM(CASE WHEN m.is_read=0 THEN 1 ELSE 0 END) AS unread_n,
                SUM(CASE WHEN m.attachments_json!='[]' THEN 1 ELSE 0 END) AS att_n,
                MAX(CASE WHEN m.category='spam' THEN 1 ELSE 0 END) AS spam,
                MAX(CASE WHEN m.folder_role='inbox' THEN m.category END) AS any_category,
                group_concat(m.from_json || char(2) || m.to_json || char(2) || m.cc_json, char(1)) AS people
            FROM messages m \(messageWhere)
            GROUP BY m.thread_id
        )
        SELECT t.*, l.id AS last_id, l.from_json, l.to_json, l.folder_role, l.summary, l.topic, l.snippet, l.subject,
               l.category, l.account_id, s.space_id, s.snoozed_until, s.waiting_dismissed,
               s.todo_since, s.todo_note, s.project_id, s.matter_id, mt.title AS matter_title
        FROM t
        JOIN messages l ON l.thread_id = t.thread_id AND l.date = t.last_date
        LEFT JOIN threads s ON s.thread_id = t.thread_id
        LEFT JOIN matters mt ON mt.id = s.matter_id
        \(outerWhere)
        GROUP BY t.thread_id
        ORDER BY t.last_date DESC
        LIMIT \(query.limit) OFFSET \(query.offset)
        """
        var result = try locked { try db.query(sql, params).map(Self.conversation) }
        let tasks = try openTasks()
        for index in result.indices { result[index].tasks = tasks[result[index].id] ?? [] }
        return result
    }

    /// How many conversations need the user right now (for the window title and the dock badge).
    public func openCount(space: UUID? = nil, now: Date = Date()) throws -> Int {
        var query = ConversationQuery(scope: .open, space: space)
        query.limit = 100_000
        query.now = now
        return try conversations(query).count
    }

    private static func conversation(_ row: Row) -> Conversation {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ string: String?, _ fallback: T) -> T {
            guard let string else { return fallback }
            return (try? decoder.decode(type, from: Data(string.utf8))) ?? fallback
        }
        var participants: [EmailAddress] = []
        var seen = Set<String>()
        for entry in (row.string("people") ?? "").split(separator: "\u{1}") {
            let parts = entry.split(separator: "\u{2}", omittingEmptySubsequences: false).map(String.init)
            var found: [EmailAddress] = []
            if parts.count > 0 { found.append(decode(EmailAddress.self, parts[0], EmailAddress(address: ""))) }
            if parts.count > 1 { found += decode([EmailAddress].self, parts[1], []) }
            if parts.count > 2 { found += decode([EmailAddress].self, parts[2], []) }
            for address in found where !address.address.isEmpty {
                let key = address.address.lowercased()
                if seen.insert(key).inserted {
                    participants.append(address)
                } else if !address.name.isEmpty, let index = participants.firstIndex(where: { $0.address.lowercased() == key }),
                          participants[index].name.isEmpty {
                    participants[index].name = address.name
                }
            }
        }
        let category = row.string("category").flatMap(MailCategory.init) ?? row.string("any_category").flatMap(MailCategory.init)
        return Conversation(
            id: row.string("thread_id") ?? "",
            subject: Threading.normalizedSubject(row.string("subject") ?? ""),
            firstDate: Date(timeIntervalSince1970: row.double("first_date") ?? 0),
            lastDate: Date(timeIntervalSince1970: row.double("last_date") ?? 0),
            messageCount: Int(row.int("n") ?? 0),
            openCount: Int(row.int("open_n") ?? 0),
            unreadCount: Int(row.int("unread_n") ?? 0),
            needsReply: (row.int("reply_n") ?? 0) > 0,
            ask: row.string("ask"),
            hasAttachments: (row.int("att_n") ?? 0) > 0,
            isSpam: row.bool("spam"),
            category: row.string("folder_role") == "sent" ? row.string("any_category").flatMap(MailCategory.init) : category,
            participants: participants,
            lastMessageID: row.int("last_id") ?? 0,
            lastFrom: decode(EmailAddress.self, row.string("from_json"), EmailAddress(address: "")),
            lastTo: decode([EmailAddress].self, row.string("to_json"), []),
            lastFolderRole: FolderRole(rawValue: row.string("folder_role") ?? "") ?? .inbox,
            lastSummary: row.string("summary"),
            lastSnippet: row.string("snippet") ?? "",
            accountID: UUID(uuidString: row.string("account_id") ?? "") ?? UUID(),
            spaceID: row.string("space_id").flatMap(UUID.init),
            snoozedUntil: row.double("snoozed_until").map(Date.init(timeIntervalSince1970:)),
            waitingDismissed: row.bool("waiting_dismissed"),
            todoSince: row.double("todo_since").map(Date.init(timeIntervalSince1970:)),
            todoNote: row.string("todo_note"),
            projectID: row.string("project_id").flatMap(UUID.init),
            lastTopic: row.string("topic"),
            matterID: row.string("matter_id"),
            matterTitle: row.string("matter_title")
        )
    }

    private static func message(_ row: Row) -> MailMessage {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ key: String, _ fallback: T) -> T {
            guard let string = row.string(key) else { return fallback }
            return (try? decoder.decode(type, from: Data(string.utf8))) ?? fallback
        }
        let space = row.string("space_id").flatMap(UUID.init)
        return MailMessage(
            id: row.int("id") ?? 0,
            accountID: UUID(uuidString: row.string("account_id") ?? "") ?? UUID(),
            folder: row.string("folder") ?? "",
            folderRole: FolderRole(rawValue: row.string("folder_role") ?? "") ?? .inbox,
            uid: UInt32(clamping: row.int("uid") ?? 0),
            messageID: row.string("message_id") ?? "",
            inReplyTo: row.string("in_reply_to") ?? "",
            references: row.string("refs") ?? "",
            subject: row.string("subject") ?? "",
            from: decode(EmailAddress.self, "from_json", EmailAddress(address: "")),
            to: decode([EmailAddress].self, "to_json", []),
            cc: decode([EmailAddress].self, "cc_json", []),
            replyTo: decode([EmailAddress].self, "reply_to_json", []),
            date: Date(timeIntervalSince1970: row.double("date") ?? 0),
            snippet: row.string("snippet") ?? "",
            bodyText: row.string("body_text") ?? "",
            bodyHTML: row.string("body_html"),
            attachments: decode([AttachmentInfo].self, "attachments_json", []),
            isBulk: row.bool("is_bulk"),
            isRead: row.bool("is_read"),
            isFlagged: row.bool("is_flagged"),
            isArchived: row.bool("is_archived"),
            category: row.string("category").flatMap(MailCategory.init),
            categorySource: row.string("category_source").flatMap(ClassificationSource.init),
            summary: row.string("summary"),
            needsReply: row.bool("needs_reply"),
            spaceIDs: space.map { [$0] } ?? [],
            rawPath: row.string("raw_path") ?? "",
            threadID: row.string("thread_id") ?? "",
            topic: row.string("topic"),
            ask: row.string("ask"),
            matterID: row.string("matter_id"),
            bcc: decode([EmailAddress].self, "bcc_json", [])
        )
    }
}

enum Snippet {
    static func make(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
        return String(lines.joined(separator: " ").prefix(220))
    }
}
