import Foundation

/// Guesses the court for a topic that has none, from where the user put earlier topics with the same people.
/// No model involved: the exact same group counts most, each shared person a little.
public struct CourtSuggestions: Sendable {
    private var byChat: [String: [UUID: Int]] = [:]
    private var byPerson: [String: [UUID: Int]] = [:]
    /// Where the topics that arrived in each account went: a hint, not a rule.
    private var byAccount: [UUID: [UUID: Int]] = [:]
    /// The newest topic per court, to break ties toward the court used last.
    private var lastUsed: [UUID: Date] = [:]
    private let isMe: @Sendable (EmailAddress) -> Bool

    /// Learns from every sorted topic in `history`; topics in `ignoring` (the Graveyard) are never suggested.
    public init(history: [Conversation], ignoring: Set<UUID> = [], isMe: @escaping @Sendable (EmailAddress) -> Bool) {
        self.isMe = isMe
        for topic in history where !topic.isSpam && !topic.isFolded {
            guard let court = topic.spaceID, !ignoring.contains(court) else { continue }
            byChat[Chat.key(for: topic, isMe: isMe), default: [:]][court, default: 0] += 1
            for person in Self.others(topic, isMe: isMe) {
                byPerson[person, default: [:]][court, default: 0] += 1
            }
            byAccount[topic.accountID, default: [:]][court, default: 0] += 1
            lastUsed[court] = max(lastUsed[court] ?? .distantPast, topic.lastDate)
        }
    }

    /// The court the topic most likely belongs to, nil without any hint.
    public func suggest(for topic: Conversation) -> UUID? {
        var score: [UUID: Int] = [:]
        for (court, count) in byChat[Chat.key(for: topic, isMe: isMe)] ?? [:] { score[court, default: 0] += 3 * count }
        for person in Self.others(topic, isMe: isMe) {
            for (court, count) in byPerson[person] ?? [:] { score[court, default: 0] += count }
        }
        // The account the mail came in on nudges: one point for the court most of its topics went to, as a tie
        // breaker when people point somewhere; alone only when nearly everything from that account went there.
        if byAccount.count > 1, let courts = byAccount[topic.accountID], let favourite = courts.max(by: { $0.value < $1.value }) {
            let total = courts.values.reduce(0, +)
            if !score.isEmpty {
                score[favourite.key, default: 0] += 1
            } else if total >= 5, favourite.value * 5 >= total * 4 {
                score[favourite.key] = 1
            }
        }
        return score.max { a, b in
            a.value != b.value ? a.value < b.value : (lastUsed[a.key] ?? .distantPast) < (lastUsed[b.key] ?? .distantPast)
        }?.key
    }

    private static func others(_ topic: Conversation, isMe: (EmailAddress) -> Bool) -> Set<String> {
        Set(topic.participants.filter { !isMe($0) && !$0.address.isEmpty }.map { $0.address.lowercased() })
    }
}
