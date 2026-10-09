import Foundation

public struct Triage: Sendable, Equatable {
    public var category: MailCategory
    public var needsReply: Bool
    public var summary: String
}

/// Sorts mail with the local model: category (incl. spam), whether a reply is expected, and a one-line summary.
public enum TriageService {
    // The model writes the summary and the sender type first, then decides: small models classify
    // much better after describing the mail than when they have to pick a category immediately.
    static let system = """
    You sort the email inbox of one person. Answer only with JSON in this order:
    1. summary: one short sentence (max 20 words) saying what the email is about, in the language of the email.
    2. sender: "person" if a real human wrote this email personally to the recipient, "company" if it is an \
    automated or mass email from a company or service, "suspicious" if it looks like a scam or phishing.
    3. category:
       - "important": a person wrote personally (friends, family, clubs, colleagues, landlord, authorities), \
    or the recipient must act.
       - "updates": automated messages about the recipient's own accounts or purchases: orders, shipping, \
    receipts, invoices, bank and security notices, confirmations, reminders.
       - "newsletters": newsletters, marketing, sales, promotions, product news.
       - "spam": scams, phishing (fake account warnings, links to look-alike domains, urgent password \
    requests), prize or crypto offers, unwanted ads from unknown senders.
    4. needs_reply: true only if a person personally waits for an answer from the recipient.

    Examples:
    From "Anna Keller <anna.keller@gmx.ch>", subject "Znacht am Samstag?" →
    {"summary": "Anna fragt, ob man am Samstag zusammen essen geht.", "sender": "person", "category": "important", "needs_reply": true}
    From "SBB <noreply@sbb.ch>", subject "Ihr Ticket" →
    {"summary": "Das gekaufte Zugticket ist angehängt.", "sender": "company", "category": "updates", "needs_reply": false}
    From "IKEA <news@ikea.ch>", subject "Neu im Herbst: 20% auf Sofas" →
    {"summary": "IKEA wirbt mit Rabatten auf Sofas.", "sender": "company", "category": "newsletters", "needs_reply": false}
    From "Swisscom Service <alert@swisscom-secure-login.net>", subject "Konto gesperrt" →
    {"summary": "Angebliche Kontosperre mit Aufforderung, das Passwort über einen Link zu bestätigen.", "sender": "suspicious", "category": "spam", "needs_reply": false}
    """

    /// GBNF grammar that forces exactly the JSON shape we parse.
    static let grammar = #"""
    root ::= "{" ws "\"summary\":" ws summary "," ws "\"sender\":" ws sender "," ws "\"category\":" ws category "," ws "\"needs_reply\":" ws boolean ws "}"
    sender ::= "\"person\"" | "\"company\"" | "\"suspicious\""
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
            var summary: String
            var sender: String?
            var category: String
            var needs_reply: Bool
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        var category: MailCategory = switch answer.category {
        case "updates": .updates
        case "newsletters": .newsletters
        case "spam": .spam
        default: .primary
        }
        // A mail the model itself calls suspicious is never shown as important.
        if answer.sender == "suspicious" { category = .spam }
        // Mass mail is not personal, even if the model thinks so.
        if category == .primary, isBulk || answer.sender == "company" { category = isBulk ? .newsletters : .updates }
        return Triage(category: category, needsReply: answer.needs_reply && category == .primary,
                      summary: answer.summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func triage(_ message: MailMessage, model: LocalModel) async throws -> Triage {
        let output = try await model.complete(system: system, user: prompt(for: message), grammar: grammar, maxTokens: 180)
        return try parse(output, isBulk: message.isBulk)
    }
}
