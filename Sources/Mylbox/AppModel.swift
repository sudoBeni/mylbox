import AppKit
import Foundation
import MylboxCore
import Observation

enum SidebarItem: Hashable {
    case inbox, needsReply, flagged, sent, archive, all
    case category(MailCategory)
    case space(UUID)

    var filter: MailFilter {
        switch self {
        case .inbox: .inbox
        case .needsReply: .needsReply
        case .flagged: .flagged
        case .sent: .sent
        case .archive: .archive
        case .all: .all
        case .category(let category): .category(category)
        case .space(let id): .space(id)
        }
    }
}

struct ComposeDraft: Identifiable {
    let id = UUID()
    var accountID: UUID?
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: String?
    var attachments: [OutgoingAttachment] = []
    /// The local message this draft answers; its "needs reply" mark is cleared after sending.
    var answering: Int64?
}

@MainActor
@Observable
final class AppModel {
    private(set) var config: AppConfig
    let store: MailStore
    private let configStore = ConfigStore()

    var selection: SidebarItem = .inbox { didSet { selectedIDs = []; reload() } }
    var search = "" { didSet { reload() } }
    var selectedIDs: Set<Int64> = []
    private(set) var messages: [MailMessage] = []
    private(set) var counts: [MailFilter: Int] = [:]

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var accountErrors: [UUID: String] = [:]
    var banner: String?
    var compose: ComposeDraft?
    var ruleDraft: Rule?

    private var syncTimer: Timer?
    private var exportTask: Task<Void, Never>?

    init() {
        config = configStore.load()
        do {
            store = try MailStore()
        } catch {
            fatalError("Cannot open the mylbox database: \(error.localizedDescription)")
        }
        reload()
        startTimer()
        LocalModelCatalog.removeUnusedFiles()
        Task { await syncAll() }
        // llama.cpp must release its Metal resources before the process exits, or it aborts on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.localModel = nil }
        }
    }

    // MARK: Config

    func updateConfig(_ change: (inout AppConfig) -> Void) {
        change(&config)
        do {
            try configStore.save(config)
        } catch {
            banner = "Could not save settings: \(error.localizedDescription)"
        }
        startTimer()
        reload()
    }

    func account(_ id: UUID) -> Account? { config.accounts.first { $0.id == id } }
    func space(_ id: UUID) -> Space? { config.spaces.first { $0.id == id } }

    func removeAccount(_ account: Account) {
        updateConfig { $0.accounts.removeAll { $0.id == account.id } }
        Keychain.delete(Keychain.passwordKey(account.id))
        Keychain.delete(Keychain.refreshTokenKey(account.id))
        try? store.deleteAccount(account.id)
        try? FileManager.default.removeItem(at: Paths.rawDirectory(account: account.id))
        reload()
    }

    func removeSpace(_ space: Space) {
        updateConfig { config in
            config.spaces.removeAll { $0.id == space.id }
            for index in config.rules.indices {
                config.rules[index].actions.removeAll { $0 == .addToSpace(space.id) }
            }
        }
        try? store.removeSpace(space.id)
        if selection == .space(space.id) { selection = .inbox }
        reload()
    }

    // MARK: Reading

    func reload() {
        do {
            messages = try store.messages(selection.filter, search: search)
            counts = try store.unreadCounts()
            let visible = Set(messages.map(\.id))
            selectedIDs = selectedIDs.filter(visible.contains)
        } catch {
            banner = error.localizedDescription
        }
    }

    var selectedMessages: [MailMessage] { messages.filter { selectedIDs.contains($0.id) } }

    var title: String {
        switch selection {
        case .inbox: "Inbox"
        case .needsReply: "Needs Reply"
        case .flagged: "Flagged"
        case .sent: "Sent"
        case .archive: "Archive"
        case .all: "All Mail"
        case .category(let category): category.displayName
        case .space(let id): space(id)?.name ?? "Space"
        }
    }

    // MARK: Sync

    private func startTimer() {
        syncTimer?.invalidate()
        let interval = TimeInterval(max(1, config.syncIntervalMinutes) * 60)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncAll() }
        }
    }

    func syncAll() async {
        guard !isSyncing, !config.accounts.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        let engine = SyncEngine(store: store, initialLimit: config.initialSyncLimit)
        await withTaskGroup(of: (UUID, String?).self) { group in
            for account in config.accounts {
                group.addTask {
                    do {
                        _ = try await engine.sync(account)
                        return (account.id, nil)
                    } catch {
                        return (account.id, error.localizedDescription)
                    }
                }
            }
            for await (id, error) in group {
                accountErrors[id] = error
            }
        }
        lastSync = Date()
        await applyRules()
        reload()
        scheduleExport()
        await runTriage()
    }

    // MARK: Automation

    /// Applies rules to messages that have not seen them yet (or to all messages when `everything` is set).
    func applyRules(everything: Bool = false) async {
        let pending: [MailMessage]
        do {
            pending = everything ? try store.messages(.all, limit: 100_000) : try store.pendingRules()
        } catch { return }
        var toArchive: [MailMessage] = []
        var toMarkRead: [MailMessage] = []
        for message in pending {
            let outcome = RuleEngine.evaluate(config.rules, message)
            for space in outcome.spaces { try? store.addToSpace(message.id, space: space) }
            if let category = outcome.category, message.categorySource != .manual {
                try? store.setCategory(message.id, category, source: .rule)
            }
            if outcome.flag, !message.isFlagged { try? store.update(message.id, flagged: true) }
            if outcome.markRead, !message.isRead { toMarkRead.append(message) }
            if outcome.archive, !message.isArchived { toArchive.append(message) }
            try? store.markRulesDone(message.id)
        }
        if !toMarkRead.isEmpty { setRead(toMarkRead, true) }
        if !toArchive.isEmpty { archive(toArchive) }
        reload()
        if everything { scheduleExport() }
    }

    private(set) var triageProgress: String?
    private(set) var modelDownloadProgress: Double?
    private(set) var modelStatus: String?
    private var localModel: (id: String, model: LocalModel)?
    private var downloadTask: Task<Void, Never>?

    var selectedModel: LocalModelInfo { LocalModelCatalog.model(config.aiModelID) }

    /// Loads the selected model once (takes a few seconds) and keeps it in memory.
    private func loadedModel() async -> LocalModel? {
        let info = selectedModel
        if let localModel, localModel.id == info.id { return localModel.model }
        guard info.isDownloaded else { return nil }
        localModel = nil
        modelStatus = "Loading \(info.name)…"
        defer { modelStatus = nil }
        do {
            let model = try await Task.detached(priority: .utility) { try LocalModel(path: info.fileURL.path) }.value
            localModel = (info.id, model)
            return model
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    func downloadModel() {
        guard modelDownloadProgress == nil else { return }
        let info = selectedModel
        modelDownloadProgress = 0
        downloadTask = Task {
            let downloader = ModelDownloader(info) { value in
                Task { @MainActor [weak self] in
                    if self?.modelDownloadProgress != nil { self?.modelDownloadProgress = value }
                }
            }
            do {
                try await downloader.download()
                modelDownloadProgress = nil
                await runTriage()
            } catch {
                modelDownloadProgress = nil
                if !Task.isCancelled { banner = "Model download failed: \(error.localizedDescription)" }
            }
        }
    }

    func cancelModelDownload() {
        downloadTask?.cancel()
        modelDownloadProgress = nil
    }

    func deleteModel(_ info: LocalModelInfo) {
        if localModel?.id == info.id { localModel = nil }
        try? FileManager.default.removeItem(at: info.fileURL)
        updateConfig { _ in }
    }

    func runTriage() async {
        guard config.aiClassificationEnabled, triageProgress == nil else { return }
        guard let pending = try? store.pendingTriage(limit: 200), !pending.isEmpty else { return }
        triageProgress = "Preparing AI…"
        defer {
            triageProgress = nil
            // Free the model's memory (a few GB) between runs; loading again takes about 2 seconds.
            localModel = nil
        }
        guard let model = await loadedModel() else { return }
        for (index, message) in pending.enumerated() {
            triageProgress = "Sorting mail \(index + 1) of \(pending.count)…"
            do {
                let result = try await TriageService.triage(message, model: model)
                try store.setTriage(message.id, category: result.category, needsReply: result.needsReply, summary: result.summary)
            } catch {
                // Keep the heuristic category and don't retry this mail forever.
                try? store.setTriage(message.id, category: nil, needsReply: false, summary: nil)
            }
            if index % 5 == 4 { reload() }
        }
        reload()
        scheduleExport()
    }

    func retriageAll() async {
        try? store.resetTriage()
        await runTriage()
    }

    // MARK: Export

    /// Exports spaces shortly after changes, coalescing bursts of edits.
    func scheduleExport() {
        exportTask?.cancel()
        exportTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            exportAll()
        }
    }

    @discardableResult
    func exportAll() -> [String] {
        var failures: [String] = []
        for space in config.spaces where space.exportFolder?.isEmpty == false {
            do {
                let messages = try store.messages(.space(space.id), limit: 100_000)
                _ = try SpaceExporter.export(space: space, messages: messages, accounts: config.accounts)
            } catch {
                failures.append("\(space.name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { banner = "Export failed – " + failures.joined(separator: "; ") }
        return failures
    }

    // MARK: Message actions

    private func perform(_ messages: [MailMessage], _ action: @escaping (Account, [MailMessage]) async throws -> Void) {
        for (accountID, items) in Dictionary(grouping: messages, by: \.accountID) {
            guard let account = account(accountID) else { continue }
            Task {
                do {
                    try await action(account, items)
                } catch {
                    banner = error.localizedDescription
                }
                reload()
            }
        }
    }

    func setRead(_ messages: [MailMessage], _ read: Bool) {
        let changed = messages.filter { $0.isRead != read }
        guard !changed.isEmpty else { return }
        for message in changed { try? store.update(message.id, read: read) }
        reload()
        perform(changed) { account, items in
            try await MailActions.setFlag("\\Seen", on: read, messages: items, account: account)
        }
    }

    func toggleFlag(_ messages: [MailMessage]) {
        let flag = !messages.allSatisfy(\.isFlagged)
        for message in messages { try? store.update(message.id, flagged: flag) }
        reload()
        perform(messages) { account, items in
            try await MailActions.setFlag("\\Flagged", on: flag, messages: items, account: account)
        }
    }

    func archive(_ messages: [MailMessage]) {
        let items = messages.filter { $0.folderRole == .inbox && !$0.isArchived }
        guard !items.isEmpty else { return }
        for message in items { try? store.update(message.id, archived: true) }
        reload()
        perform(items) { [store] account, items in
            let moved = try await MailActions.move(items, to: .archive, account: account)
            for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
        }
    }

    func unarchive(_ messages: [MailMessage]) {
        let items = messages.filter(\.isArchived)
        for message in items { try? store.update(message.id, archived: false) }
        reload()
        perform(items) { [store] account, items in
            let moved = try await MailActions.move(items, to: .inbox, account: account)
            for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
        }
    }

    func delete(_ messages: [MailMessage]) {
        for message in messages { try? store.delete(message.id) }
        reload()
        perform(messages) { account, items in
            _ = try await MailActions.move(items, to: .trash, account: account)
        }
        scheduleExport()
    }

    /// Marks mail as spam and moves it to the server's junk folder, which also trains the provider's filter.
    func markSpam(_ messages: [MailMessage]) {
        let items = messages.filter { $0.folderRole == .inbox }
        for message in items {
            try? store.setCategory(message.id, .spam, source: .manual)
            try? store.setNeedsReply(message.id, false)
            try? store.update(message.id, read: true, archived: true)
        }
        reload()
        perform(items) { [store] account, items in
            let moved = try await MailActions.move(items, to: .junk, account: account)
            for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
        }
    }

    func notSpam(_ messages: [MailMessage]) {
        for message in messages { try? store.setCategory(message.id, .primary, source: .manual) }
        unarchive(messages)
    }

    func setCategory(_ messages: [MailMessage], _ category: MailCategory) {
        for message in messages { try? store.setCategory(message.id, category, source: .manual) }
        reload()
    }

    func setNeedsReply(_ messages: [MailMessage], _ value: Bool) {
        for message in messages { try? store.setNeedsReply(message.id, value) }
        reload()
    }

    func toggleSpace(_ space: Space, for messages: [MailMessage]) {
        let add = !messages.allSatisfy { $0.spaceIDs.contains(space.id) }
        for message in messages {
            if add { try? store.addToSpace(message.id, space: space.id) } else { try? store.removeFromSpace(message.id, space: space.id) }
        }
        reload()
        scheduleExport()
    }

    /// Opens a message: marks it read after a short moment, like other mail apps.
    func opened(_ message: MailMessage) {
        guard !message.isRead else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if selectedIDs == [message.id] { setRead([message], true) }
        }
    }

    // MARK: Compose

    func newMail() {
        compose = ComposeDraft(accountID: defaultAccountID())
    }

    private func defaultAccountID(for message: MailMessage? = nil) -> UUID? {
        message?.accountID ?? config.accounts.first?.id
    }

    func reply(_ message: MailMessage, all: Bool) {
        let me = account(message.accountID)?.email.lowercased()
        var to = message.folderRole == .sent ? message.to : (message.replyTo.isEmpty ? [message.from] : message.replyTo)
        var cc: [EmailAddress] = []
        if all {
            let others = (message.to + message.cc).filter { $0.address.lowercased() != me }
            if message.folderRole == .sent { to = message.to; cc = message.cc } else { cc = others }
        }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        compose = ComposeDraft(
            accountID: defaultAccountID(for: message),
            to: to.map(\.formatted).joined(separator: ", "),
            cc: cc.map(\.formatted).joined(separator: ", "),
            subject: subject,
            body: "\n\n" + quote(message),
            inReplyTo: message.messageID,
            references: [message.references, message.messageID].filter { !$0.isEmpty }.joined(separator: " "),
            answering: message.id)
    }

    func forward(_ message: MailMessage) {
        var attachments: [OutgoingAttachment] = []
        if let raw = try? Data(contentsOf: URL(fileURLWithPath: message.rawPath)) {
            attachments = MIME.parse(raw).attachments.filter { !$0.isInline }.map {
                OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
        }
        compose = ComposeDraft(
            accountID: defaultAccountID(for: message),
            subject: "Fwd: \(message.subject)",
            body: """


            ---------- Forwarded message ----------
            From: \(message.from.formatted)
            Date: \(message.date.formatted(date: .long, time: .shortened))
            Subject: \(message.subject)
            To: \(message.to.map(\.formatted).joined(separator: ", "))

            \(readableBody(message))
            """,
            attachments: attachments)
    }

    private func readableBody(_ message: MailMessage) -> String {
        message.bodyText.isEmpty ? message.bodyHTML.map(HTMLText.plainText) ?? "" : message.bodyText
    }

    private func quote(_ message: MailMessage) -> String {
        let header = "On \(message.date.formatted(date: .long, time: .shortened)), \(message.from.displayName) wrote:"
        let quoted = readableBody(message).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        return header + "\n" + quoted
    }

    func send(_ draft: ComposeDraft) async throws {
        guard let accountID = draft.accountID, let account = account(accountID) else {
            throw ComposeError("Choose an account to send from.")
        }
        let to = MIME.parseAddressList(draft.to)
        let cc = MIME.parseAddressList(draft.cc)
        guard !to.isEmpty || !cc.isEmpty else { throw ComposeError("Add at least one recipient.") }
        let mail = OutgoingMail(from: EmailAddress(name: account.name, address: account.email), to: to, cc: cc,
                                subject: draft.subject, body: draft.body, inReplyTo: draft.inReplyTo,
                                references: draft.references, attachments: draft.attachments)
        let data = MessageBuilder.build(mail)
        let auth = try await Credentials.shared.auth(for: account)
        try await SMTPClient.send(data, from: account.email, recipients: mail.recipients, endpoint: account.smtp, auth: auth)
        if let answered = draft.answering { try? store.setNeedsReply(answered, false) }
        if !account.provider.serverSavesSentMail {
            try? await MailActions.appendToSent(data, account: account)
        }
        Task { await syncAll() }
    }
}

struct ComposeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
