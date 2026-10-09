import Foundation

// MARK: - Accounts

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
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

    /// The text shown as the row's headline: the model's one-liner, or the subject until it exists.
    public var headline: String {
        if let summary = lastSummary, !summary.isEmpty { return summary }
        return subject.isEmpty ? "(no subject)" : subject
    }

    public var isFolded: Bool { category == .updates || category == .newsletters }
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
    }

    public var scope: Scope
    public var space: UUID?
    public var search = ""
    public var peopleOnly = false
    public var attachmentsOnly = false
    public var limit = 200
    public var offset = 0
    public var now = Date()

    public init(scope: Scope, space: UUID? = nil, search: String = "") {
        self.scope = scope
        self.space = space
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

    public init(name: String, symbol: String = "folder") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.keepOutOfGit = false
        self.includeAttachments = true
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
    }
}
