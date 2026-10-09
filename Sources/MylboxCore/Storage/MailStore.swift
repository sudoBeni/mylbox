import Foundation

/// Which messages a list view shows.
public enum MailFilter: Hashable, Sendable {
    case inbox
    case category(MailCategory)
    case needsReply
    case flagged
    case sent
    case archive
    case all
    case space(UUID)
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
        """)
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
        let addresses = ([mail.from].compactMap { $0 } + mail.to + mail.cc).map(\.formatted).joined(separator: " ")
        let search = [mail.subject, addresses, text].joined(separator: "\n").lowercased()
        let attachments = mail.attachments.filter { !$0.isInline }.map {
            AttachmentInfo(filename: $0.filename, mimeType: $0.mimeType, size: $0.data.count)
        }
        let category = incoming.folderRole == .inbox
            ? Heuristics.category(from: mail.from, isBulk: mail.isBulk, subject: mail.subject) : nil
        return try locked {
            try db.run("""
            INSERT OR IGNORE INTO messages(account_id, folder, folder_role, uid, message_id, in_reply_to, refs,
                subject, from_json, to_json, cc_json, reply_to_json, search_text, date, snippet, body_text, body_html,
                attachments_json, is_bulk, is_read, is_flagged, raw_path, category, category_source)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                incoming.accountID.uuidString, incoming.folder, incoming.folderRole.rawValue, incoming.uid,
                mail.messageID, mail.inReplyTo, mail.references, mail.subject,
                json(mail.from ?? EmailAddress(address: "")), json(mail.to), json(mail.cc), json(mail.replyTo),
                search, mail.date, Snippet.make(text), text, mail.html, json(attachments), mail.isBulk,
                incoming.flags.contains("\\Seen") || incoming.folderRole == .sent,
                incoming.flags.contains("\\Flagged"), incoming.rawPath,
                category?.rawValue, category == nil ? nil : ClassificationSource.heuristic.rawValue,
            ])
            return db.changes > 0 ? db.lastInsertID : nil
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

    public func markRulesDone(_ id: Int64) throws {
        try locked { try db.run("UPDATE messages SET rules_done=1 WHERE id=?", [id]) }
    }

    public func addToSpace(_ id: Int64, space: UUID) throws {
        try locked { try db.run("INSERT OR IGNORE INTO message_spaces(message_id, space_id) VALUES(?,?)", [id, space.uuidString]) }
    }

    public func removeFromSpace(_ id: Int64, space: UUID) throws {
        try locked { try db.run("DELETE FROM message_spaces WHERE message_id=? AND space_id=?", [id, space.uuidString]) }
    }

    public func removeSpace(_ space: UUID) throws {
        try locked { try db.run("DELETE FROM message_spaces WHERE space_id=?", [space.uuidString]) }
    }

    // MARK: Reading

    private static let listColumns = """
    m.*, (SELECT group_concat(space_id) FROM message_spaces s WHERE s.message_id = m.id) AS space_ids
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
            conditions.append("m.id IN (SELECT message_id FROM message_spaces WHERE space_id=?)")
            params.append(space.uuidString)
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
        return try locked {
            try db.query("SELECT \(Self.listColumns) FROM messages m \(whereClause) ORDER BY m.date DESC LIMIT \(limit)", params)
                .map(Self.message)
        }
    }

    public func message(_ id: Int64) throws -> MailMessage? {
        try locked {
            try db.query("SELECT \(Self.listColumns) FROM messages m WHERE m.id=?", [id]).first.map(Self.message)
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

    public func unreadCounts() throws -> [MailFilter: Int] {
        try locked {
            var counts: [MailFilter: Int] = [:]
            let inbox = try db.query("""
            SELECT count(*) AS n FROM messages WHERE folder_role='inbox' AND is_archived=0 AND is_read=0
            AND (category IS NULL OR category='primary')
            """)
            counts[.inbox] = Int(inbox.first?.int("n") ?? 0)
            for row in try db.query("""
            SELECT category, count(*) AS n FROM messages WHERE folder_role='inbox' AND is_archived=0 AND is_read=0
            AND category IS NOT NULL GROUP BY category
            """) {
                if let category = row.string("category").flatMap(MailCategory.init) {
                    counts[.category(category)] = Int(row.int("n") ?? 0)
                }
            }
            let reply = try db.query("""
            SELECT count(*) AS n FROM messages WHERE folder_role='inbox' AND is_archived=0 AND needs_reply=1
            AND IFNULL(category,'') != 'spam'
            """)
            counts[.needsReply] = Int(reply.first?.int("n") ?? 0)
            return counts
        }
    }

    private static func message(_ row: Row) -> MailMessage {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ key: String, _ fallback: T) -> T {
            guard let string = row.string(key) else { return fallback }
            return (try? decoder.decode(type, from: Data(string.utf8))) ?? fallback
        }
        let spaces = (row.string("space_ids") ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
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
            spaceIDs: Set(spaces),
            rawPath: row.string("raw_path") ?? ""
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
