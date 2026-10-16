import Foundation

/// Fast, deterministic first guess at a category, used until (or instead of) the AI.
public enum Heuristics {
    static let automatedSenders = ["noreply", "no-reply", "donotreply", "do-not-reply", "notification",
                                   "mailer-daemon", "postmaster", "alerts@", "alert@", "billing@", "invoice@", "updates@"]

    public static func category(from: EmailAddress?, isBulk: Bool, subject: String) -> MailCategory {
        let address = from?.address.lowercased() ?? ""
        if isBulk {
            return automatedSenders.contains(where: address.contains) && !address.contains("news") ? .updates : .newsletters
        }
        if automatedSenders.contains(where: address.contains) { return .updates }
        return .primary
    }
}

public enum RuleEngine {
    public static func matches(_ rule: Rule, _ message: MailMessage) -> Bool {
        guard rule.enabled, !rule.conditions.isEmpty else { return false }
        let results = rule.conditions.map { matches($0, message) }
        return rule.matchAll ? results.allSatisfy { $0 } : results.contains(true)
    }

    static func matches(_ condition: RuleCondition, _ message: MailMessage) -> Bool {
        let needle = condition.value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        let haystacks: [String]
        switch condition.field {
        case .from: haystacks = [message.from.address, message.from.name]
        case .to: haystacks = (message.to + message.cc).flatMap { [$0.address, $0.name] }
        case .subject: haystacks = [message.subject]
        case .body: haystacks = [message.bodyText]
        case .anyField:
            haystacks = [message.from.formatted, message.subject, message.bodyText] + (message.to + message.cc).map(\.formatted)
        }
        let values = haystacks.map { $0.lowercased() }
        switch condition.op {
        case .contains: return values.contains { $0.contains(needle) }
        case .notContains: return !values.contains { $0.contains(needle) }
        case .equals: return values.contains { $0 == needle }
        case .endsWith: return values.contains { $0.hasSuffix(needle) }
        }
    }

    public struct Outcome: Sendable {
        public var spaces: Set<UUID> = []
        public var projects: Set<UUID> = []
        public var category: MailCategory?
        public var archive = false
        public var markRead = false
        public var flag = false

        public var isEmpty: Bool { spaces.isEmpty && projects.isEmpty && category == nil && !archive && !markRead && !flag }
    }

    public static func evaluate(_ rules: [Rule], _ message: MailMessage) -> Outcome {
        var outcome = Outcome()
        for rule in rules where matches(rule, message) {
            for action in rule.actions {
                switch action {
                case .addToSpace(let space): outcome.spaces.insert(space)
                case .setProject(let project): outcome.projects.insert(project)
                case .setCategory(let category): outcome.category = category
                case .archive: outcome.archive = message.folderRole == .inbox
                case .markRead: outcome.markRead = true
                case .flag: outcome.flag = true
                }
            }
        }
        return outcome
    }
}
