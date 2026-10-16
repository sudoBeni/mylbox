import Foundation

/// Finds the topic a conversation most likely continues, for mail that started fresh instead of replying.
/// Two signals, no model involved; the user confirms with one click:
/// - a reference both mention, in the subject or in what people wrote: a case or order number like "A24015827";
/// - the same organisation (e.g. equans.com) with a similar subject within a few weeks;
/// - the same person with a similar subject, typos included ("Website:)" and "Websiite" to Fabian), within a month.
/// A topic is suggested to join one that is in a court, or an older one, so two topics never point at each other.
/// Only between topics with people, and you wrote in at least one of the two: notifications and newsletters repeat
/// numbers and subjects all the time.
/// Which topic a conversation should join, and why. `certain` suggestions are applied without asking: a file
/// number in both subjects with the same organisation is as good as a reply header.
public struct MatterSuggestion: Equatable, Sendable {
    public var matter: String
    public var reference: String
    public var certain = false
}

public struct MatterSuggestions: Sendable {
    private var byToken: [String: [String]] = [:]
    private var tokens: [String: [String]] = [:]
    private var subjectTokens: [String: Set<String>] = [:]
    private var matters: [String: Matter] = [:]
    private var domains: [String: Set<String>] = [:]
    private var byDomain: [String: [String]] = [:]
    private var persons: [String: [EmailAddress]] = [:]
    private var byPerson: [String: [String]] = [:]
    private var answered: Set<String>? = nil

    /// Mail services anyone can use: sharing one says nothing about belonging together.
    static let freemail: Set<String> = [
        "gmail.com", "googlemail.com", "gmx.ch", "gmx.de", "gmx.net", "gmx.at", "bluewin.ch", "hotmail.com", "hotmail.ch",
        "outlook.com", "live.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "yahoo.de", "web.de", "sunrise.ch",
        "proton.me", "protonmail.com", "hispeed.ch", "swissonline.ch", "t-online.de",
    ]

    /// `references`: reference numbers per conversation from what people wrote (`MailStore.referenceTokens`).
    /// `answered`: conversations with mail from the user (`MailStore.threadsWithSentMail`); nil to not ask for it.
    public init(_ matters: [Matter], references: [String: Set<String>] = [:], answered: Set<String>? = nil,
                isMe: (EmailAddress) -> Bool = { _ in false }) {
        self.answered = answered
        for matter in matters where Self.isPersonal(matter) {
            self.matters[matter.id] = matter
            // Subject references first: they say most about what the topic is.
            let subjectTokens = ([matter.title] + matter.conversations.map(\.subject)).flatMap(Self.references)
            // Stored numbers are checked again, so a stricter rule also applies to mail stored before it.
            let textTokens = matter.conversations.flatMap { references[$0.id] ?? [] }.filter { Self.references($0) == [$0] }.sorted()
            var seen = Set<String>()
            let all = (subjectTokens + textTokens).filter { seen.insert($0).inserted }
            tokens[matter.id] = all
            self.subjectTokens[matter.id] = Set(subjectTokens)
            for token in all { byToken[token, default: []].append(matter.id) }
            let people = matter.people(isMe: isMe)
            persons[matter.id] = people
            for person in people { byPerson[person.address.lowercased(), default: []].append(matter.id) }
            let organisations = Set(people.compactMap { person -> String? in
                guard let domain = person.address.lowercased().split(separator: "@").last.map(String.init),
                      !Self.freemail.contains(domain) else { return nil }
                return domain
            })
            domains[matter.id] = organisations
            for domain in organisations { byDomain[domain, default: []].append(matter.id) }
        }
    }

    /// The topic and why: the shared reference ("075920"), or "@" and the organisation's domain.
    public func suggest(for matter: Matter) -> MatterSuggestion? {
        guard Self.isPersonal(matter) else { return nil }
        // A file number in the subject on both sides, with the same organisation: the same matter, however
        // many conversations it has by now (a legal case runs for years).
        let organisations = domains[matter.id] ?? []
        for token in (subjectTokens[matter.id] ?? []).sorted() where !organisations.isEmpty {
            let others = (byToken[token] ?? []).filter { other in
                other != matter.id && subjectTokens[other]?.contains(token) == true
                    && !(domains[other] ?? []).isDisjoint(with: organisations)
            }
            if let target = best(others, for: matter, requireWrote: false) { return MatterSuggestion(matter: target, reference: token, certain: true) }
        }
        for token in tokens[matter.id] ?? [] {
            let others = (byToken[token] ?? []).filter { $0 != matter.id }
            // In many topics it is a customer number or a footer, not this matter's reference.
            guard !others.isEmpty, others.count <= 2 else { continue }
            if let target = best(others, for: matter) { return MatterSuggestion(matter: target, reference: token) }
        }
        // Without a real subject there is nothing to compare.
        guard Self.hasSubject(matter.title) else { return nil }
        let words = Self.words(matter.title)
        for domain in (domains[matter.id] ?? []).sorted() {
            let others = (byDomain[domain] ?? []).filter { other in
                guard other != matter.id, let candidate = matters[other] else { return false }
                return abs(candidate.lastDate.timeIntervalSince(matter.lastDate)) < 45 * 86400
                    && Self.similar(words, Self.words(candidate.title))
            }
            if let target = best(others, for: matter) { return MatterSuggestion(matter: target, reference: "@" + domain) }
        }
        for person in persons[matter.id] ?? [] {
            let others = (byPerson[person.address.lowercased()] ?? []).filter { other in
                guard other != matter.id, let candidate = matters[other], Self.hasSubject(candidate.title) else { return false }
                return abs(candidate.lastDate.timeIntervalSince(matter.lastDate)) < 31 * 86400
                    && (Self.similar(words, Self.words(candidate.title)) || Self.nearlySame(matter.title, candidate.title))
            }
            if let target = best(others, for: matter) { return MatterSuggestion(matter: target, reference: "=" + (person.name.isEmpty ? person.address : person.name)) }
        }
        return nil
    }

    static func hasSubject(_ title: String) -> Bool {
        let subject = Threading.normalizedSubject(title).lowercased()
        return !subject.isEmpty && !["(no subject)", "(kein betreff)", "(ohne betreff)", "(sans objet)"].contains(subject)
    }

    /// The same subject but for a typo or a smiley: "Website:)" and "Websiite".
    static func nearlySame(_ a: String, _ b: String) -> Bool {
        func letters(_ text: String) -> [Character] {
            Array(Threading.normalizedSubject(text).lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let x = letters(a), y = letters(b)
        guard min(x.count, y.count) >= 5 else { return false }
        return distance(x, y) <= max(1, min(x.count, y.count) / 6)
    }

    /// Edit distance: how many letters to add, remove or change.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private func wrote(in matter: Matter) -> Bool {
        guard let answered else { return true }
        return matter.conversations.contains { answered.contains($0.id) }
    }

    /// Mail from people: no conversation the heuristics or the model called an update or newsletter, none sent in bulk.
    static func isPersonal(_ matter: Matter) -> Bool {
        matter.conversations.allSatisfy { $0.category != .updates && $0.category != .newsletters && $0.category != .spam }
    }

    /// A topic in a court first, else the oldest that is older than this one.
    private func best(_ ids: [String], for matter: Matter, requireWrote: Bool = true) -> String? {
        let candidates = ids.compactMap { matters[$0] }.filter { !requireWrote || wrote(in: matter) || wrote(in: $0) }
        if let inCourt = candidates.first(where: { $0.spaceID != nil }) { return inCourt.id }
        return candidates.filter { $0.lastDate < matter.lastDate }.min { $0.lastDate < $1.lastDate }?.id
    }

    /// For the side panel: "Both mention 075920.", "Both are with equans.com, with a similar subject." or
    /// "Same person (Fabian), similar subject."
    public static func explain(_ reference: String) -> String {
        if reference.hasPrefix("@") { return "Both are with \(reference.dropFirst()), with a similar subject." }
        if reference.hasPrefix("=") { return "Same person (\(reference.dropFirst())), similar subject." }
        return "Both mention \(reference)."
    }

    public static func explain(_ suggestion: MatterSuggestion) -> String {
        suggestion.certain ? "Both have \(suggestion.reference) in the subject, with the same organisation." : explain(suggestion.reference)
    }

    /// Words of four letters or more, without reply prefixes and tags.
    static func words(_ subject: String) -> Set<String> {
        Set(Threading.normalizedSubject(subject).lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 4 })
    }

    /// At least two words in common, and half of the shorter subject.
    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shared = a.intersection(b).count
        return shared >= 2 && shared * 2 >= min(a.count, b.count)
    }

    /// Names of embedded pictures ("image002.png" in the text), not references.
    static let pictureName = try! NSRegularExpression(pattern: #"^(IMAGE|IMG|DSC|SCAN|PHOTO|FOTO)[-_]?\d"#)

    /// Words of at least five characters with at least three digits that are not a plain year or date, a picture
    /// name or a short number range ("A24015827", "88412"; not "2FWWW", "IMAGE002", "00-18").
    static func references(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "/" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-/")).uppercased() }
            .filter { word in
                // Not technical ids: "0663D59A-A5F6-4FA8-…".
                word.count >= 5 && word.count <= 20 && word.filter({ $0 == "-" }).count <= 1 && word.filter(\.isNumber).count >= 3
                    && pictureName.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) == nil
                    && !(word.contains("-") && word.allSatisfy { $0.isNumber || $0 == "-" } && word.filter(\.isNumber).count < 6)
                    && !(word.count == 4 && word.allSatisfy(\.isNumber))
                    && word.rangeOfCharacter(from: CharacterSet(charactersIn: "./")) == nil
            }
    }
}
