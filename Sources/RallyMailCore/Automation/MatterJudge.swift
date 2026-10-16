import Foundation

/// Asks the local model whether two topics are one matter, for the pairs the rules could not decide (same
/// organisation or person with a similar subject). The model gets two short cards, never the whole mail, and
/// answers yes, no or unsure; the answer only decides whether a suggestion is shown, nothing is merged by it.
public enum MatterJudge {
    public enum Verdict: String, Sendable, Codable {
        case same, different, unsure
    }

    static let system = """
    You compare two email conversations of one person and decide whether they are about the same matter: the \
    same case, order, booking, application or project, so that they belong in one chat. Different bookings, \
    invoices or events with the same company are different matters, even when the subjects look alike. Answer only \
    with JSON: {"same": "yes" | "no" | "unsure", "why": "a few words"}. Say "unsure" when the cards do not tell.
    """

    static let grammar = #"""
    root ::= "{" ws "\"same\":" ws answer "," ws "\"why\":" ws "\"" char{0,80} "\"" ws "}"
    answer ::= "\"yes\"" | "\"no\"" | "\"unsure\""
    char ::= [^"\\\x00-\x1f]
    ws ::= [ \n]?
    """#

    /// A short card: title, people, when, and the first lines of the first and the last mail.
    public static func card(_ matter: Matter, messages: [MailMessage], isMe: (EmailAddress) -> Bool) -> String {
        let people = matter.people(isMe: isMe).prefix(4).map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }
        let sorted = messages.sorted { $0.date < $1.date }
        func excerpt(_ message: MailMessage?) -> String {
            guard let message else { return "" }
            var text = message.chatText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if text.count > 240 { text = String(text.prefix(240)) + " …" }
            return "\(DateText.short(message.date)) \(isMe(message.from) ? "me" : message.from.displayName): \(text)"
        }
        let span = sorted.first.map { first in
            DateText.short(first.date) + (sorted.count > 1 ? " – " + DateText.short(matter.lastDate) : "")
        } ?? ""
        var lines = ["Title: \(matter.title)", "People: \(people.joined(separator: ", "))", "When: \(span), \(sorted.count) mails"]
        lines.append("First mail: " + excerpt(sorted.first))
        if sorted.count > 1 { lines.append("Last mail: " + excerpt(sorted.last)) }
        return lines.joined(separator: "\n")
    }

    static func prompt(a: String, b: String, reason: String) -> String {
        """
        Conversation A:
        \(a)

        Conversation B:
        \(b)

        What they share: \(reason)
        Are A and B the same matter?
        """
    }

    static func parse(_ json: String) throws -> Verdict {
        struct Answer: Decodable { var same: String }
        switch try JSONDecoder().decode(Answer.self, from: Data(json.utf8)).same {
        case "yes": return .same
        case "no": return .different
        default: return .unsure
        }
    }

    public static func judge(a: String, b: String, reason: String, model: LocalModel) async throws -> Verdict {
        try parse(try await model.complete(system: system, user: prompt(a: a, b: b, reason: reason), grammar: grammar, maxTokens: 60))
    }
}
