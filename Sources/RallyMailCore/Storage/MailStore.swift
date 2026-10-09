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

    public init(accountID: UUID, folder: String, folderRole: FolderRole, uid: UInt32, flags: Set<String>,
                parsed: ParsedMail, rawPath: String) {
        self.accountID = accountID
        self.folder = folder
        self.folderRole = folderRole
        self.uid = uid
        self.flags = flags
        self.parsed = parsed
        self.rawPath = rawPath
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
        try backfillThreads()
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
                          participants: [EmailAddress], date: Date, fallback: String) throws -> String {
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
        // 3. Well-formed chains all name the same root: use it, so order of arrival does not matter.
        if let root = referenced.first { return root }
        // 4. Replies without headers (some web mailers): same subject and a shared person within half a year.
        if Threading.isReplySubject(subject) {
            let normalized = Threading.normalizedSubject(subject).lowercased()
            let addresses = Set(participants.map { $0.address.lowercased() })
            let candidates = try db.query("""
            SELECT thread_id, from_json, to_json, cc_json FROM messages
            WHERE norm_subject=? AND ABS(date - ?) < ? ORDER BY ABS(date - ?) LIMIT 20
            """, [normalized, date.timeIntervalSince1970, 180.0 * 86400, date.timeIntervalSince1970])
            for candidate in candidates {
                let text = [candidate.string("from_json"), candidate.string("to_json"), candidate.string("cc_json")].compactMap { $0 }.joined().lowercased()
                if addresses.contains(where: { !$0.isEmpty && text.contains($0) }), let thread = candidate.string("thread_id"), !thread.isEmpty {
                    return thread
                }
            }
        }
        return messageID.isEmpty ? "local:" + StableHash.hex(fallback, length: 16) : messageID
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
        return try locked {
            let exists = try db.query("SELECT id FROM messages WHERE account_id=? AND folder=? AND uid=?",
                                      [incoming.accountID.uuidString, incoming.folder, incoming.uid]).first != nil
            if exists { return nil }
            let fallback = "\(incoming.accountID.uuidString)/\(incoming.folder)/\(incoming.uid)"
            let thread = try threadID(messageID: mail.messageID, inReplyTo: mail.inReplyTo, references: mail.references,
                                      subject: mail.subject, participants: people, date: mail.date, fallback: fallback)
            try db.run("""
            INSERT OR IGNORE INTO messages(account_id, folder, folder_role, uid, message_id, in_reply_to, refs,
                subject, from_json, to_json, cc_json, reply_to_json, search_text, date, snippet, body_text, body_html,
                attachments_json, is_bulk, is_read, is_flagged, raw_path, category, category_source, thread_id, norm_subject)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                incoming.accountID.uuidString, incoming.folder, incoming.folderRole.rawValue, incoming.uid,
                mail.messageID, mail.inReplyTo, mail.references, mail.subject,
                json(mail.from ?? EmailAddress(address: "")), json(mail.to), json(mail.cc), json(mail.replyTo),
                search, mail.date, Snippet.make(text), text, mail.html, json(attachments), mail.isBulk,
                incoming.flags.contains("\\Seen") || incoming.folderRole == .sent,
                incoming.flags.contains("\\Flagged"), incoming.rawPath,
                category?.rawValue, category == nil ? nil : ClassificationSource.heuristic.rawValue,
                thread, Threading.normalizedSubject(mail.subject).lowercased(),
            ])
            guard db.changes > 0 else { return nil }
            // New mail in a conversation that was put off for later brings it back now.
            if incoming.folderRole == .inbox {
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
            try db.run("INSERT OR REPLACE INTO sync_state(account_id, folder, uid_validity) VALUES(?,?,?)",
                       [account.uuidString, folder, value])
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

    public func setTriage(_ id: Int64, category: MailCategory?, needsReply: Bool, summary: String?) throws {
        try locked {
            if let category {
                // Never override decisions made by rules or by the user.
                try db.run("""
                UPDATE messages SET category=?, category_source='ai'
                WHERE id=? AND (category_source IS NULL OR category_source IN ('heuristic','ai'))
                """, [category.rawValue, id])
            }
            try db.run("UPDATE messages SET needs_reply=?, summary=?, ai_done=1 WHERE id=?", [needsReply, summary, id])
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

    public func setSpace(thread: String, space: UUID?) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET space_id=? WHERE thread_id=?", [space?.uuidString, thread])
        }
    }

    /// Puts a conversation into a space unless it already has one (used by rules).
    public func setSpaceIfNone(thread: String, space: UUID) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET space_id=? WHERE thread_id=? AND space_id IS NULL", [space.uuidString, thread])
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
        try locked { try db.run("UPDATE threads SET space_id=NULL WHERE space_id=?", [space.uuidString]) }
    }

    public func snooze(thread: String, until date: Date?) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET snoozed_until=? WHERE thread_id=?", [date?.timeIntervalSince1970, thread])
        }
    }

    public func dismissWaiting(thread: String) throws {
        try locked {
            try db.run("INSERT OR IGNORE INTO threads(thread_id) VALUES(?)", [thread])
            try db.run("UPDATE threads SET waiting_dismissed=1 WHERE thread_id=?", [thread])
        }
    }

    // MARK: Reading messages

    private static let listColumns = """
    m.*, (SELECT t.space_id FROM threads t WHERE t.thread_id = m.thread_id) AS space_id
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
            conditions.append("m.folder_role='inbox' AND m.is_archived=0 AND m.needs_reply=1 AND IFNULL(m.category,'') != 'spam'")
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
                SUM(CASE WHEN m.needs_reply=1 AND m.folder_role='inbox' AND m.is_archived=0 THEN 1 ELSE 0 END) AS reply_n,
                SUM(CASE WHEN m.is_read=0 THEN 1 ELSE 0 END) AS unread_n,
                SUM(CASE WHEN m.attachments_json!='[]' THEN 1 ELSE 0 END) AS att_n,
                MAX(CASE WHEN m.category='spam' THEN 1 ELSE 0 END) AS spam,
                MAX(CASE WHEN m.folder_role='inbox' THEN m.category END) AS any_category,
                group_concat(m.from_json || char(2) || m.to_json || char(2) || m.cc_json, char(1)) AS people
            FROM messages m \(messageWhere)
            GROUP BY m.thread_id
        )
        SELECT t.*, l.id AS last_id, l.from_json, l.to_json, l.folder_role, l.summary, l.snippet, l.subject,
               l.category, l.account_id, s.space_id, s.snoozed_until, s.waiting_dismissed
        FROM t
        JOIN messages l ON l.thread_id = t.thread_id AND l.date = t.last_date
        LEFT JOIN threads s ON s.thread_id = t.thread_id
        \(outerWhere)
        GROUP BY t.thread_id
        ORDER BY t.last_date DESC
        LIMIT \(query.limit) OFFSET \(query.offset)
        """
        return try locked { try db.query(sql, params).map(Self.conversation) }
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
            waitingDismissed: row.bool("waiting_dismissed")
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
            threadID: row.string("thread_id") ?? ""
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
