import Foundation

/// Topics that are about the same theme at the same time, but separate matters: the cancelled camp booking and
/// the new one. Only a pointer in the side panel; nothing is merged and no status changes.
///
/// The theme comes from the subjects, the model's keywords and the organisations' names ("beachvolleycamps.ch",
/// "beach-volleyball.de"). Words count as the same when one contains the other ("beachcamp" and "camp"), since
/// German glues words together. Two shared theme words and at most three weeks apart make two topics related.
/// Words in many topics (the user's own name, "volleyball" for a club member) say nothing and are left out, and
/// the user must have written in one of the two: notifications from one sender are not a theme.
public struct RelatedTopics: Sendable {
    var themes: [String: Set<String>] = [:]
    var spans: [String: ClosedRange<Date>] = [:]
    private var titles: [String: String] = [:]
    var wrote: Set<String> = []

    /// Words that say what kind of mail it is, not what it is about.
    static let generic: Set<String> = [
        "anfrage", "buchung", "bestellung", "rechnung", "reservation", "reservierung", "bestätigung", "info", "infos",
        "information", "update", "aktuell", "aktueller", "stand", "frage", "fragen", "termin", "mail", "email",
        "nachricht", "antwort", "danke", "bitte", "hallo", "neue", "neuer", "deine", "ihre", "your", "order",
        "booking", "request", "invoice", "confirmation", "reminder", "erinnerung", "zahlungserinnerung", "news",
        "newsletter", "mail", "gmbh", "team", "service", "support", "noreply", "kontakt", "mitteilung", "betreff",
    ]

    /// `answered`: conversations with mail from the user (`MailStore.threadsWithSentMail`).
    public init(_ matters: [Matter], answered: Set<String> = [], isMe: (EmailAddress) -> Bool = { _ in false }) {
        for matter in matters where matter.conversations.contains(where: { answered.contains($0.id) }) {
            wrote.insert(matter.id)
        }
        for matter in matters {
            var words = Set<String>()
            let texts = [matter.title] + matter.conversations.flatMap { [$0.subject, $0.lastTopic ?? ""] }
            for text in texts { words.formUnion(Self.words(Threading.normalizedSubject(text))) }
            for person in matter.people(isMe: isMe) {
                guard let domain = person.address.lowercased().split(separator: "@").last,
                      !MatterSuggestions.freemail.contains(String(domain)),
                      let name = domain.split(separator: ".").dropLast().last else { continue }
                // "beach-volleyball" → "beach", "volleyball" and "beachvolleyball".
                words.formUnion(Self.words(String(name).replacingOccurrences(of: "-", with: " ")))
                words.insert(String(name).replacingOccurrences(of: "-", with: ""))
            }
            themes[matter.id] = words.filter { $0.count >= 4 && !Self.generic.contains($0) }
            let first = matter.conversations.map(\.firstDate).min() ?? matter.lastDate
            spans[matter.id] = min(first, matter.lastDate)...matter.lastDate
            titles[matter.id] = matter.title
        }
        // In more than a dozen topics a word is a name or a hobby, not this matter's theme.
        var count: [String: Int] = [:]
        for words in themes.values { for word in words { count[word, default: 0] += 1 } }
        let common = Set(count.filter { $0.value > 12 }.keys)
        for id in themes.keys { themes[id]?.subtract(common) }
    }

    /// Up to three related topics, the closest first.
    public func related(to matter: Matter) -> [String] {
        guard let mine = themes[matter.id], let span = spans[matter.id] else { return [] }
        var scored: [(id: String, score: Int, gap: TimeInterval)] = []
        for (id, theirs) in themes where id != matter.id {
            guard let other = spans[id], wrote.contains(matter.id) || wrote.contains(id) else { continue }
            let gap = max(0, max(other.lowerBound.timeIntervalSince(span.upperBound), span.lowerBound.timeIntervalSince(other.upperBound)))
            guard gap <= 21 * 86400 else { continue }
            let score = max(Self.shared(mine, theirs), Self.shared(theirs, mine))
            if score >= 2 { scored.append((id, score, gap)) }
        }
        return scored.sorted { ($0.score, -$0.gap) > ($1.score, -$1.gap) }.prefix(3).map(\.id)
    }

    /// Theme words of one topic that also appear in the other, counting "camp" in "beachvolleycamps".
    static func shared(_ a: Set<String>, _ b: Set<String>) -> Int {
        a.filter { word in b.contains { $0 == word || $0.contains(word) || word.contains($0) } }.count
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init))
    }
}
