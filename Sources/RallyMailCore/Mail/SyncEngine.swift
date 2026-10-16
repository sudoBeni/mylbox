import Foundation

public struct SyncReport: Sendable {
    public var newMessages = 0
    public var removed = 0
}

/// Special folders of an account, detected from LIST attributes or common names.
public struct FolderMap: Sendable {
    public var inbox = "INBOX"
    public var sent: String?
    public var archive: String?
    public var trash: String?
    public var junk: String?

    static func detect(_ mailboxes: [IMAPMailbox]) -> FolderMap {
        var map = FolderMap()
        func find(attribute: String, names: [String]) -> String? {
            if let match = mailboxes.first(where: { $0.has(attribute) }) { return match.name }
            for name in names {
                if let match = mailboxes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    return match.name
                }
            }
            return nil
        }
        map.sent = find(attribute: "\\Sent", names: ["Sent", "Sent Items", "Sent Messages", "Sent Mail",
                                                     "Gesendet", "Gesendete Elemente", "Gesendete Objekte", "INBOX.Sent"])
        map.archive = find(attribute: "\\Archive", names: ["Archive", "Archiv", "INBOX.Archive"])
            ?? find(attribute: "\\All", names: ["[Gmail]/All Mail", "[Google Mail]/All Mail"])
        map.trash = find(attribute: "\\Trash", names: ["Trash", "Deleted Items", "Deleted Messages", "Papierkorb",
                                                       "Gelöschte Elemente", "INBOX.Trash"])
        map.junk = find(attribute: "\\Junk", names: ["Junk", "Spam", "Junk E-Mail", "Junk Email", "Junk-E-Mail",
                                                     "[Gmail]/Spam", "INBOX.Junk", "INBOX.Spam"])
        return map
    }
}

public final class SyncEngine: @unchecked Sendable {
    private let store: MailStore
    private let initialLimit: Int

    public init(store: MailStore, initialLimit: Int) {
        self.store = store
        self.initialLimit = initialLimit
    }

    /// Opens an authenticated IMAP session for an account.
    public static func session(for account: Account) async throws -> IMAPClient {
        let client = try await IMAPClient.connect(account.imap)
        do {
            try await client.authenticate(try await Credentials.shared.auth(for: account))
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    public func sync(_ account: Account) async throws -> SyncReport {
        let client = try await Self.session(for: account)
        var report = SyncReport()
        do {
            let folders = FolderMap.detect(try await client.listMailboxes())
            // Gmail tells which conversation a mail is in; asked for on Gmail only.
            let gmail = folders.archive.map { $0.hasPrefix("[Gmail]") || $0.hasPrefix("[Google Mail]") } ?? false
            try await syncFolder(client, account: account, folder: folders.inbox, role: .inbox, gmail: gmail, report: &report)
            if let sent = folders.sent {
                try await syncFolder(client, account: account, folder: sent, role: .sent, gmail: gmail, report: &report)
            }
            // The archive after inbox and sent, so mail that is in both is already known and skipped. Only when
            // everything is synced (no initial limit): it is the rest of the history.
            if let archive = folders.archive, initialLimit <= 0 {
                try await syncArchive(client, account: account, folder: archive, gmail: gmail, report: &report)
            }
            await client.logout()
        } catch {
            await client.close()
            throw error
        }
        return report
    }

    private func syncFolder(_ client: IMAPClient, account: Account, folder: String, role: FolderRole, gmail: Bool,
                            report: inout SyncReport) async throws {
        let info = try await client.select(folder)
        if let known = try store.uidValidity(account: account.id, folder: folder), known != info.uidValidity {
            // The server renumbered the mailbox: start over for this folder.
            try store.deleteFolder(account: account.id, folder: folder)
        }
        try store.setUIDValidity(info.uidValidity, account: account.id, folder: folder)

        let local = try store.uids(account: account.id, folder: folder)
        let server = info.exists == 0 ? [] : try await client.uidSearch()
        let serverSet = Set(server)

        // Messages that disappeared from the server folder were archived or deleted elsewhere.
        for (uid, id) in local where !serverSet.contains(uid) {
            if role == .inbox {
                try store.update(id, archived: true)
                try store.move(id, toFolder: "", uid: nil)
            } else {
                try store.delete(id)
            }
            report.removed += 1
        }

        // Flag changes (read/flagged) from other clients.
        let knownOnServer = local.keys.filter(serverSet.contains)
        if let lowest = knownOnServer.min() {
            for fetched in try await client.uidFetch(set: "\(lowest):*", items: "UID FLAGS") {
                guard let id = local[fetched.uid] else { continue }
                try store.update(id, read: role == .sent || fetched.flags.contains("\\Seen"),
                                 flagged: fetched.flags.contains("\\Flagged"))
            }
        }

        // New messages, newest first. With a limit, the first sync of a folder only fetches the most recent
        // ones; with 0 (the default) everything is fetched, so the archive is complete and search finds all mail.
        var missing = server.filter { local[$0] == nil }.sorted(by: >)
        let limit = initialLimit <= 0 ? Int.max : (local.isEmpty ? (role == .sent ? max(1, initialLimit / 3) : initialLimit) : 2000)
        missing = Array(missing.prefix(limit))
        try await download(missing, client, account: account, folder: folder, uidValidity: info.uidValidity, gmail: gmail,
                           report: &report) { _ in role }
    }

    /// Fetches mail in batches of 20, newest first, and stores it. `role` decides per mail (the archive holds both
    /// received and sent mail).
    private func download(_ uids: [UInt32], _ client: IMAPClient, account: Account, folder: String, uidValidity: UInt32,
                          gmail: Bool, archived: Bool = false, report: inout SyncReport,
                          skip: (ParsedMail) -> Bool = { _ in false },
                          role: (ParsedMail) -> FolderRole) async throws {
        let rawDirectory = Paths.rawDirectory(account: account.id)
        try Paths.ensure(rawDirectory)
        let items = "UID FLAGS INTERNALDATE BODY.PEEK[]" + (gmail ? " X-GM-THRID" : "")
        for batch in stride(from: 0, to: uids.count, by: 20).map({ Array(uids[$0..<min($0 + 20, uids.count)]) }) {
            let fetched = try await client.uidFetch(batch, items: items)
            for message in fetched {
                guard let raw = message.raw else { continue }
                let folderKey = StableHash.hex(folder, length: 8)
                let rawURL = rawDirectory.appendingPathComponent("\(folderKey)-\(uidValidity)-\(message.uid).eml")
                try raw.write(to: rawURL, options: .atomic)
                let parsed = MIME.parse(raw, fallbackDate: message.internalDate)
                if skip(parsed) {
                    try? FileManager.default.removeItem(at: rawURL)
                    continue
                }
                let mailRole = role(parsed)
                let incoming = IncomingMessage(accountID: account.id, folder: folder, folderRole: mailRole,
                                               uid: message.uid, flags: message.flags, parsed: parsed,
                                               rawPath: rawURL.path, archived: archived,
                                               gmailThread: message.gmailThread ?? "")
                if try store.insert(incoming) != nil { report.newMessages += 1 }
            }
            await progress?(report)
        }
    }

    /// The archive (Gmail's All Mail, or an Archive folder): mail that was done before RallyMail saw it, so old
    /// conversations have both sides. Only the Message-IDs are fetched first; mail that is already here (Gmail
    /// keeps the inbox and sent mail in All Mail as well) and drafts are skipped. The highest uid looked at is
    /// remembered, so later syncs only look at what is new.
    private func syncArchive(_ client: IMAPClient, account: Account, folder: String, gmail: Bool,
                             report: inout SyncReport) async throws {
        let info = try await client.select(folder)
        if let known = try store.uidValidity(account: account.id, folder: folder), known != info.uidValidity {
            try store.deleteFolder(account: account.id, folder: folder)
        }
        try store.setUIDValidity(info.uidValidity, account: account.id, folder: folder)
        let local = try store.uids(account: account.id, folder: folder)
        let server = info.exists == 0 ? [] : try await client.uidSearch()
        let serverSet = Set(server)

        // Gone from the archive: deleted elsewhere. (Mail moved back to the inbox was moved there by the inbox sync.)
        for (uid, id) in local where !serverSet.contains(uid) {
            try store.delete(id)
            report.removed += 1
        }

        let seen = try store.seenUID(account: account.id, folder: folder)
        let candidates = server.filter { $0 > seen && local[$0] == nil }.sorted(by: >)
        var wanted: [UInt32] = []
        for batch in stride(from: 0, to: candidates.count, by: 200).map({ Array(candidates[$0..<min($0 + 200, candidates.count)]) }) {
            let headers = try await client.uidFetch(batch, items: "UID FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]")
            var ids: [UInt32: String] = [:]
            for message in headers where !message.flags.contains("\\Draft") {
                ids[message.uid] = message.raw.map(Self.messageID) ?? ""
            }
            let known = try store.knownMessageIDs(account: account.id, among: ids.values.filter { !$0.isEmpty })
            wanted += ids.filter { $0.value.isEmpty || !known.contains($0.value) }.keys
        }
        let own = account.email.lowercased()
        // Drafts kept before this rule: gone.
        for (id, path) in try store.ownCopies(account: account.id, folder: folder) {
            if let raw = try? Data(contentsOf: URL(fileURLWithPath: path)), Self.isDraft(MIME.parse(raw)) {
                try store.delete(id)
                try? FileManager.default.removeItem(atPath: path)
                report.removed += 1
            }
        }
        try await download(wanted.sorted(by: >), client, account: account, folder: folder, uidValidity: info.uidValidity,
                           gmail: gmail, archived: true, report: &report,
                           skip: { $0.from?.address.lowercased() == own && Self.isDraft($0) }) { parsed in
            parsed.from?.address.lowercased() == own ? .sent : .inbox
        }
        if let highest = server.max() { try store.setSeenUID(highest, account: account.id, folder: folder) }
    }

    /// A mail of the user's own that never went out: no server ever added a "Received" line. Gmail's All Mail
    /// holds drafts without the \Draft flag, so this is how they are told apart from sent mail that only lives
    /// there (sent from Outlook, or before the Sent label existed).
    static func isDraft(_ mail: ParsedMail) -> Bool {
        !mail.headers.contains { $0.name.caseInsensitiveCompare("Received") == .orderedSame }
    }

    /// The Message-ID from a "Message-ID: <…>" header block.
    static func messageID(_ header: Data) -> String {
        let text = String(decoding: header, as: UTF8.self)
        guard let start = text.firstIndex(of: "<"), let end = text[start...].firstIndex(of: ">") else { return "" }
        return String(text[start...end])
    }

    /// Called after every batch of fetched mail, so the app can show new mail while a long first sync runs.
    public var progress: (@Sendable (SyncReport) async -> Void)?
}

/// Changes made on the server on behalf of the user.
public enum MailActions {
    public static func setFlag(_ flag: String, on: Bool, messages: [MailMessage], account: Account) async throws {
        try await withFolders(messages, account: account) { client, _, folder, items in
            _ = try await client.select(folder)
            try await client.uidStore(items.map(\.uid), add: on, flags: [flag])
        }
    }

    public enum MoveTarget: Sendable { case archive, trash, junk, inbox }

    /// Moves messages on the server. Returns new (folder, uid) locations per message id.
    public static func move(_ messages: [MailMessage], to target: MoveTarget, account: Account) async throws -> [Int64: (String, UInt32?)] {
        var locations: [Int64: (String, UInt32?)] = [:]
        try await withFolders(messages, account: account) { client, folders, folder, items in
            let destination: String? = switch target {
            case .archive: folders.archive
            case .trash: folders.trash
            case .junk: folders.junk
            case .inbox: folders.inbox
            }
            guard let destination else {
                throw IMAPError.unexpected("No \(target) folder found on the server.")
            }
            guard destination != folder else { return }
            _ = try await client.select(folder)
            let mapping = try await client.uidMove(items.map(\.uid), to: destination)
            for item in items { locations[item.id] = (destination, mapping[item.uid]) }
        }
        return locations
    }

    public static func appendToSent(_ data: Data, account: Account) async throws {
        let client = try await SyncEngine.session(for: account)
        defer { Task { await client.logout() } }
        guard let sent = FolderMap.detect(try await client.listMailboxes()).sent else { return }
        try await client.append(data, to: sent, flags: ["\\Seen"])
    }

    private static func withFolders(
        _ messages: [MailMessage], account: Account,
        _ body: (IMAPClient, FolderMap, String, [MailMessage]) async throws -> Void
    ) async throws {
        // Messages without a known server location (folder "" or uid 0) are local only.
        let onServer = messages.filter { !$0.folder.isEmpty && $0.uid > 0 }
        guard !onServer.isEmpty else { return }
        let client = try await SyncEngine.session(for: account)
        do {
            let folders = FolderMap.detect(try await client.listMailboxes())
            for (folder, items) in Dictionary(grouping: onServer, by: \.folder) {
                try await body(client, folders, folder, items)
            }
            await client.logout()
        } catch {
            await client.close()
            throw error
        }
    }
}
