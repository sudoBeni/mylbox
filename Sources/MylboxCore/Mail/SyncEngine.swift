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
            try await syncFolder(client, account: account, folder: folders.inbox, role: .inbox, report: &report)
            if let sent = folders.sent {
                try await syncFolder(client, account: account, folder: sent, role: .sent, report: &report)
            }
            await client.logout()
        } catch {
            await client.close()
            throw error
        }
        return report
    }

    private func syncFolder(_ client: IMAPClient, account: Account, folder: String, role: FolderRole,
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

        // New messages, newest first. The first sync of a folder only fetches the most recent ones.
        var missing = server.filter { local[$0] == nil }.sorted(by: >)
        let limit = local.isEmpty ? (role == .sent ? initialLimit / 3 : initialLimit) : 2000
        missing = Array(missing.prefix(limit))
        let rawDirectory = Paths.rawDirectory(account: account.id)
        try Paths.ensure(rawDirectory)
        for batch in stride(from: 0, to: missing.count, by: 20).map({ Array(missing[$0..<min($0 + 20, missing.count)]) }) {
            let fetched = try await client.uidFetch(batch, items: "UID FLAGS INTERNALDATE BODY.PEEK[]")
            for message in fetched {
                guard let raw = message.raw else { continue }
                let folderKey = StableHash.hex(folder, length: 8)
                let rawURL = rawDirectory.appendingPathComponent("\(folderKey)-\(info.uidValidity)-\(message.uid).eml")
                try raw.write(to: rawURL, options: .atomic)
                let parsed = MIME.parse(raw, fallbackDate: message.internalDate)
                let incoming = IncomingMessage(accountID: account.id, folder: folder, folderRole: role,
                                               uid: message.uid, flags: message.flags, parsed: parsed,
                                               rawPath: rawURL.path)
                if try store.insert(incoming) != nil { report.newMessages += 1 }
            }
        }
    }
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
