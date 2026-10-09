import Foundation

public struct Triage: Sendable, Equatable {
    public var category: MailCategory
    public var needsReply: Bool
    public var summary: String
}

/// Sorts mail with the local model: category (incl. spam), whether a reply is expected, and a one-line summary.
public enum TriageService {
    static let system = """
    You sort the email inbox of one person. Answer only with JSON.
    category:
    - "important": written personally to the recipient by a human (friends, family, clubs, colleagues, \
    landlord, authorities), or anything that needs their attention or action.
    - "updates": automated mail: receipts, invoices, orders, shipping, bank and security notifications, \
    calendar invites, account confirmations.
    - "newsletters": newsletters, marketing, promotions, product news.
    - "spam": scams, phishing, fake prize or crypto offers, unsolicited ads from unknown senders.
    needs_reply: true only if a human personally waits for an answer or action from the recipient.
    summary: one short sentence (max 20 words) saying what the email is about, in the language of the email.
    """

    /// GBNF grammar that forces exactly the JSON shape we parse.
    static let grammar = #"""
    root ::= "{" ws "\"category\":" ws category "," ws "\"needs_reply\":" ws boolean "," ws "\"summary\":" ws summary ws "}"
    category ::= "\"important\"" | "\"updates\"" | "\"newsletters\"" | "\"spam\""
    boolean ::= "true" | "false"
    summary ::= "\"" char{1,200} "\""
    char ::= [^"\\\x00-\x1f]
    ws ::= [ \n]?
    """#

    static func prompt(for message: MailMessage) -> String {
        var body = message.bodyText.isEmpty ? message.bodyHTML.map(HTMLText.plainText) ?? "" : message.bodyText
        if body.count > 2000 { body = String(body.prefix(2000)) + " …" }
        return """
        From: \(message.from.formatted)
        To: \(message.to.map(\.formatted).joined(separator: ", "))
        Mailing list / bulk: \(message.isBulk ? "yes" : "no")
        Subject: \(message.subject)

        \(body)
        """
    }

    static func parse(_ json: String, isBulk: Bool) throws -> Triage {
        struct Answer: Decodable {
            var category: String
            var needs_reply: Bool
            var summary: String
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        let category: MailCategory = switch answer.category {
        case "updates": .updates
        case "newsletters": .newsletters
        case "spam": .spam
        default: .primary
        }
        return Triage(category: category, needsReply: answer.needs_reply && !isBulk && category == .primary,
                      summary: answer.summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func triage(_ message: MailMessage, model: LocalModel) async throws -> Triage {
        let output = try await model.complete(system: system, user: prompt(for: message), grammar: grammar, maxTokens: 160)
        return try parse(output, isBulk: message.isBulk)
    }
}
