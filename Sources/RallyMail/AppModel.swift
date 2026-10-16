import AppKit
import Foundation
import Observation
import RallyMailCore

/// What the window shows below the top bar.
enum Screen: Hashable {
    /// The court: where the ball is in every topic, with Rally on top and the to-dos on the side.
    case play
    /// Every received mail, new on top, with where each one belongs.
    case inbox
    /// The courts with their sub-courts and topics (nil: the first court).
    case courts(UUID?)
    /// One topic as a chat (a matter id, or a conversation id for a topic of its own).
    case topic(String)
    /// The sorting assistant: proposed courts and topics to check and take over.
    case sorting
}

@MainActor
@Observable
final class AppModel {
    private(set) var config: AppConfig
    let store: MailStore
    private let configStore = ConfigStore()

    // MARK: State

    var screen: Screen = .play { didSet { screenChanged(from: oldValue) } }
    /// The mail shown in the reading pane on the right (Rally, Inbox, Overview, court page).
    var selectedMessage: Int64? { didSet { loadSelection() } }
    private(set) var selection: MailMessage?
    /// The topic of the selected mail, oldest first, for the reading pane.
    private(set) var selectionContext: [MailMessage] = []

    /// Every topic, newest first (spam left out).
    private(set) var matters: [Matter] = []
    private var matterIndex: [String: Int] = [:]
    /// Received mail not read yet, newest first: what Rally lists and what the Inbox shows on top.
    private(set) var fresh: [MailMessage] = []
    /// The Inbox: received mail, newest first, narrowed by the query.
    var feedQuery = FeedQuery() { didSet { if feedQuery != oldValue { loadFeed() } } }
    /// The Inbox shows only mail whose topic has no court yet.
    var inboxOnlyUnplaced = false
    private(set) var feed: [MailMessage] = []
    /// The open topic's mail, oldest first.
    private(set) var topicMessages: [MailMessage] = []
    /// A mail to scroll to and mark in the open topic.
    var focusMessage: Int64?
    /// The court suggested for a topic in none, by where earlier topics with the same people went.
    private(set) var courtSuggestions: [String: UUID] = [:]
    /// The topic a topic in no court probably continues, and the reference both share.
    private(set) var topicSuggestions: [String: MatterSuggestion] = [:]
    /// What the local model said about the suggestions the rules were unsure of, by "topic|target".
    private(set) var suggestionVerdicts: [String: MatterJudge.Verdict] = [:]
    private var judging = false
    /// How each conversation got its court ("you", "rule", "infos", …), for the Inbox's placement note.
    private(set) var placements: [String: String] = [:]
    /// The earliest deadline named in a topic's open tasks or questions, by topic.
    private(set) var dues: [String: Date] = [:]
    /// Topics about the same theme at the same time, for the side panel's "Related" pointer.
    private(set) var relatedTopics = RelatedTopics([])
    /// The sorting assistant's proposal while it is being made and checked.
    let sorting = SortingSession()
    /// Sub-courts the local model proposes for courts, while they are made and checked.
    let subCourtHelp = SubCourtHelp()
    /// Questions to Rally and its answers, this session.
    var rallyLog: [RallyEntry] = []
    let speaker = Speaker()

    /// A mail being written outside an existing topic (⌘N, forward).
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
        var loaded = configStore.load()
        if loaded.graveyardID.flatMap({ id in loaded.spaces.first { $0.id == id } }) == nil {
            let graveyard = Space(name: "Graveyard", symbol: "trash")
            loaded.graveyardID = graveyard.id
            loaded.spaces.append(graveyard)
        }
        if loaded.infosID.flatMap({ id in loaded.spaces.first { $0.id == id } }) == nil {
            let infos = Space(name: "Infos", symbol: "bell")
            loaded.infosID = infos.id
            let graveyard = loaded.spaces.firstIndex { $0.id == loaded.graveyardID } ?? loaded.spaces.endIndex
            loaded.spaces.insert(infos, at: graveyard)
        }
        do {
            store = try MailStore()
        } catch {
            fatalError("Cannot open the RallyMail database: \(error.localizedDescription)")
        }
        suggestionVerdicts = Self.loadVerdicts()
        try? configStore.save(loaded)
        config = loaded
        store.knownOwnAddresses = ownAddresses
        fileInfos()
        reload()
        startTimer()
        // Topics put off for later come back on their own; check once a minute.
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
        defer { store.knownOwnAddresses = ownAddresses }
        // Change a copy: the closure may read `config` again (e.g. via space(_:)), which would overlap the write and abort.
        var updated = config
        change(&updated)
        config = updated
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
    func isGraveyard(_ id: UUID?) -> Bool { id != nil && id == config.graveyardID }

    /// The account addresses and their aliases: everything that is the user.
    var ownAddresses: Set<String> { config.accounts.reduce(into: Set<String>()) { $0.formUnion($1.allAddresses) } }
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
        guard space.id != config.graveyardID, space.id != config.infosID else { return }
        updateConfig { config in
            config.spaces.removeAll { $0.id == space.id }
            config.rules.removeAll { $0.id == space.id }
            for index in config.rules.indices {
                config.rules[index].actions.removeAll { $0 == .addToSpace(space.id) }
            }
        }
        try? store.removeSpace(space.id)
        if screen == .courts(space.id) { screen = .courts(nil) }
        reload()
    }

    // MARK: Reading

    func reload() {
        do {
            let now = Date()
            var all = ConversationQuery(scope: .all)
            all.limit = 1_000_000
            all.now = now
            let conversations = try store.conversations(all)
            matters = Matter.group(conversations, now: now) { isMe($0) }
            matterIndex = Dictionary(uniqueKeysWithValues: matters.enumerated().map { ($1.id, $0) })
            var unread = FeedQuery()
            unread.unreadOnly = true
            unread.limit = 500
            fresh = try store.feed(unread)
            feed = try store.feed(feedQuery)

            // Suggestions for topics in no court: the court the same people's topics went to, and a topic that
            // shares a reference like a case number.
            let own = ownAddresses
            let courts = CourtSuggestions(history: conversations, ignoring: Set([config.graveyardID].compactMap { $0 })) {
                own.contains($0.address.lowercased())
            }
            let topics = MatterSuggestions(matters, references: (try? store.referenceTokens()) ?? [:],
                                           answered: (try? store.threadsWithSentMail()) ?? []) {
                own.contains($0.address.lowercased())
            }
            var byCourt: [String: UUID] = [:]
            var byTopic: [String: MatterSuggestion] = [:]
            var bundled: [(Matter, Matter)] = []
            for matter in matters where matter.spaceID == nil && !matter.isFolded {
                if let found = topics.suggest(for: matter) {
                    if found.certain, let target = self.matter(found.matter) {
                        bundled.append((matter, target))
                    } else {
                        byTopic[matter.id] = found
                    }
                }
                if let court = courts.suggest(for: matter.conversations[0]), space(court) != nil { byCourt[matter.id] = court }
            }
            courtSuggestions = byCourt
            topicSuggestions = byTopic
            // A file number in both subjects with the same organisation: the same matter, bundled without asking.
            if !bundled.isEmpty {
                for (source, target) in bundled { join(source, into: target) }
                show(Toast(text: bundled.count == 1 ? "\(bundled[0].0.title) joined \(bundled[0].1.title)" : "\(bundled.count) topics joined their matter"))
                reload()
                return
            }
            judgeSuggestions()
            placements = (try? store.placements()) ?? [:]
            dues = Self.deadlines(matters)
            relatedTopics = RelatedTopics(matters, answered: (try? store.threadsWithSentMail()) ?? []) {
                own.contains($0.address.lowercased())
            }

            let mine = matters.filter { $0.ball == .mine && !$0.isFolded }.count
            NSApplication.shared.dockTile.badgeLabel = mine > 0 ? String(mine) : nil
            if case .topic(let key) = screen {
                if let matter = matter(key) {
                    topicMessages = try store.messages(threads: matter.threadIDs)
                } else {
                    screen = .play
                }
            }
            if let selectedMessage {
                if let message = try store.message(selectedMessage) {
                    selection = message
                    selectionContext = try store.messages(threads: matter(message.matterKey)?.threadIDs ?? [message.threadID])
                } else {
                    self.selectedMessage = nil
                }
            }
        } catch {
            banner = error.localizedDescription
        }
    }

    private func loadFeed() {
        feed = (try? store.feed(feedQuery)) ?? []
    }

    private func loadSelection() {
        guard let selectedMessage, let message = try? store.message(selectedMessage) else {
            selection = nil
            selectionContext = []
            return
        }
        selection = message
        selectionContext = (try? store.messages(threads: matter(message.matterKey)?.threadIDs ?? [message.threadID])) ?? []
    }

    private func screenChanged(from old: Screen) {
        guard screen != old else { return }
        newDraft = nil
        if case .topic(let key) = screen {
            selectedMessage = nil
            topicMessages = (try? store.messages(threads: matter(key)?.threadIDs ?? store.threads(ofMatter: key))) ?? []
            // Opening a topic reads its new mail, after a moment so the "new" mark is seen.
            let unread = topicMessages.filter { !$0.isRead && $0.folderRole == .inbox }
            if !unread.isEmpty {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard self.screen == .topic(key) else { return }
                    setRead(unread, true)
                }
            }
        } else {
            topicMessages = []
            focusMessage = nil
        }
    }

    func matter(_ key: String) -> Matter? { matterIndex[key].map { matters[$0] } }
    func matter(of message: MailMessage) -> Matter? { matter(message.matterKey) }

    /// The topics of a court, newest first.
    func matters(in court: UUID?) -> [Matter] { matters.filter { $0.spaceID == court } }

    /// Opens a topic, scrolled to one of its mails when given.
    func open(topic key: String, at message: Int64? = nil) {
        focusMessage = message
        screen = .topic(key)
    }

    // MARK: Sub-courts

    /// The sub-courts of a court (e.g. Finanzen, Spielbetrieb in VBC).
    func subCourts(of court: UUID?) -> [Project] { space(court)?.projects ?? [] }

    /// The sub-court a topic is in: its newest conversation's, if that sub-court still exists in its court.
    func subCourt(of matter: Matter) -> Project? {
        guard let id = matter.conversations.first?.projectID else { return nil }
        return subCourts(of: matter.spaceID).first { $0.id == id }
    }

    /// "VBC › Finanzen", or just the court's name.
    func path(of matter: Matter) -> String? {
        guard let court = space(matter.spaceID) else { return nil }
        return subCourt(of: matter).map { "\(court.name) › \($0.name)" } ?? court.name
    }

    /// Puts a whole topic into a sub-court of its court (nil: none).
    func setSubCourt(_ key: String, _ sub: UUID?) {
        guard let matter = matter(key) else { return }
        for thread in matter.threadIDs { try? store.setProject(thread: thread, project: sub) }
        reload()
        scheduleExport()
        let name = subCourts(of: matter.spaceID).first { $0.id == sub }?.name
        show(Toast(text: name.map { "\(matter.title) is in \($0)" } ?? "\(matter.title) is in no sub-court"))
    }

    @discardableResult
    func addSubCourt(to court: UUID, named name: String) -> Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, space(court) != nil else { return nil }
        let sub = Project(name: name)
        updateConfig { config in
            if let index = config.spaces.firstIndex(where: { $0.id == court }) { config.spaces[index].projects.append(sub) }
        }
        return sub
    }

    func renameSubCourt(_ sub: UUID, in court: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updateConfig { config in
            guard let index = config.spaces.firstIndex(where: { $0.id == court }),
                  let at = config.spaces[index].projects.firstIndex(where: { $0.id == sub }) else { return }
            config.spaces[index].projects[at].name = name
        }
    }

    /// Removes a sub-court; its topics stay in the court.
    func removeSubCourt(_ sub: UUID, in court: UUID) {
        try? store.removeProject(sub)
        updateConfig { config in
            if let index = config.spaces.firstIndex(where: { $0.id == court }) { config.spaces[index].projects.removeAll { $0.id == sub } }
        }
    }

    /// The sub-court a topic probably belongs to: the one whose topics share the most people with it.
    func guessSubCourt(for matter: Matter, in court: UUID) -> Project? {
        let subs = subCourts(of: court)
        guard !subs.isEmpty else { return nil }
        let people = Set(matter.people(isMe: isMe).map { $0.address.lowercased() })
        guard !people.isEmpty else { return nil }
        var score: [UUID: Int] = [:]
        for other in matters(in: court) where other.id != matter.id {
            guard let sub = subCourt(of: other) else { continue }
            let shared = other.people(isMe: isMe).filter { people.contains($0.address.lowercased()) }.count
            if shared > 0 { score[sub.id, default: 0] += shared }
        }
        guard let best = score.max(by: { $0.value < $1.value })?.key else { return nil }
        return subs.first { $0.id == best }
    }

    // MARK: Placing new mail

    /// Where RallyMail would put a topic that has no court yet, and why.
    struct Placement {
        var court: UUID
        var sub: Project?
        /// A topic it probably continues; nil: a new topic in the court.
        var topic: String?
        var why: String
    }

    func placement(for matter: Matter) -> Placement? {
        if let suggestion = topicSuggestion(for: matter.id), let target = self.matter(suggestion.matter), let court = target.spaceID {
            return Placement(court: court, sub: subCourt(of: target), topic: target.id, why: MatterSuggestions.explain(suggestion))
        }
        if let court = courtSuggestions[matter.id] {
            return Placement(court: court, sub: guessSubCourt(for: matter, in: court), topic: nil, why: "Your topics with these people are there.")
        }
        // The same organisation (not a freemail address) as topics in a court.
        let special = Set([config.infosID, config.graveyardID].compactMap { $0 })
        let domains = Set(matter.people(isMe: isMe).compactMap(Self.organisation))
        guard !domains.isEmpty else { return nil }
        var counts: [UUID: Int] = [:]
        for other in matters where other.id != matter.id {
            guard let court = other.spaceID, !special.contains(court) else { continue }
            if other.people(isMe: isMe).contains(where: { Self.organisation($0).map(domains.contains) ?? false }) { counts[court, default: 0] += 1 }
        }
        guard let court = counts.max(by: { $0.value < $1.value })?.key, let domain = domains.first else { return nil }
        return Placement(court: court, sub: guessSubCourt(for: matter, in: court), topic: nil, why: "Others from \(domain) are there.")
    }

    /// "vbc-kriens.ch" for a company or club address; nil for freemail.
    static func organisation(_ address: EmailAddress) -> String? {
        let parts = address.address.lowercased().split(separator: "@")
        guard parts.count == 2 else { return nil }
        let domain = String(parts[1])
        let free: Set<String> = ["gmail.com", "googlemail.com", "gmx.ch", "gmx.net", "gmx.de", "bluewin.ch", "hotmail.com", "outlook.com",
                                 "icloud.com", "me.com", "mac.com", "yahoo.com", "yahoo.de", "sunrise.ch", "hispeed.ch", "protonmail.com",
                                 "proton.me", "web.de", "live.com", "msn.com", "windowslive.com"]
        return free.contains(domain) ? nil : domain
    }

    /// Takes RallyMail's suggestion for a topic in no court.
    func accept(_ placement: Placement, for key: String, quietly: Bool = false) {
        guard let matter = matter(key) else { return }
        if let topic = placement.topic, let target = self.matter(topic) {
            for thread in matter.threadIDs { move(thread: thread, toTopic: target.id) }
        } else {
            for thread in matter.threadIDs {
                try? store.setSpace(thread: thread, space: placement.court, how: "suggestion")
                try? store.setProject(thread: thread, project: placement.sub?.id)
            }
            reload()
            scheduleExport()
            if !quietly { show(Toast(text: "\(matter.title) is in \(path(of: self.matter(key) ?? matter) ?? "its court")")) }
        }
    }

    /// New topics in no court, newest first: what the Play screen shows as tiles.
    var unplaced: [Matter] {
        matters.filter { $0.spaceID == nil && !$0.isFolded && $0.unreadCount > 0 }
    }

    func acceptAllPlacements() {
        let list = unplaced.compactMap { matter in placement(for: matter).map { (matter.id, $0) } }
        for (key, placement) in list { accept(placement, for: key, quietly: true) }
        show(Toast(text: "\(list.count) topic\(list.count == 1 ? "" : "s") placed"))
    }

    /// How a mail came to be where it is, in a few words, for the Inbox.
    func placementNote(_ message: MailMessage, in matter: Matter) -> String {
        if let conversation = matter.conversations.first(where: { $0.id == message.threadID }),
           message.date.timeIntervalSince(conversation.firstDate) > 1 {
            return "automatically · same conversation"
        }
        switch placements[message.threadID] {
        case "you": return "set by you"
        case "suggestion": return "suggestion you took"
        case "rule": return "automatically · court rule"
        case "infos": return "automatically · one-way mail"
        case "sorting": return "sorting assistant"
        case "topic": return "joined \(matter.title)"
        default: return matter.conversations.count > 1 ? "automatically · same topic" : "automatically"
        }
    }

    // MARK: Deadlines

    /// The earliest date named in a topic's open tasks and questions, read by rules (`DueDate`).
    static func deadlines(_ matters: [Matter]) -> [String: Date] {
        var result: [String: Date] = [:]
        for matter in matters where matter.ball == .mine {
            var dates = matter.tasks.compactMap { DueDate.find(in: $0.text, from: $0.created) }
            for conversation in matter.conversations where conversation.needsReply {
                if let ask = conversation.ask, let date = DueDate.find(in: ask, from: conversation.lastDate) { dates.append(date) }
            }
            if let ask = matter.ask, let date = DueDate.find(in: ask, from: matter.lastDate) { dates.append(date) }
            if let earliest = dates.min() { result[matter.id] = earliest }
        }
        return result
    }

    /// The deadline of one open task, if it names one.
    func due(of task: MailTask) -> Date? { DueDate.find(in: task.text, from: task.created) }

    /// Every open task across all topics, the ones due first on top, then the oldest.
    var allTasks: [(task: MailTask, matter: Matter)] {
        let pairs = matters.flatMap { matter in matter.tasks.map { (task: $0, matter: matter) } }
        return pairs.sorted { a, b in
            let da = due(of: a.task) ?? .distantFuture, db = due(of: b.task) ?? .distantFuture
            return da != db ? da < db : a.task.created < b.task.created
        }
    }

    /// Opens the Inbox with a search (from the search field in the top bar).
    func search(_ text: String) {
        feedQuery.search = text
        if screen != .inbox { screen = .inbox }
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: Topics

    /// Puts a whole topic into a court (nil: no court). The Graveyard also quiets it.
    func setCourt(_ key: String, _ court: UUID?, how: String = "you") {
        guard let matter = matter(key) else { return }
        for thread in matter.threadIDs { try? store.setSpace(thread: thread, space: court, how: how) }
        if isGraveyard(court) { quiet(key, silently: true) }
        reload()
        scheduleExport()
        show(Toast(text: space(court).map { "\(matter.title) is in \($0.name)" } ?? "\(matter.title) is in no court"))
    }

    /// Puts all conversations of one topic into another (and its court), without reloading.
    private func join(_ source: Matter, into target: Matter) {
        var id = target.id
        if !target.isGrouped {
            id = (try? store.createMatter(title: target.title)) ?? target.id
            try? store.setMatter(threads: target.threadIDs, matter: id)
        }
        try? store.setMatter(threads: source.threadIDs, matter: id)
        for thread in source.threadIDs {
            try? store.setSpace(thread: thread, space: target.spaceID, how: "topic")
            try? store.setProject(thread: thread, project: subCourt(of: target)?.id)
        }
    }

    /// Asks the local model about the suggestions the rules were unsure of, one pair after the other. A "no"
    /// hides the suggestion; the answers are kept, so a pair is asked once.
    private func judgeSuggestions() {
        let pending = topicSuggestions.filter { suggestionVerdicts["\($0.key)|\($0.value.matter)"] == nil }
        guard !pending.isEmpty, !judging, !sortingUsesModel else { return }
        judging = true
        Task {
            defer { judging = false }
            guard let model = await loadedModel() else { return }
            let own = ownAddresses
            let isMe: (EmailAddress) -> Bool = { own.contains($0.address.lowercased()) }
            for (key, suggestion) in pending {
                guard let source = matter(key), let target = matter(suggestion.matter) else { continue }
                let a = MatterJudge.card(source, messages: (try? store.messages(threads: source.threadIDs)) ?? [], isMe: isMe)
                let b = MatterJudge.card(target, messages: (try? store.messages(threads: target.threadIDs)) ?? [], isMe: isMe)
                let verdict = (try? await MatterJudge.judge(a: a, b: b, reason: MatterSuggestions.explain(suggestion.reference), model: model)) ?? .unsure
                suggestionVerdicts["\(key)|\(suggestion.matter)"] = verdict
                Self.saveVerdicts(suggestionVerdicts)
            }
        }
    }

    /// The suggestion to show for a topic: what the rules found, unless the model said it is a different matter.
    func topicSuggestion(for key: String) -> MatterSuggestion? {
        guard let suggestion = topicSuggestions[key] else { return nil }
        return suggestionVerdicts["\(key)|\(suggestion.matter)"] == .different ? nil : suggestion
    }

    func suggestionVerdict(for key: String) -> MatterJudge.Verdict? {
        guard let suggestion = topicSuggestions[key] else { return nil }
        return suggestionVerdicts["\(key)|\(suggestion.matter)"]
    }

    private static var verdictsURL: URL { Paths.appSupport.appendingPathComponent("suggestion-verdicts.json") }

    static func loadVerdicts() -> [String: MatterJudge.Verdict] {
        guard let data = try? Data(contentsOf: verdictsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: MatterJudge.Verdict].self, from: data)) ?? [:]
    }

    static func saveVerdicts(_ verdicts: [String: MatterJudge.Verdict]) {
        if let data = try? JSONEncoder().encode(verdicts) { try? data.write(to: verdictsURL, options: .atomic) }
    }

    /// Moves one conversation into another topic (and its court).
    func move(thread: String, toTopic key: String) {
        guard let target = matter(key) else { return }
        var id = key
        if !target.isGrouped {
            // A topic of its own becomes a real topic, named as it is shown.
            id = (try? store.createMatter(title: target.title)) ?? key
            try? store.setMatter(threads: target.threadIDs, matter: id)
        }
        try? store.setMatter(threads: [thread], matter: id)
        try? store.setSpace(thread: thread, space: target.spaceID, how: "topic")
        try? store.setProject(thread: thread, project: subCourt(of: target)?.id)
        reload()
        scheduleExport()
        show(Toast(text: "Now in \(target.title)"))
    }

    /// Takes one conversation out of its topic into a topic of its own, in a court.
    func newTopic(from thread: String, in court: UUID?) {
        try? store.setMatter(threads: [thread], matter: nil)
        try? store.setSpace(thread: thread, space: court)
        reload()
        scheduleExport()
        show(Toast(text: space(court).map { "New topic in \($0.name)" } ?? "New topic"))
    }

    func rename(topic key: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let matter = matter(key) else { return }
        if matter.isGrouped {
            try? store.renameMatter(key, title: title)
        } else {
            // A topic of its own gets a matter row to carry the name; the topic keeps its place.
            try? store.ensureMatter(id: key, title: title)
            try? store.renameMatter(key, title: title)
            try? store.setMatter(threads: matter.threadIDs, matter: key)
        }
        reload()
    }

    /// The user's call on one mail: they are asked to do something (the ball is with them) or not.
    func judge(_ message: MailMessage, mine: Bool) {
        try? store.setNeedsReply(message.id, mine)
        if !mine, let matter = matter(of: message), let newest = matter.conversations.first {
            try? store.clearTodo(thread: newest.id)
        }
        reload()
        show(Toast(text: mine ? "Your turn" : "Nothing to do"))
    }

    /// The ball is with the user after all ("not right, it's my turn").
    func takeBall(_ key: String) {
        guard let newest = matter(key)?.conversations.first else { return }
        try? store.dismissWaiting(thread: newest.id)
        try? store.setTodo(thread: newest.id, note: nil)
        reload()
    }

    /// The ball is not with the user ("not right, I'm waiting").
    func giveBall(_ key: String) {
        guard let matter = matter(key) else { return }
        for thread in matter.threadIDs {
            try? store.clearNeedsReply(thread: thread)
            try? store.clearTodo(thread: thread)
        }
        reload()
    }

    /// Quiet: nothing left to do. Its mail is archived on the server and kept forever; new mail wakes it up.
    func quiet(_ key: String, silently: Bool = false) {
        guard let matter = matter(key) else { return }
        var archived: [MailMessage] = []
        for thread in matter.threadIDs {
            let items = threadMessages(thread).filter { $0.folderRole == .inbox && !$0.isArchived }
            for message in items { try? store.update(message.id, read: true, archived: true) }
            archived += items
            try? store.clearNeedsReply(thread: thread)
            try? store.clearTodo(thread: thread)
            try? store.snooze(thread: thread, until: nil)
            try? store.dismissWaiting(thread: thread)
        }
        reload()
        if !archived.isEmpty {
            perform(archived) { [store] account, items in
                let moved = try await MailActions.move(items, to: .archive, account: account)
                for (id, location) in moved { try store.move(id, toFolder: location.0, uid: location.1) }
            }
        }
        if !silently { show(Toast(text: "\(matter.title) is quiet · new mail wakes it up")) }
        scheduleExport()
    }

    /// Later: hides the topic until the next morning (or the configured hour).
    func later(_ key: String) {
        guard let matter = matter(key) else { return }
        let calendar = Calendar.current
        var wake = calendar.date(bySettingHour: config.laterHour, minute: 0, second: 0, of: Date()) ?? Date()
        if wake <= Date() { wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake }
        for thread in matter.threadIDs { try? store.snooze(thread: thread, until: wake) }
        reload()
        let when = calendar.isDateInTomorrow(wake) ? "tomorrow" : "today"
        show(Toast(text: "Later · back \(when) at \(wake.formatted(date: .omitted, time: .shortened))") { [weak self] in
            for thread in matter.threadIDs { try? self?.store.snooze(thread: thread, until: nil) }
            self?.reload()
        })
    }

    /// One-way mail (notifications, receipts, newsletters) goes to the Infos court, one topic per sender.
    func fileInfos() {
        guard let infos = config.infosID else { return }
        var all = ConversationQuery(scope: .all)
        all.limit = 1_000_000
        guard let conversations = try? store.conversations(all) else { return }
        for conversation in conversations where conversation.isFolded && conversation.spaceID == nil && !conversation.isSpam {
            let sender = conversation.participants.first { !isMe($0) && !$0.address.isEmpty } ?? conversation.lastFrom
            let id = "sender:" + sender.address.lowercased()
            try? store.ensureMatter(id: id, title: sender.displayName)
            try? store.setMatterIfNone(thread: conversation.id, matter: id)
            try? store.setSpaceIfNone(thread: conversation.id, space: infos, how: "infos")
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
        fileInfos()
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
            // A conversation has one court; the first matching rule wins and the user can always change it.
            if let space = outcome.spaces.sorted(by: { $0.uuidString < $1.uuidString }).first {
                try? store.setSpaceIfNone(thread: message.threadID, space: space)
            }
            // Rules of former projects put their mail into the project's topic.
            for project in outcome.projects.sorted(by: { $0.uuidString < $1.uuidString }) {
                try? store.ensureMatter(id: project.uuidString, title: "")
                try? store.setMatterIfNone(thread: message.threadID, matter: project.uuidString)
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
    /// The sorting assistant has the model; sorting mail waits.
    var sortingUsesModel = false
    private(set) var modelDownloadProgress: Double?
    private(set) var modelStatus: String?
    private var localModel: (id: String, model: LocalModel)?
    private var downloadTask: Task<Void, Never>?

    var selectedModel: LocalModelInfo { LocalModelCatalog.model(config.aiModelID) }

    /// Loads the selected model once (takes a few seconds) and keeps it in memory.
    func loadedModel() async -> LocalModel? {
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

    /// Frees the model's memory (a few GB); loading it again takes about two seconds.
    func releaseModel() { localModel = nil }

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
        guard config.aiClassificationEnabled, triageProgress == nil, !sortingUsesModel else { return }
        let pending = (try? store.pendingTriage(limit: 200)) ?? []
        // The user's own recent mail is read too: for tasks they took on and tasks it says are done.
        let sent = (try? store.pendingReview(since: Date().addingTimeInterval(-30 * 86400), limit: 100)) ?? []
        guard !pending.isEmpty || !sent.isEmpty else { return }
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
                // Only in CC: someone else is asked, not the user.
                let own = ownAddresses
                let onlyCC = message.cc.contains { own.contains($0.address.lowercased()) }
                    && !message.to.contains { own.contains($0.address.lowercased()) }
                try store.setTriage(message.id, category: result.category, needsReply: result.needsReply && !onlyCC,
                                    summary: result.summary, topic: result.topic, ask: result.ask)
                if !result.task.isEmpty, !onlyCC {
                    try store.addTask(thread: message.threadID, text: result.task, message: message.id, date: message.date)
                }
            } catch {
                // Keep the heuristic category and don't retry this mail forever.
                try? store.setTriage(message.id, category: nil, needsReply: false, summary: nil)
            }
            if index % 5 == 4 { reload() }
        }
        for (index, message) in sent.enumerated() {
            triageProgress = "Reading your mail \(index + 1) of \(sent.count)…"
            await review(message, model: model)
        }
        fileInfos()
        reload()
        scheduleExport()
    }

    /// One mail the user sent: a task they took on becomes a task; open tasks it sounds done with get a suggestion.
    private func review(_ message: MailMessage, model: LocalModel) async {
        defer { try? store.markReviewed(message.id) }
        let open = ((try? store.openTasks(threads: [message.threadID]))?[message.threadID] ?? []).filter { $0.created < message.date }
        let earlier = (try? store.messages(threads: [message.threadID]))?
            .filter { $0.folderRole == .inbox && $0.date < message.date }.max { $0.date < $1.date }
        guard let result = try? await TriageService.review(message, openTasks: open.map(\.label), earlier: earlier, model: model) else { return }
        for index in result.done { try? store.suggestDone(open[index].id, by: message.id) }
        if !result.task.isEmpty {
            try? store.addTask(thread: message.threadID, text: result.task, message: message.id, date: message.date)
        }
    }

    // MARK: Tasks

    func completeTask(_ task: MailTask) {
        try? store.completeTask(task.id)
        reload()
    }

    func dismissTask(_ task: MailTask) {
        try? store.dismissTask(task.id)
        reload()
        show(Toast(text: "Not a task"))
    }

    func rejectDoneSuggestion(_ task: MailTask) {
        try? store.rejectDoneSuggestion(task.id)
        reload()
    }

    /// Open tasks of the topic a conversation belongs to.
    func openTasks(thread: String) -> [MailTask] {
        matters.first { $0.threadIDs.contains(thread) }?.tasks ?? []
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

    // MARK: Mail actions

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

    func setRead(_ messages: [MailMessage], _ read: Bool) {
        let changed = messages.filter { $0.isRead != read }
        guard !changed.isEmpty else { return }
        for message in changed { try? store.update(message.id, read: read) }
        reload()
        perform(changed) { account, items in
            try await MailActions.setFlag("\\Seen", on: read, messages: items, account: account)
        }
    }

    /// Seen: the mail leaves the new ones; it stays in its topic.
    func markSeen(_ messages: [MailMessage]) { setRead(messages, true) }

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
    func delete(thread: String) {
        let messages = threadMessages(thread)
        for message in messages { try? store.delete(message.id) }
        if messages.contains(where: { $0.id == selectedMessage }) { selectedMessage = nil }
        reload()
        perform(messages) { account, items in
            _ = try await MailActions.move(items, to: .trash, account: account)
        }
        scheduleExport()
        show(Toast(text: "Deleted · moved to the server's trash"))
    }

    /// Marks mail as spam and moves it to the server's junk folder, which also trains the provider's filter.
    func markSpam(thread: String) {
        let items = threadMessages(thread).filter { $0.folderRole == .inbox }
        for message in items {
            try? store.setCategory(message.id, .spam, source: .manual)
            try? store.setNeedsReply(message.id, false)
            try? store.update(message.id, read: true, archived: true)
        }
        if items.contains(where: { $0.id == selectedMessage }) { selectedMessage = nil }
        reload()
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

    func newMail(to people: [EmailAddress] = []) {
        var draft = MailDraft(accountID: config.accounts.first?.id)
        for person in people { draft.add(person, as: .to) }
        newDraft = draft
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
            // Tasks stay: a reply does not pay the invoice. The composer's "done" toggle ticks them off.
            reload()
        }
        if !account.provider.serverSavesSentMail {
            try? await MailActions.appendToSent(data, account: account)
        }
        show(Toast(text: "Sent · " + draft.audienceText(nameOf: shortName)))
        Task { await syncAll() }
    }

    /// "Reto, Lea" for a topic or conversation: the others in it.
    func names(_ people: [EmailAddress]) -> String {
        if people.isEmpty { return "you" }
        return people.prefix(3).map(\.displayName).joined(separator: ", ") + (people.count > 3 ? " +\(people.count - 3)" : "")
    }
}

struct ComposeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
