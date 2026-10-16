import Foundation

/// A sender's signature, learned from what their mails have in common at the end. Works without "-- " and
/// without AI: lines that end at least two of their mails are signature lines.
public struct SenderSignature: Equatable, Sendable {
    /// Lines that end at least two of the sender's mails, as `MessageFormatter` sees them.
    public var known: Set<String>
    /// The newest signature, exactly as written; empty if none was found.
    public var latest: String
    /// What the badge shows, read from `latest`.
    public var card: SignatureCard
    /// Lines a relay or notification service puts at the top or bottom of every mail ("Du hast Nachrichten von …
    /// erhalten.", "Jetzt direkt antworten"): learned like the signature, folded by the formatter.
    public var boilerplate: Set<String> = []

    public static let empty = SenderSignature(known: [], latest: "", card: SignatureCard())

    /// `bodies`: what the bubbles show of the sender's mails (`MailMessage.bubbleSource`), newest first.
    public static func learn(from bodies: [String], name: String, address: String = "") -> SenderSignature {
        var counts: [String: Int] = [:]
        for body in bodies {
            let tail = MessageFormatter.lines(body).map(\.text).filter { !$0.isEmpty }.suffix(25)
            for line in Set(tail) { counts[line, default: 0] += 1 }
        }
        let known = Set(counts.filter { line, count in count >= 2 && isSignatureLine(line) }.keys)
        let latest = bodies.lazy.map { MessageFormatter.format($0, known: known).text(of: .signature) }.first { !$0.isEmpty } ?? ""
        var everywhere: [String: Int] = [:]
        for body in bodies {
            for line in Set(MessageFormatter.lines(body).map(\.text).filter { !$0.isEmpty }) { everywhere[line, default: 0] += 1 }
        }
        let boilerplate = Set(everywhere.filter { line, count in count >= 2 && isBoilerplateLine(line) && !known.contains(line) }.keys)
        return SenderSignature(known: known, latest: latest, card: SignatureCard.read(latest, name: name, address: address),
                               boilerplate: boilerplate)
    }

    /// A line long enough to be a service's fixed text, not a greeting or a sign-off a person repeats.
    static func isBoilerplateLine(_ line: String) -> Bool {
        guard line.count >= 24 else { return false }
        return !MessageFormatter.matches(MessageFormatter.greeting, line) && !MessageFormatter.isClosing(line)
    }

    /// Lines that can be part of a signature: no sentences, no greeting or sign-off ("Anbei die Rechnung." also
    /// ends many mails of some people, but it is text).
    static func isSignatureLine(_ line: String) -> Bool {
        if MessageFormatter.matches(MessageFormatter.greeting, line) || MessageFormatter.isClosing(line) { return false }
        if MessageFormatter.matches(MessageFormatter.contactHint, line) { return true }
        guard line.count <= 60, let last = line.last else { return false }
        return !".?!:".contains(last)
    }
}

/// What a signature says about the sender, for the badge next to their name. Only excerpts: the full
/// signature is always one click away.
public struct SignatureCard: Equatable, Sendable {
    /// Role or organisation: "Kassier VBC Luzern", "Value Solutions AG".
    public var title: String?
    public var phones: [String] = []
    public var links: [URL] = []

    public var isEmpty: Bool { title == nil && phones.isEmpty && links.isEmpty }

    static let separator = try! NSRegularExpression(pattern: #"\s+[|·•–-]\s+|\s*\|\s*|,\s+"#)
    static let phone = try! NSRegularExpression(pattern: #"(?:\+|\b0)\d[\d ()/.-]{7,}\d"#)
    static let label = try! NSRegularExpression(
        pattern: #"^(tel|telefon|phone|mobile?|mobil|natel|fax|e-?mail|mail|web|website|direkt|direct|office|büro)\b\.?:?"#,
        options: [.caseInsensitive])
    static let web = try! NSRegularExpression(
        pattern: #"\b(?:https?://|www\.)[^\s<>()|]+|(?<![@\w.-])[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ch|com|de|org|net|io|dev|at|li|fr|it|eu|app|co|nl|uk)\b(?![@\w-])"#,
        options: [.caseInsensitive])
    /// "Hofmattweg 1", "Postfach 12": an address line, not a role.
    static let street = try! NSRegularExpression(pattern: #"\p{L}\.?\s+\d{1,4}\s?[a-z]?$|^postfach\b"#, options: [.caseInsensitive])

    public init(title: String? = nil, phones: [String] = [], links: [URL] = []) {
        self.title = title
        self.phones = phones
        self.links = links
    }

    /// `address` puts the link to the sender's own domain first.
    public static func read(_ signature: String, name: String, address: String = "") -> SignatureCard {
        var card = SignatureCard()
        let nameWords = Set(name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 2 })
        let ns = signature as NSString
        for match in phone.matches(in: signature, range: NSRange(location: 0, length: ns.length)) {
            let number = ns.substring(with: match.range)
            if number.filter(\.isNumber).count >= 9, !card.phones.contains(number) { card.phones.append(number) }
        }
        for match in web.matches(in: signature, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,;:>".contains(last) { raw.removeLast() }
            if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
            if let url = URL(string: raw), url.host() != nil, !card.links.contains(where: { $0.host() == url.host() }) {
                card.links.append(url)
            }
        }
        let domain = address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        if !domain.isEmpty, let own = card.links.firstIndex(where: { $0.host()?.lowercased().hasSuffix(domain) == true }) {
            card.links.insert(card.links.remove(at: own), at: 0)
        }
        for line in signature.split(separator: "\n").map(String.init) {
            let segments = separator.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "\u{0}")
                .split(separator: "\u{0}").map { $0.trimmingCharacters(in: .whitespaces) }
            for segment in segments.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "()[]*_")) })
            where isTitle(segment, nameWords: nameWords) {
                card.title = segment
                return card
            }
        }
        return card
    }

    /// Buttons and calls to action of newsletter footers.
    static let action = try! NSRegularExpression(
        pattern: #"\b(click|tweet|follow|folge|contact|kontakt|download|questions|fragen|unsubscribe|abmelden|view|ansehen|support|hilfe|help)\b"#,
        options: [.caseInsensitive])

    /// A role or organisation: not the name, a number, address, link, label or button, and not a sentence.
    static func isTitle(_ segment: String, nameWords: Set<String>) -> Bool {
        // Starts like a name or title, or with an abbreviation: "dipl. Wirtschaftsprüfer".
        let firstWord = segment.prefix { !$0.isWhitespace }
        guard segment.count <= 50, segment.filter(\.isLetter).count >= 3,
              segment.first?.isUppercase == true || firstWord.hasSuffix(".") else { return false }
        if segment.filter(\.isNumber).count >= 3 || segment.contains("@") || segment.contains(":") { return false }
        if let last = segment.last, ",!?".contains(last) { return false }
        let range = NSRange(segment.startIndex..., in: segment)
        if [web, label, street, action].contains(where: { $0.firstMatch(in: segment, range: range) != nil }) { return false }
        if MessageFormatter.isClosing(segment) || MessageFormatter.matches(MessageFormatter.greeting, segment) { return false }
        let words = segment.lowercased().split { !$0.isLetter }.map(String.init).filter { !$0.isEmpty }
        // "Reto Kaufmann", "Kaufmann Reto", "Beni" for Benjamin: every word belongs to the name.
        // "Thomas Steimann" for Tom Steimann: the surname is enough.
        let isName = words.count <= 3 && (words.allSatisfy { word in
            nameWords.contains(word) || word.count <= 6 && nameWords.contains { $0.hasPrefix(word.prefix(3)) }
        } || words.contains { $0.count >= 4 && nameWords.contains($0) })
        return !isName
    }
}
