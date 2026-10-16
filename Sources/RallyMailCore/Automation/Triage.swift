import Foundation

public struct Triage: Sendable, Equatable {
    public var category: MailCategory
    public var needsReply: Bool
    public var summary: String
    /// One to three words naming what the mail is about, shown before the summary.
    public var topic: String = ""
    /// What the recipient is asked to do ("Hallenmiete bestätigen"), empty when nothing; this is what makes it "Reply".
    public var ask: String = ""
    /// Something to do outside mail ("Rechnung bezahlen bis 23.10."), which a reply does not finish; empty when nothing.
    public var task: String = ""
}

/// What a mail the user sent says: a task they took on, and which open tasks it reports as done.
public struct SentReview: Sendable, Equatable {
    public var task: String = ""
    /// Positions (from 0) in the open tasks that were passed in.
    public var done: [Int] = []
}

/// Sorts mail with the local model: category (incl. spam), whether a reply is expected, and a one-line summary.
public enum TriageService {
    // The model writes the summary and the sender type first, then decides: small models classify
    // much better after describing the mail than when they have to pick a category immediately.
    static let system = """
    You sort the email inbox of one person. Answer only with JSON in this order:
    1. summary: one short sentence (max 20 words) saying what the email is about, in the language of the email.
    2. topic: a keyword of one to three words naming what the email is about, in the language of the email.
    3. sender: "person" if a real human wrote this email personally to the recipient, "company" if it is an \
    automated or mass email from a company or service, "suspicious" if it looks like a scam or phishing.
    4. category:
       - "important": a person wrote personally (friends, family, clubs, colleagues, landlord, authorities), \
    or the recipient must act.
       - "updates": automated messages about the recipient's own accounts or purchases: orders, shipping, \
    receipts, invoices, bank and security notices, confirmations, reminders.
       - "newsletters": newsletters, marketing, sales, promotions, product news.
       - "spam": scams, phishing (fake account warnings, links to look-alike domains, urgent password \
    requests), prize or crypto offers, unwanted ads from unknown senders.
    5. ask: what the recipient personally is asked to do, answer or decide, in a few words in the language of \
    the email (e.g. "Hallenmiete bestätigen bis Freitag"). Only a real request to the recipient: a question to \
    them, a task, a decision, a deadline, something to send, pay, confirm, sign or hand in. Empty "" if the email \
    only informs, thanks, confirms, greets, answers the recipient's own question, is a general announcement to a \
    group, or asks nothing of the recipient. When in doubt, empty.
    6. task: something the recipient must do themselves outside of answering this email: pay, sign, send or upload \
    a document, book, cancel, buy, bring, register. A few words in the language of the email, with the deadline if \
    there is one (e.g. "Rechnung CHF 49 bezahlen bis 23.10."). Empty "" if the only thing asked is an answer or a \
    decision, or if nothing is to be done (receipts, confirmations, paid invoices, debit notices). When in doubt, empty.

    Examples:
    From "Anna Keller <anna.keller@gmx.ch>", subject "Znacht am Samstag?" →
    {"summary": "Anna fragt, ob man am Samstag zusammen essen geht.", "topic": "Znacht Samstag", "sender": "person", "category": "important", "ask": "Zusagen für Znacht am Samstag", "task": ""}
    From "SBB <noreply@sbb.ch>", subject "Ihr Ticket" →
    {"summary": "Das gekaufte Zugticket ist angehängt.", "topic": "Zugticket", "sender": "company", "category": "updates", "ask": "", "task": ""}
    From "Hoststar <order@hoststar.ch>", subject "Rechnung: Erneuerung Domainregistrierung" →
    {"summary": "Rechnung über CHF 15 für die Verlängerung der Domain, zahlbar in 30 Tagen.", "topic": "Domain-Rechnung", "sender": "company", "category": "updates", "ask": "", "task": "Domain-Rechnung CHF 15 bezahlen"}
    From "IKEA <news@ikea.ch>", subject "Neu im Herbst: 20% auf Sofas" →
    {"summary": "IKEA wirbt mit Rabatten auf Sofas.", "topic": "Sofa-Rabatt", "sender": "company", "category": "newsletters", "ask": "", "task": ""}
    From "Swisscom Service <alert@swisscom-secure-login.net>", subject "Konto gesperrt" →
    {"summary": "Angebliche Kontosperre mit Aufforderung, das Passwort über einen Link zu bestätigen.", "topic": "Kontosperre", "sender": "suspicious", "category": "spam", "ask": "", "task": ""}
    From "Reto Kaufmann <reto@vbc-example.ch>", subject "Re: Training Donnerstag" →
    {"summary": "Reto bedankt sich und bestätigt, dass er am Donnerstag dabei ist.", "topic": "Training Donnerstag", "sender": "person", "category": "important", "ask": "", "task": ""}
    From "Lea Brunner <lea@vbc-example.ch>", subject "Anmeldung Turnier" →
    {"summary": "Lea bittet darum, das Anmeldeformular für das Turnier bis Freitag unterschrieben zurückzuschicken.", "topic": "Turnieranmeldung", "sender": "person", "category": "important", "ask": "Anmeldeformular zurückschicken", "task": "Anmeldeformular unterschreiben und bis Freitag schicken"}
    From "Sandra Huber <praesidentin@vbc-example.ch>", subject "Infos zum Turnier" →
    {"summary": "Sandra informiert alle Mitglieder über Zeitplan und Treffpunkt des Turniers.", "topic": "Turnier-Infos", "sender": "person", "category": "important", "ask": "", "task": ""}
    """

    /// GBNF grammar that forces exactly the JSON shape we parse.
    static let grammar = #"""
    root ::= "{" ws "\"summary\":" ws summary "," ws "\"topic\":" ws topic "," ws "\"sender\":" ws sender "," ws "\"category\":" ws category "," ws "\"ask\":" ws ask "," ws "\"task\":" ws task ws "}"
    sender ::= "\"person\"" | "\"company\"" | "\"suspicious\""
    category ::= "\"important\"" | "\"updates\"" | "\"newsletters\"" | "\"spam\""
    summary ::= "\"" char{1,200} "\""
    topic ::= "\"" char{1,40} "\""
    ask ::= "\"" char{0,80} "\""
    task ::= "\"" char{0,80} "\""
    char ::= [^"\\\x00-\x1f]
    ws ::= [ \n]?
    """#

    static func prompt(for message: MailMessage) -> String {
        // What the sender newly wrote (or forwarded), not the quoted history; the full text when that is too short to tell.
        var body = message.chatText
        if body.count < 80 { body = message.fullText }
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
            var topic: String?
            var sender: String?
            var category: String
            var ask: String?
            var task: String?
            /// Older answers had a yes/no instead of the ask.
            var needs_reply: Bool?
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
        let ask = cleaned(answer.ask)
        let task = cleaned(answer.task)
        let asked = answer.ask.map { _ in !ask.isEmpty } ?? (answer.needs_reply ?? false)
        return Triage(category: category, needsReply: asked && category == .primary,
                      summary: answer.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                      topic: (answer.topic ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                      ask: category == .primary ? ask : "",
                      // Invoices and forms from companies are tasks too; ads and spam never are.
                      task: category == .primary || category == .updates ? task : "")
    }

    /// Trimmed, and placeholders small models write instead of leaving it empty ("keine") become empty.
    static func cleaned(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["none", "nothing", "n/a", "na", "keine", "nichts", "-", "aucune", "rien"].contains(trimmed.lowercased()) ? "" : trimmed
    }

    // MARK: Mail the user sent

    static let reviewSystem = """
    You read an email that one person wrote and sent. Answer only with JSON:
    1. task: something the writer takes on to do themselves outside of email, in a few words in the language of \
    the email (e.g. "Hoststar-Rechnung bezahlen", "Unterlagen bis Freitag schicken"). Also when they accept \
    something that means work for them, like answering "ja, die Rechnung ist für mich" to an invoice (→ pay it). \
    Empty "" if they only answer, thank, ask or inform. When in doubt, empty.
    2. done: the numbers of the open tasks listed in the message that this email says are already done \
    ("habe bezahlt", "ist erledigt", "anbei das unterschriebene Formular"). [] if none. When in doubt, [].

    Examples:
    Open tasks: 1. Rechnung CHF 49 bezahlen. Earlier mail: "Ist diese Rechnung für dich?" Email: "Ja, das ist für mich, danke!" →
    {"task": "Rechnung CHF 49 bezahlen", "done": []}
    Open tasks: 1. Anmeldeformular unterschreiben und schicken. Email: "Hoi Lea, anbei das unterschriebene Formular." →
    {"task": "", "done": [1]}
    Open tasks: none. Email: "Danke für die Info, bis Samstag!" →
    {"task": "", "done": []}
    """

    static let reviewGrammar = #"""
    root ::= "{" ws "\"task\":" ws task "," ws "\"done\":" ws done ws "}"
    task ::= "\"" char{0,80} "\""
    done ::= "[" ws ( num ( "," ws num )* )? ws "]"
    num ::= [1-9]
    char ::= [^"\\\x00-\x1f]
    ws ::= [ \n]?
    """#

    static func reviewPrompt(_ sent: MailMessage, openTasks: [String], earlier: MailMessage?) -> String {
        var own = sent.chatText
        if own.count > 1500 { own = String(own.prefix(1500)) + " …" }
        let tasks = openTasks.isEmpty ? "none" : openTasks.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        var context = ""
        if let earlier {
            var text = earlier.chatText
            if text.count > 800 { text = String(text.prefix(800)) + " …" }
            context = "\n\nEarlier mail they answer, from \(earlier.from.formatted), subject \(earlier.subject):\n\(text)"
        }
        return """
        Open tasks:
        \(tasks)\(context)

        Their email to \(sent.to.map(\.formatted).joined(separator: ", ")), subject \(sent.subject):
        \(own)
        """
    }

    static func parseReview(_ json: String, openCount: Int) throws -> SentReview {
        struct Answer: Decodable {
            var task: String?
            var done: [Int]?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        let done = (answer.done ?? []).map { $0 - 1 }.filter { (0..<openCount).contains($0) }
        return SentReview(task: cleaned(answer.task), done: Array(Set(done)).sorted())
    }

    /// Reads a mail the user sent for a task they took on and for open tasks it reports as done.
    public static func review(_ sent: MailMessage, openTasks: [String], earlier: MailMessage?, model: LocalModel) async throws -> SentReview {
        let output = try await model.complete(system: reviewSystem, user: reviewPrompt(sent, openTasks: openTasks, earlier: earlier),
                                              grammar: reviewGrammar, maxTokens: 120)
        return try parseReview(output, openCount: openTasks.count)
    }

    public static func triage(_ message: MailMessage, model: LocalModel) async throws -> Triage {
        let output = try await model.complete(system: system, user: prompt(for: message), grammar: grammar, maxTokens: 200)
        return try parse(output, isBulk: message.isBulk)
    }
}
