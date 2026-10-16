import Foundation

// MARK: - Accounts

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    public var defaultSymbol: String {
        switch self {
        case .gmail: "envelope"
        case .icloud: "cloud"
        case .outlook: "briefcase"
        default: "at"
        }
    }

    case gmail, icloud, outlook, imap

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gmail: "Gmail / Google Workspace"
        case .icloud: "iCloud Mail"
        case .outlook: "Outlook / Microsoft 365"
        case .imap: "Other (IMAP)"
        }
    }

    public var defaultIMAP: ServerEndpoint {
        switch self {
        case .gmail: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls)
        case .icloud: ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .tls)
        case .outlook: ServerEndpoint(host: "outlook.office365.com", port: 993, security: .tls)
        case .imap: ServerEndpoint(host: "", port: 993, security: .tls)
        }
    }

    public var defaultSMTP: ServerEndpoint {
        switch self {
        case .gmail: ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls)
        case .icloud: ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        case .outlook: ServerEndpoint(host: "smtp.office365.com", port: 587, security: .startTLS)
        case .imap: ServerEndpoint(host: "", port: 465, security: .tls)
        }
    }

    public var defaultAuth: AuthMethod { self == .outlook ? .microsoftOAuth : .password }

    /// Whether the server stores a copy of mail sent via SMTP in the Sent folder by itself.
    public var serverSavesSentMail: Bool { self == .gmail || self == .outlook }

    public var passwordHint: String {
        switch self {
        case .gmail: "Use an app password (Google Account → Security → 2-Step Verification → App passwords)."
        case .icloud: "Use an app-specific password (account.apple.com → Sign-In and Security → App-Specific Passwords)."
        case .outlook: "Outlook signs in with Microsoft (OAuth). You need an Azure app client ID, see README."
        case .imap: "Your mailbox password or an app password from your provider."
        }
    }
}

public enum ConnectionSecurity: String, Codable, CaseIterable, Sendable {
    case tls, startTLS
}

public struct ServerEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public enum AuthMethod: String, Codable, Sendable {
    case password, microsoftOAuth
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var name: String
    public var email: String
    public var username: String
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    public var auth: AuthMethod
    public var oauthClientID: String?
    /// Other addresses that are also the user and arrive here (a school or an old address forwarded in).
    public var aliases: [String]?
    /// The badge that marks mail from this account: an SF Symbol name and a hue (0…1).
    public var symbol: String?
    public var hue: Double?

    /// The account address and its aliases, lowercased.
    public var allAddresses: Set<String> {
        Set(([email] + (aliases ?? [])).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public var badgeSymbol: String { symbol ?? provider.defaultSymbol }
    /// A hue of its own when none was chosen, so two accounts never look the same by accident.
    public var badgeHue: Double {
        hue ?? Double(id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    public init(provider: Provider, name: String, email: String) {
        self.id = UUID()
        self.provider = provider
        self.name = name
        self.email = email
        self.username = email
        self.imap = provider.defaultIMAP
        self.smtp = provider.defaultSMTP
        self.auth = provider.defaultAuth
    }
}

// MARK: - Messages

public enum MailCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Mail from people that deserves attention.
    case primary
    /// Notifications, receipts, confirmations.
    case updates
    /// Newsletters and marketing.
    case newsletters
    /// Unwanted mail: scams, phishing, unsolicited ads.
    case spam

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: "Important"
        case .updates: "Updates"
        case .newsletters: "Newsletters"
        case .spam: "Spam"
        }
    }

    public var symbol: String {
        switch self {
        case .primary: "tray"
        case .updates: "bell"
        case .newsletters: "newspaper"
        case .spam: "xmark.bin"
        }
    }
}

public enum FolderRole: String, Codable, Sendable {
    case inbox, sent
}

public enum ClassificationSource: String, Codable, Sendable {
    case heuristic, ai, rule, manual
}

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String
    public var address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    public var displayName: String { name.isEmpty ? address : name }

    public var formatted: String { name.isEmpty ? address : "\(name) <\(address)>" }
}

public struct AttachmentInfo: Codable, Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var size: Int

    public init(filename: String, mimeType: String, size: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

/// A message as stored locally.
public struct MailMessage: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var accountID: UUID
    public var folder: String
    public var folderRole: FolderRole
    public var uid: UInt32
    public var messageID: String
    public var inReplyTo: String
    public var references: String
    public var subject: String
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date
    public var snippet: String
    public var bodyText: String
    public var bodyHTML: String?
    public var attachments: [AttachmentInfo]
    public var isBulk: Bool
    public var isRead: Bool
    public var isFlagged: Bool
    public var isArchived: Bool
    public var category: MailCategory?
    public var categorySource: ClassificationSource?
    public var summary: String?
    public var needsReply: Bool
    public var spaceIDs: Set<UUID>
    public var rawPath: String
    /// All messages of one conversation share this key (see `Threading`).
    public var threadID: String = ""
    /// The model's keyword ("Jahresabrechnung") and what it asks of the user, when it said so.
    public var topic: String? = nil
    public var ask: String? = nil
    /// The topic (matter) the conversation was put into; nil while the conversation is a topic of its own.
    public var matterID: String? = nil
    /// Bcc recipients, known only for the user's own sent mail.
    public var bcc: [EmailAddress] = []

    /// The topic this message belongs to: its matter, or its own conversation.
    public var matterKey: String { matterID ?? threadID }

    /// Stable key used for export filenames, independent of folder moves.
    public var stableKey: String {
        let base = messageID.isEmpty ? "\(accountID.uuidString)/\(folder)/\(uid)" : messageID
        return StableHash.hex(base, length: 10)
    }
}

// MARK: - Conversations

/// One thread of mail, as shown in the list. Built by `MailStore.conversations`.
public struct Conversation: Identifiable, Hashable, Sendable {
    public var id: String
    public var subject: String
    public var firstDate: Date
    public var lastDate: Date
    public var messageCount: Int
    /// Messages in the inbox that are neither done (archived) nor spam.
    public var openCount: Int
    public var unreadCount: Int
    public var needsReply: Bool
    /// What the user is asked to do in it ("Hallenmiete bestätigen"), when the model said so.
    public var ask: String? = nil
    public var hasAttachments: Bool
    public var isSpam: Bool
    /// Category of the newest message; decides whether the conversation is folded (updates, newsletters).
    public var category: MailCategory?
    /// Everyone who wrote or received mail in this thread, including the user's own addresses.
    public var participants: [EmailAddress]
    public var lastMessageID: Int64
    public var lastFrom: EmailAddress
    public var lastTo: [EmailAddress]
    public var lastFolderRole: FolderRole
    public var lastSummary: String?
    public var lastSnippet: String
    public var accountID: UUID
    public var spaceID: UUID?
    public var snoozedUntil: Date?
    public var waitingDismissed: Bool
    /// When the user put this topic on their To-do (nil: not on it), and their note for it.
    public var todoSince: Date? = nil
    public var todoNote: String? = nil
    /// Open tasks: things to do outside mail, which a reply does not finish.
    public var tasks: [MailTask] = []
    public var projectID: UUID? = nil
    /// The model's keyword for the newest message ("Jahresabrechnung"), nil until it exists.
    public var lastTopic: String? = nil
    /// The topic (matter) this conversation was put into, and its name; nil while it is a topic of its own.
    public var matterID: String? = nil
    public var matterTitle: String? = nil

    /// The topic this conversation belongs to: its matter, or itself.
    public var matterKey: String { matterID ?? id }

    /// What the topic is about in a word or two: the model's keyword, or the subject until it exists.
    public var keyword: String {
        if let topic = lastTopic, !topic.isEmpty { return topic }
        return subject.isEmpty ? "(no subject)" : subject
    }

    /// The model's one-liner that follows the keyword, nil while there is none.
    public var blurb: String? {
        guard let summary = lastSummary, !summary.isEmpty, summary != keyword else { return nil }
        return summary
    }

    /// The text shown as the row's headline: the model's one-liner, or the subject until it exists.
    public var headline: String {
        if let summary = lastSummary, !summary.isEmpty { return summary }
        return subject.isEmpty ? "(no subject)" : subject
    }

    public var isFolded: Bool { category == .updates || category == .newsletters }
}

// MARK: - Tasks

/// Something to do outside mail ("Hoststar-Rechnung bezahlen"): found by the model in a mail, or set by the user
/// ("my turn"). Unlike a question, a reply does not finish it; only ticking it off does. When a mail the user sent
/// sounds like it is done, that is a suggestion, never automatic.
public struct MailTask: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case model, manual }
    public var id: Int64
    public var threadID: String
    public var text: String
    public var source: Source
    /// When the task came up: the mail's date, or when the user set it.
    public var created: Date
    /// A sent mail that sounds like the task is done, waiting for the user to confirm.
    public var doneSuggestedBy: Int64?

    public init(id: Int64, threadID: String, text: String, source: Source, created: Date, doneSuggestedBy: Int64? = nil) {
        self.id = id
        self.threadID = threadID
        self.text = text
        self.source = source
        self.created = created
        self.doneSuggestedBy = doneSuggestedBy
    }

    /// What the list shows.
    public var label: String { text.isEmpty ? "You marked this as your turn" : text }
}

// MARK: - Topics

/// Where the ball is in a topic: with the user (asked to do something), with the others (the user wrote last and
/// waits), or nowhere.
public enum Ball: String, Sendable, Hashable, CaseIterable {
    case mine, theirs, quiet
}

/// A topic ("Rechtsfall A24015827"): one or more conversations about the same matter, read as one chat. A
/// conversation that was never put together with others is a topic of its own.
public struct Matter: Identifiable, Hashable, Sendable {
    /// The matter's id, or the conversation's id for a topic of its own.
    public var id: String
    public var title: String
    public var spaceID: UUID?
    /// Its conversations, newest first.
    public var conversations: [Conversation]
    public var ball: Ball
    /// What the user is asked to do, while the ball is with them.
    public var ask: String?
    /// Who the user waits for, while the ball is with the others, or who has the user's last mail.
    public var waitingOn: EmailAddress?
    /// Open tasks in the topic, oldest first. Any of them keeps the ball with the user.
    public var tasks: [MailTask] = []

    public var lastDate: Date { conversations.first?.lastDate ?? .distantPast }
    public var unreadCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }
    public var messageCount: Int { conversations.reduce(0) { $0 + $1.messageCount } }
    public var threadIDs: [String] { conversations.map(\.id) }
    public var isFolded: Bool { conversations.allSatisfy(\.isFolded) }
    /// A conversation that was put together with others (has a matter row), not just a single conversation.
    public var isGrouped: Bool { conversations.first?.matterID != nil }

    /// Everyone in the topic but the user, the most recent first.
    public func people(isMe: (EmailAddress) -> Bool) -> [EmailAddress] {
        var seen = Set<String>()
        return conversations.flatMap { [$0.lastFrom] + $0.participants }
            .filter { !isMe($0) && !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
    }

    /// Groups conversations into topics, newest first. Spam is left out. `now` decides whether Later is over.
    public static func group(_ conversations: [Conversation], now: Date = Date(), isMe: (EmailAddress) -> Bool) -> [Matter] {
        var byKey: [String: [Conversation]] = [:]
        for conversation in conversations where !conversation.isSpam {
            byKey[conversation.matterKey, default: []].append(conversation)
        }
        return byKey.map { key, list in
            let sorted = list.sorted { $0.lastDate > $1.lastDate }
            return make(key, sorted, now: now, isMe: isMe)
        }
        .sorted { $0.lastDate > $1.lastDate }
    }

    static func make(_ key: String, _ conversations: [Conversation], now: Date, isMe: (EmailAddress) -> Bool) -> Matter {
        let newest = conversations[0]
        let awake = conversations.filter { ($0.snoozedUntil ?? .distantPast) <= now }
        let asked = awake.first { $0.needsReply && $0.openCount > 0 }
        // A reply finishes a question, not a task: open tasks keep the ball with the user.
        let tasks = awake.flatMap(\.tasks).sorted { $0.created < $1.created }
        var ball = Ball.quiet
        var ask: String?
        var waitingOn: EmailAddress?
        if newest.lastFolderRole == .sent {
            waitingOn = newest.lastTo.first { !isMe($0) } ?? newest.participants.first { !isMe($0) }
        }
        if asked != nil || !tasks.isEmpty {
            ball = .mine
            ask = asked.map { $0.ask ?? $0.lastSummary } ?? tasks.first?.label
        } else if newest.lastFolderRole == .sent, !newest.waitingDismissed, (newest.snoozedUntil ?? .distantPast) <= now {
            ball = .theirs
        } else {
            waitingOn = nil
        }
        let subject = newest.subject.isEmpty ? "(no subject)" : newest.subject
        let title = newest.matterTitle.flatMap { $0.isEmpty ? nil : $0 } ?? subject
        return Matter(id: key, title: title, spaceID: newest.spaceID, conversations: conversations,
                      ball: ball, ask: ask, waitingOn: waitingOn, tasks: tasks)
    }
}

/// Which mails the Inbox lists: every received mail, newest first, narrowed by these.
public struct FeedQuery: Hashable, Sendable {
    public var search = ""
    public var space: UUID?
    public var unreadOnly = false
    public var attachmentsOnly = false
    /// A sender's address, lowercased.
    public var from: String?
    /// Only mail older than this (jumping to a month).
    public var before: Date?
    public var limit = 300

    public init() {}
}

/// Everything with the same people, like a chat in a messenger: Reto alone is one chat, Reto and Lea together
/// another. Each conversation (topic) belongs to the chat of the people in it.
public struct Chat: Identifiable, Hashable, Sendable {
    public var id: String
    /// The people other than the user, the most active first.
    public var people: [EmailAddress]
    /// The topics of this chat, newest first.
    public var topics: [Conversation]

    public var lastDate: Date { topics.first?.lastDate ?? .distantPast }
    public var unreadCount: Int { topics.reduce(0) { $0 + $1.unreadCount } }
    /// A topic in this chat is open and waits for an answer.
    public var needsReply: Bool { topics.contains { $0.needsReply && $0.openCount > 0 } }
    /// Only updates and newsletters, no mail from people.
    public var isFolded: Bool { topics.allSatisfy(\.isFolded) }

    /// The id of the chat a conversation belongs to: "chat:" and the other people's addresses, sorted.
    public static func key(for conversation: Conversation, isMe: (EmailAddress) -> Bool) -> String {
        let others = conversation.participants.filter { !isMe($0) && !$0.address.isEmpty }
        return "chat:" + Set(others.map { $0.address.lowercased() }).sorted().joined(separator: ",")
    }

    /// Groups conversations into chats, newest chat first. `isMe` tells the user's own addresses apart.
    public static func group(_ conversations: [Conversation], isMe: (EmailAddress) -> Bool) -> [Chat] {
        var chats: [String: Chat] = [:]
        for conversation in conversations where !conversation.isSpam {
            let others = conversation.participants.filter { !isMe($0) && !$0.address.isEmpty }
            let id = key(for: conversation, isMe: isMe)
            if chats[id] == nil {
                // The sender comes first: "Reto, Lea" when Reto wrote last.
                let first = others.firstIndex { $0.address.lowercased() == conversation.lastFrom.address.lowercased() } ?? 0
                var people = others
                if !people.isEmpty { people.insert(people.remove(at: first), at: 0) }
                chats[id] = Chat(id: id, people: people, topics: [])
            }
            chats[id]?.topics.append(conversation)
        }
        return chats.values
            .map { chat in var chat = chat; chat.topics.sort { $0.lastDate > $1.lastDate }; return chat }
            .sorted { $0.lastDate > $1.lastDate }
    }
}

/// One sender of one-way mail (GitHub, Coolify, SBB): notifications to read, not conversations to answer.
public struct InfoSource: Identifiable, Hashable, Sendable {
    /// The sender's address, lowercased.
    public var id: String
    public var sender: EmailAddress
    /// Its conversations, newest first.
    public var items: [Conversation]

    public var lastDate: Date { items.first?.lastDate ?? .distantPast }
    public var unreadCount: Int { items.reduce(0) { $0 + $1.unreadCount } }

    /// Groups folded conversations (updates, newsletters) by sender, newest source first.
    public static func group(_ conversations: [Conversation], isMe: (EmailAddress) -> Bool) -> [InfoSource] {
        var sources: [String: InfoSource] = [:]
        for conversation in conversations where !conversation.isSpam {
            let sender = conversation.participants.first { !isMe($0) && !$0.address.isEmpty } ?? conversation.lastFrom
            let id = sender.address.lowercased()
            sources[id, default: InfoSource(id: id, sender: sender, items: [])].items.append(conversation)
        }
        return sources.values
            .map { source in var source = source; source.items.sort { $0.lastDate > $1.lastDate }; return source }
            .sorted { $0.lastDate > $1.lastDate }
    }
}

/// Which conversations a list shows.
public struct ConversationQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Conversations that still need the user: open mail, not snoozed.
        case open
        /// Everything else: done, later, folded away, sent. Nothing is ever deleted.
        case earlier
        /// Mails the user sent that got no answer.
        case waiting(olderThan: Date)
        /// All conversations, used for search.
        case all
        /// Topics on the user's To-do.
        case todo
    }

    public var scope: Scope
    public var space: UUID?
    /// Narrows to one project inside the court.
    public var project: UUID?
    public var search = ""
    public var peopleOnly = false
    public var attachmentsOnly = false
    public var limit = 200
    public var offset = 0
    public var now = Date()

    public init(scope: Scope, space: UUID? = nil, project: UUID? = nil, search: String = "") {
        self.scope = scope
        self.space = space
        self.project = project
        self.search = search
    }
}

// MARK: - Spaces

/// A space is a named collection of mails (e.g. "Volleyball Finance") that can be
/// mirrored as Markdown into another project's folder.
public struct Space: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var exportFolder: String?
    public var keepOutOfGit: Bool
    public var includeAttachments: Bool
    /// The projects inside this court (e.g. Cheersfeed in Slackers); each has a rule with the project's id.
    public var projects: [Project] = []

    public init(name: String, symbol: String = "folder") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.keepOutOfGit = false
        self.includeAttachments = true
    }

    // Courts saved before projects existed keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        exportFolder = try container.decodeIfPresent(String.self, forKey: .exportFolder)
        keepOutOfGit = try container.decode(Bool.self, forKey: .keepOutOfGit)
        includeAttachments = try container.decode(Bool.self, forKey: .includeAttachments)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
    }
}

/// A project inside a court. Its mail comes in by its rule (senders, domains, subject words) or by hand.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(name: String) {
        self.id = UUID()
        self.name = name
    }
}

// MARK: - Rules

public enum RuleField: String, Codable, CaseIterable, Identifiable, Sendable {
    case from, to, subject, body, anyField

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .from: "From"
        case .to: "To / Cc"
        case .subject: "Subject"
        case .body: "Body"
        case .anyField: "Anywhere"
        }
    }
}

public enum RuleOperator: String, Codable, CaseIterable, Identifiable, Sendable {
    case contains, equals, endsWith, notContains

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .contains: "contains"
        case .equals: "is"
        case .endsWith: "ends with"
        case .notContains: "does not contain"
        }
    }
}

public struct RuleCondition: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var field: RuleField
    public var op: RuleOperator
    public var value: String

    public init(field: RuleField = .from, op: RuleOperator = .contains, value: String = "") {
        self.field = field
        self.op = op
        self.value = value
    }
}

public enum RuleAction: Codable, Hashable, Sendable {
    case addToSpace(UUID)
    case setProject(UUID)
    case setCategory(MailCategory)
    case archive
    case markRead
    case flag
}

public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var matchAll: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]

    public init(name: String, conditions: [RuleCondition] = [RuleCondition()], actions: [RuleAction] = []) {
        self.id = UUID()
        self.name = name
        self.enabled = true
        self.matchAll = true
        self.conditions = conditions
        self.actions = actions
    }
}

// MARK: - Config

public struct AppConfig: Codable, Sendable {
    public var accounts: [Account] = []
    public var spaces: [Space] = []
    public var rules: [Rule] = []
    public var aiClassificationEnabled = true
    public var aiModelID = LocalModelCatalog.defaultModel.id
    /// 0 means everything: the archive is only complete when the first sync fetches all mail.
    public var initialSyncLimit = 0
    public var syncIntervalMinutes = 3
    /// Hour of the day at which "Later" brings a conversation back.
    public var laterHour = 9
    /// Days without an answer before a sent mail shows up under "Waiting for".
    public var waitingDays = 3
    /// The court for mail that may be deleted some day. Nothing in it is deleted yet; it only leaves the way.
    public var graveyardID: UUID?
    /// The court for one-way mail (notifications, receipts, newsletters): one topic per sender.
    public var infosID: UUID?
    /// Setting up (sub-court suggestions, the sorting assistant) with a cloud model through OpenRouter instead of
    /// the local one. Off unless the user turns it on; the key is in the Keychain.
    public var cloudForSetup = false
    /// The OpenRouter model id, e.g. "anthropic/claude-sonnet-…".
    public var cloudModelID = ""

    public init() {}

    // Missing keys fall back to defaults, so config files from older versions keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? defaults.accounts
        spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? defaults.spaces
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? defaults.rules
        aiClassificationEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiClassificationEnabled)
            ?? defaults.aiClassificationEnabled
        aiModelID = try container.decodeIfPresent(String.self, forKey: .aiModelID) ?? defaults.aiModelID
        initialSyncLimit = try container.decodeIfPresent(Int.self, forKey: .initialSyncLimit) ?? defaults.initialSyncLimit
        syncIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes)
            ?? defaults.syncIntervalMinutes
        laterHour = try container.decodeIfPresent(Int.self, forKey: .laterHour) ?? defaults.laterHour
        waitingDays = try container.decodeIfPresent(Int.self, forKey: .waitingDays) ?? defaults.waitingDays
        graveyardID = try container.decodeIfPresent(UUID.self, forKey: .graveyardID)
        infosID = try container.decodeIfPresent(UUID.self, forKey: .infosID)
        cloudForSetup = try container.decodeIfPresent(Bool.self, forKey: .cloudForSetup) ?? defaults.cloudForSetup
        cloudModelID = try container.decodeIfPresent(String.self, forKey: .cloudModelID) ?? defaults.cloudModelID
    }
}
