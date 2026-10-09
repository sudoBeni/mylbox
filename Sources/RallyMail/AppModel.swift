import AppKit
import Foundation
import Observation
import RallyMailCore

@MainActor
@Observable
final class AppModel {
    private(set) var config: AppConfig
    let store: MailStore
    private let configStore = ConfigStore()

    // MARK: List state

    /// nil shows every space ("Open"); a space id narrows the whole list to that space.
    var spaceFilter: UUID? { didSet { earlierOffset = 0; reload() } }
    var search = "" { didSet { earlierOffset = 0; reload() } }
    var peopleOnly = false { didSet { earlierOffset = 0; reload() } }
    var attachmentsOnly = false { didSet { earlierOffset = 0; reload() } }

    /// Conversations from people that need the user, newest first.
    private(set) var open: [Conversation] = []
    /// Machine mail in Open, folded into one group per category.
    private(set) var folded: [MailCategory: [Conversation]] = [:]
    /// Mails the user sent that got no answer.
    private(set) var waiting: [Conversation] = []
    /// Everything that does not need the user anymore, paged.
    private(set) var earlier: [Conversation] = []
    private(set) var earlierHasMore = false
    private var earlierOffset = 0
    private static let earlierPage = 150
    /// Conversations matching the search box, all scopes.
    private(set) var searchResults: [Conversation] = []
    /// Open conversations per space (for the filter strip), all spaces.
    private(set) var openCounts: [UUID?: Int] = [:]
    private(set) var totalOpen = 0

    /// The highlighted row (keyboard navigation) and the conversation shown in the drawer.
    var selectedThread: String?
    var openedThread: String? { didSet { loadThread() } }
    private(set) var threadMessages: [MailMessage] = []
    /// A mail being written outside an existing conversation (⌘N, forward).
    var newDraft: MailDraft?

    var toast: Toast?
    private var toastTask: Task<Void, Never>?
    var banner: String?
    var focusSearchToken = 0

    // MARK: Sync state

    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var syncProgress: Int?
    private(set) var accountErrors: [UUID: String] = [:]

    private var syncTimer: Timer?
    private var wakeTimer: Timer?
    private var lastProgressReload = Date()
    private var exportTask: Task<Void, Never>?

    init() {
        config = configStore.load()
        do {
            store = try MailStore()
        } catch {
            fatalError("Cannot open the RallyMail database: \(error.localizedDescription)")
        }
        reload()
        startTimer()
        // Snoozed conversations come back on their own; check once a minute.
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
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
    func space(_ id: UUID?) -> Space? { id.flatMap { id in config.spaces.first { $0.id == id } } }

    var ownAddresses: Set<String> { Set(config.accounts.map { $0.email.lowercased() }) }
    func isMe(_ address: EmailAddress) -> Bool { ownAddresses.contains(address.address.lowercased()) }

    /// A person's first name, or the address, for compact labels.
    func shortName(_ address: EmailAddress) -> String {
        if isMe(address) { return "you" }
        let name = address.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return address.address }
        // "Amhof, Benjamin" → Benjamin
        if name.contains(",") { return name.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? name }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

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
            config.rules.removeAll { $0.id == space.id }
            for index in config.rules.indices {
                config.rules[index].actions.removeAll { $0 == .addToSpace(space.id) }
            }
        }
        try? store.removeSpace(space.id)
        if spaceFilter == space.id { spaceFilter = nil }
        reload()
    }

    // MARK: Reading

    func reload() {
        do {
            let now = Date()
            var all = ConversationQuery(scope: .open)
            all.limit = 100_000
            all.now = now
            let everyOpen = try store.conversations(all).filter { !$0.isSpam }
            var counts: [UUID?: Int] = [:]
            for conversation in everyOpen where !conversation.isFolded { counts[conversation.spaceID, default: 0] += 1 }
            openCounts = counts
            totalOpen = everyOpen.filter { !$0.isFolded }.count
            NSApplication.shared.dockTile.badgeLabel = totalOpen > 0 ? String(totalOpen) : nil

            let scoped = spaceFilter == nil ? everyOpen : everyOpen.filter { $0.spaceID == spaceFilter }
            open = scoped.filter { !$0.isFolded }
            folded = Dictionary(grouping: scoped.filter(\.isFolded)) { $0.category ?? .updates }

            let olderThan = now.addingTimeInterval(-Double(max(1, config.waitingDays)) * 86400)
            var waitingQuery = ConversationQuery(scope: .waiting(olderThan: olderThan), space: spaceFilter)
            waitingQuery.limit = 50
            waiting = try store.conversations(waitingQuery).filter { conversation in
                conversation.participants.contains { !isMe($0) }
            }

            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = []
                var earlierQuery = ConversationQuery(scope: .earlier, space: spaceFilter)
                earlierQuery.peopleOnly = peopleOnly
                earlierQuery.attachmentsOnly = attachmentsOnly
                earlierQuery.limit = earlierOffset + Self.earlierPage
                earlierQuery.now = now
                let page = try store.conversations(earlierQuery)
                // A conversation shown under "Waiting for" is not repeated below.
                let waitingIDs = Set(waiting.map(\.id))
                earlier = page.filter { !waitingIDs.contains($0.id) }
                earlierHasMore = page.count >= earlierQuery.limit
            } else {
                var query = ConversationQuery(scope: .all, space: spaceFilter, search: search)
                query.limit = 300
                searchResults = try store.conversations(query)
                earlier = []
                earlierHasMore = false
            }
            if let openedThread, !(try store.thread(openedThread)).isEmpty {
                threadMessages = try store.thread(openedThread)
            } else if openedThread != nil {
                self.openedThread = nil
            }
        } catch {
            banner = error.localizedDescription
        }
    }

    func loadMoreEarlier() {
        guard earlierHasMore else { return }
        earlierOffset += Self.earlierPage
        reload()
    }

    private func loadThread() {
        guard let openedThread else { threadMessages = []; return }
        threadMessages = (try? store.thread(openedThread)) ?? []
        selectedThread = openedThread
        markRead(threadMessages)
    }

    /// Rows in the order the keyboard walks them.
    var visibleThreads: [String] {
        if !searchResults.isEmpty { return searchResults.map(\.id) }
        return open.map(\.id) + waiting.map(\.id) + earlier.map(\.id)
    }

    func conversation(_ id: String) -> Conversation? {
        (open + waiting + earlier + searchResults + folded.values.flatMap { $0 }).first { $0.id == id }
    }

    func moveSelection(_ delta: Int) {
        let threads = visibleThreads
        guard !threads.isEmpty else { return }
        let current = selectedThread.flatMap { threads.firstIndex(of: $0) } ?? -1
        let next = min(max(current + delta, 0), threads.count - 1)
        selectedThread = threads[next]
        if openedThread != nil { openedThread = selectedThread }
    }

    private func markRead(_ messages: [MailMessage]) {
        let unread = messages.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard openedThread == unread.first?.threadID else { return }
            setRead(unread, true)
        }
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self.toast = nil }
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
        syncProgress = nil
        defer { isSyncing = false; syncProgress = nil }
        let engine = SyncEngine(store: store, initialLimit: config.initialSyncLimit)
        lastProgressReload = Date()
        engine.progress = { @MainActor [weak self] report in
            guard let self else { return }
            syncProgress = report.newMessages
            // Long first syncs show mail as it arrives, without reloading on every batch.
            if Date().timeIntervalSince(lastProgressReload) > 3 {
                lastProgressReload = Date()
                reload()
            }
        }
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
            // A conversation has one space; the first matching rule wins and the user can always change it.
            if let space = outcome.spaces.sorted(by: { $0.uuidString < $1.uuidString }).first {
                try? store.setSpaceIfNone(thread: message.threadID, space: space)
            }
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

    // MARK: Conversation actions

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

    private func threadMessages(_ thread: String) -> [MailMessage] {
        (try? store.thread(thread)) ?? []
    }

    private func afterRowRemoved(_ thread: String) {
        if openedThread == thread { openedThread = nil }
        if selectedThread == thread {
            let threads = visibleThreads
            if let index = threads.firstIndex(of: thread) {
                selectedThread = threads.indices.contains(index + 1) ? threads[index + 1] : threads.last
            }
        }
    }

    /// Done: the conversation leaves Open. Its mail is archived on the server and kept forever.
    func done(_ thread: String, quiet: Bool = false) {
        let messages = threadMessages(thread)
        let items = messages.filter { $0.folderRole == .inbox && !$0.isArchived }
        for message in items { try? store.update(message.id, read: true, archived: true) }
        try? store.clearNeedsReply(thread: thread)
        try? store.snooze(thread: thread, until: nil)
        try? store.dismissWaiting(thread: thread)
        let was = selectedThread
        reload()
        afterRowRemoved(thread)
        if !items.isEmpty {
            perform(items) { [store] account, items in
                let moved = try await MailActions.move(items, to: .archive, account: account)
                for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
            }
        }
        if !quiet {
            let who = conversation(thread).map { headlineName($0) } ?? "conversation"
            show(Toast(text: "Done · \(who) · kept under Earlier") { [weak self] in
                self?.reopen(thread)
                self?.selectedThread = was
            })
        }
        scheduleExport()
    }

    /// Later: hides the conversation until the next morning (or the configured hour).
    func later(_ thread: String) {
        let calendar = Calendar.current
        var wake = calendar.date(bySettingHour: config.laterHour, minute: 0, second: 0, of: Date()) ?? Date()
        if wake <= Date() { wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake }
        try? store.snooze(thread: thread, until: wake)
        reload()
        afterRowRemoved(thread)
        let when = calendar.isDateInTomorrow(wake) ? "tomorrow" : "today"
        show(Toast(text: "Later · back \(when) at \(wake.formatted(date: .omitted, time: .shortened))") { [weak self] in
            try? self?.store.snooze(thread: thread, until: nil)
            self?.reload()
        })
    }

    /// Reopen: back into Open, and back into the inbox on the server.
    func reopen(_ thread: String) {
        let messages = threadMessages(thread)
        let archived = messages.filter { $0.folderRole == .inbox && $0.isArchived && $0.category != .spam }
        // Reopening a conversation that only has sent mail, or that was fully archived, brings back its newest mail.
        let items = archived.isEmpty ? [] : [archived.max { $0.date < $1.date }!]
        for message in items { try? store.update(message.id, archived: false) }
        try? store.snooze(thread: thread, until: nil)
        reload()
        if !items.isEmpty {
            perform(items) { [store] account, items in
                let moved = try await MailActions.move(items, to: .inbox, account: account)
                for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
            }
        }
        selectedThread = thread
    }

    func clearFolded(_ category: MailCategory) {
        let items = folded[category] ?? []
        for conversation in items { done(conversation.id, quiet: true) }
        show(Toast(text: "Cleared \(items.count) · filed under Earlier") { [weak self] in
            for conversation in items { self?.reopen(conversation.id) }
        })
    }

    /// The model folded a human's mail away: bring it up as a conversation from a person.
    func markFromPerson(_ thread: String) {
        try? store.setThreadCategory(thread, .primary)
        reload()
        selectedThread = thread
    }

    func fold(_ thread: String, as category: MailCategory) {
        try? store.setThreadCategory(thread, category)
        reload()
    }

    func dismissWaiting(_ thread: String) {
        try? store.dismissWaiting(thread: thread)
        reload()
    }

    func setSpace(_ thread: String, space: UUID?, alsoSender: EmailAddress? = nil) {
        try? store.setSpace(thread: thread, space: space)
        if let space, let sender = alsoSender, !sender.address.isEmpty {
            addSenderRule(sender.address.lowercased(), space: space)
        }
        reload()
        scheduleExport()
        let name = self.space(space)?.name
        var text = name.map { "In \($0)" } ?? "Removed from space"
        if name != nil, self.space(space)?.exportFolder != nil { text += " · mirrored to the repo on next sync" }
        if alsoSender != nil, name != nil { text += " · future mail from this sender too" }
        show(Toast(text: text))
    }

    /// The space's own rule ("Add mails automatically from") shares the space's id.
    private func addSenderRule(_ address: String, space: UUID) {
        updateConfig { config in
            if let index = config.rules.firstIndex(where: { $0.id == space }) {
                if !config.rules[index].conditions.contains(where: { $0.value.lowercased() == address }) {
                    config.rules[index].conditions.append(RuleCondition(field: .from, op: .contains, value: address))
                }
                config.rules[index].matchAll = false
                config.rules[index].enabled = true
            } else {
                var rule = Rule(name: "Mails for \(self.space(space)?.name ?? "space")",
                                conditions: [RuleCondition(field: .from, op: .contains, value: address)],
                                actions: [.addToSpace(space)])
                rule.id = space
                rule.matchAll = false
                config.rules.append(rule)
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

    /// Delete is for spam and junk only; it lives in the context menu.
    func delete(_ thread: String) {
        let messages = threadMessages(thread)
        for message in messages { try? store.delete(message.id) }
        reload()
        afterRowRemoved(thread)
        perform(messages) { account, items in
            _ = try await MailActions.move(items, to: .trash, account: account)
        }
        scheduleExport()
        show(Toast(text: "Deleted · moved to the server's trash"))
    }

    /// Marks mail as spam and moves it to the server's junk folder, which also trains the provider's filter.
    func markSpam(_ thread: String) {
        let items = threadMessages(thread).filter { $0.folderRole == .inbox }
        for message in items {
            try? store.setCategory(message.id, .spam, source: .manual)
            try? store.setNeedsReply(message.id, false)
            try? store.update(message.id, read: true, archived: true)
        }
        reload()
        afterRowRemoved(thread)
        perform(items) { [store] account, items in
            let moved = try await MailActions.move(items, to: .junk, account: account)
            for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
        }
        show(Toast(text: "Marked as spam"))
    }

    // MARK: Writing

    private func defaultAccountID(for messages: [MailMessage]) -> UUID? {
        // Answer from the account that received the conversation.
        for message in messages.reversed() where message.folderRole == .inbox { return message.accountID }
        return messages.last?.accountID ?? config.accounts.first?.id
    }

    /// A reply to everyone on the newest message of a conversation, the way a room works.
    func replyDraft(for messages: [MailMessage]) -> MailDraft {
        guard let last = messages.last else { return MailDraft(accountID: config.accounts.first?.id) }
        var draft = MailDraft(accountID: defaultAccountID(for: messages), threadID: last.threadID)
        let subject = Threading.normalizedSubject(last.subject)
        draft.subject = subject.isEmpty ? "" : "Re: \(subject)"
        draft.inReplyTo = last.messageID
        draft.references = [last.references, last.messageID].filter { !$0.isEmpty }.joined(separator: " ")
        if last.folderRole == .sent {
            for address in last.to { draft.add(address, as: .to) }
            for address in last.cc { draft.add(address, as: .cc) }
        } else {
            let primary = last.replyTo.isEmpty ? [last.from] : last.replyTo
            for address in primary where !isMe(address) { draft.add(address, as: .to) }
            for address in last.to + last.cc where !isMe(address) { draft.add(address, as: .cc) }
            if draft.recipients.isEmpty { for address in primary { draft.add(address, as: .to) } }
        }
        return draft
    }

    func newMail() {
        openedThread = nil
        newDraft = MailDraft(accountID: config.accounts.first?.id)
    }

    func forward(_ message: MailMessage) {
        var attachments: [OutgoingAttachment] = []
        if let raw = try? Data(contentsOf: URL(fileURLWithPath: message.rawPath)) {
            attachments = MIME.parse(raw).attachments.filter { !$0.isInline }.map {
                OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
        }
        var draft = MailDraft(accountID: message.accountID)
        draft.subject = "Fwd: \(Threading.normalizedSubject(message.subject))"
        draft.body = """


        ---------- Forwarded message ----------
        From: \(message.from.formatted)
        Date: \(message.date.formatted(date: .long, time: .shortened))
        Subject: \(message.subject)
        To: \(message.to.map(\.formatted).joined(separator: ", "))

        \(QuoteStripper.plainBody(text: message.bodyText, html: message.bodyHTML))
        """
        draft.attachments = attachments
        openedThread = nil
        newDraft = draft
    }

    /// Quotes the newest message below the reply, so other mail clients keep their context.
    private func quoted(_ message: MailMessage) -> String {
        let header = "On \(message.date.formatted(date: .long, time: .shortened)), \(message.from.displayName) wrote:"
        let body = QuoteStripper.plainBody(text: message.bodyText, html: message.bodyHTML)
        return header + "\n" + body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    func send(_ draft: MailDraft) async throws {
        guard let accountID = draft.accountID, let account = account(accountID) else {
            throw ComposeError("Choose an account to send from.")
        }
        guard !draft.recipients.isEmpty else { throw ComposeError("Add at least one recipient.") }
        guard draft.recipients.contains(where: { $0.role != .bcc }) else {
            throw ComposeError("At least one person must be visible (To or Cc).")
        }
        var body = draft.body
        if let thread = draft.threadID, let last = threadMessages(thread).last {
            body += "\n\n" + quoted(last)
        }
        let mail = OutgoingMail(from: EmailAddress(name: account.name, address: account.email), to: draft.to, cc: draft.cc,
                                bcc: draft.bcc, subject: draft.subject, body: body, inReplyTo: draft.inReplyTo,
                                references: draft.references, attachments: draft.attachments)
        let data = MessageBuilder.build(mail)
        let auth = try await Credentials.shared.auth(for: account)
        try await SMTPClient.send(data, from: account.email, recipients: mail.recipients, endpoint: account.smtp, auth: auth)
        if let thread = draft.threadID {
            try? store.clearNeedsReply(thread: thread)
            try? store.snooze(thread: thread, until: nil)
        }
        if !account.provider.serverSavesSentMail {
            try? await MailActions.appendToSent(data, account: account)
        }
        show(Toast(text: "Sent · " + draft.audienceText(nameOf: shortName)))
        Task { await syncAll() }
    }

    func headlineName(_ conversation: Conversation) -> String {
        let others = conversation.participants.filter { !isMe($0) }
        if others.isEmpty { return conversation.participants.first.map(\.displayName) ?? "you" }
        return others.prefix(3).map(\.displayName).joined(separator: ", ") + (others.count > 3 ? " +\(others.count - 3)" : "")
    }
}

struct ComposeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
