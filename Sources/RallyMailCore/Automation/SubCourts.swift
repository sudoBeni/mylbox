import Foundation

/// A topic as the model sees it when proposing sub-courts.
public struct SubCourtCard: Sendable, Hashable {
    public var key: String
    public var title: String
    public var keyword: String
    public var summary: String
    public var people: [String]

    public init(key: String, title: String, keyword: String = "", summary: String = "", people: [String] = []) {
        self.key = key
        self.title = title
        self.keyword = keyword
        self.summary = summary
        self.people = people
    }
}

/// A sub-court RallyMail proposes for a court: a name and the topics that would go in.
public struct ProposedSubCourt: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// The topics (matter keys) that would go in.
    public var topics: [String]
    /// The court's sub-court of the same name, if there is one: the topics are added to it.
    public var existing: UUID?
    public var include = true

    public init(name: String, topics: [String], existing: UUID? = nil) {
        self.name = name
        self.topics = topics
        self.existing = existing
    }
}

/// Proposes sub-courts for one court with the local model, in small steps: each topic first gets the name of a
/// sub-area on its own (no list to copy from, so one name does not swallow everything), rules put equal names
/// together, and each topic left over is asked once which of the groups found fits, or none.
public enum SubCourtProposer {
    static let system = """
    Someone sorts the topics of one area of their email into a few sub-areas, like sub-folders. You get one topic. \
    Answer with the sub-area it belongs to: one or two words naming a kind of thing that several topics could \
    share (e.g. "Rechnungen", "Löhne", "Trainingslager", "Mitglieder", "Kunden", "Server", "Newsletter", \
    "Bestellungen"), not the topic's own name, not a person's or company's name. Never the area's own name: \
    name a part of the area. Answer only with JSON: {"area": "..."}
    """

    static let fitSystem = """
    Someone sorts the topics of one area of their email into sub-areas. You get one topic and the sub-areas. \
    Answer with the sub-area the topic clearly belongs to, or "none" if none fits well. When in doubt, "none". \
    Answer only with JSON: {"area": "..."}
    """

    static func prompt(_ card: SubCourtCard, court: String, language: String) -> String {
        var lines = ["Area: \(court) (answer with a part of it, not \"\(court)\")", "Write the name in \(language).", "Topic: \(card.title)"]
        if !card.keyword.isEmpty, card.keyword != card.title { lines.append("Keyword: \(card.keyword)") }
        if !card.summary.isEmpty { lines.append("Latest mail: \(String(card.summary.prefix(200)))") }
        if !card.people.isEmpty { lines.append("People: \(card.people.prefix(3).joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// A grammar that only allows one of the names, or "none".
    static func choiceGrammar(_ names: [String]) -> String {
        let options = (names.map { $0.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "") } + ["none"])
            .map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
        return """
        root ::= "{" ws "\\"area\\":" ws ( \(options) ) ws "}"
        ws ::= [ \\n]?
        """
    }

    /// The first step for one topic: the name of its sub-area, on its own; nil when the answer is no name.
    public static func label(_ card: SubCourtCard, court: String, language: String, model: any TextModel) async throws -> String? {
        let output = try await model.complete(system: system, user: prompt(card, court: court, language: language),
                                              grammar: CourtNaming.textGrammar("area", max: 30), maxTokens: 50)
        return clean((try? JSONDecoder().decode([String: String].self, from: Data(output.utf8)))?["area"], court: court)
    }

    /// Names a sub-area for each topic, groups the names, then places the rest. `existing` are the court's sub-courts.
    public static func propose(court: String, topics: [SubCourtCard], existing: [(id: UUID, name: String)], language: String, model: any TextModel,
                               progress: @Sendable (Int, Int) async -> Void) async throws -> (proposals: [ProposedSubCourt], rest: Int) {
        var labels: [(key: String, label: String)] = []
        for (index, card) in topics.enumerated() {
            await progress(index + 1, topics.count)
            if let label = try await label(card, court: court, language: language, model: model) { labels.append((card.key, label)) }
        }
        var result = group(labels, existing: existing, total: topics.count)
        // The topics without a group: one question each, choosing among the groups found (with examples of each).
        // With a single group the question leans to yes, so it is only asked when there is a choice.
        let names = result.proposals.map(\.name)
        guard names.count >= 2 else { return result }
        let title = Dictionary(topics.map { ($0.key, $0.title) }, uniquingKeysWith: { a, _ in a })
        let examples = result.proposals.map { proposal in
            "\(proposal.name) (e.g. " + proposal.topics.prefix(3).compactMap { title[$0].map { String($0.prefix(40)) } }.joined(separator: "; ") + ")"
        }
        let grouped = Set(result.proposals.flatMap(\.topics))
        let left = topics.filter { !grouped.contains($0.key) }
        var added = Array(repeating: [String](), count: names.count)
        for (index, card) in left.enumerated() {
            await progress(topics.count + index + 1, topics.count + left.count)
            let user = prompt(card, court: court, language: language) + "\nSub-areas:\n" + examples.joined(separator: "\n")
            let output = try await model.complete(system: fitSystem, user: user, grammar: choiceGrammar(names), maxTokens: 40)
            guard let answer = (try? JSONDecoder().decode([String: String].self, from: Data(output.utf8)))?["area"],
                  let at = names.firstIndex(of: answer) else { continue }
            added[at].append(card.key)
        }
        // A group that this step blows up to most of the court takes no one from it.
        for at in names.indices where !added[at].isEmpty {
            guard Double(result.proposals[at].topics.count + added[at].count) < Double(topics.count) * 0.6 else { continue }
            result.proposals[at].topics += added[at]
            result.rest -= added[at].count
        }
        return result
    }

    /// Equal names together; a name with two or more topics, or one of the court's sub-courts, becomes a proposal.
    /// A name that takes nearly all of a court's topics is no sub-court and is left out.
    static func group(_ labels: [(key: String, label: String)], existing: [(id: UUID, name: String)], total: Int) -> (proposals: [ProposedSubCourt], rest: Int) {
        var order: [String] = []
        var members: [String: [String]] = [:]
        for (key, label) in labels {
            let name = order.first { same($0, label) } ?? label
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(key)
        }
        var proposals: [ProposedSubCourt] = []
        for name in order {
            let keys = members[name] ?? []
            let match = existing.first { same($0.name, name) }
            guard keys.count >= 2 || match != nil else { continue }
            if match == nil, total >= 5, Double(keys.count) >= Double(total) * 0.8 { continue }
            proposals.append(ProposedSubCourt(name: match?.name ?? name, topics: keys, existing: match?.id))
        }
        proposals.sort { $0.topics.count > $1.topics.count }
        let placed = proposals.reduce(0) { $0 + $1.topics.count }
        return (proposals, total - placed)
    }

    /// Trimmed and capitalised; nil for empty answers, placeholders and (words of) the court's own name.
    static func clean(_ text: String?, court: String) -> String? {
        var label = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !label.isEmpty, label.count <= 30, TriageService.cleaned(label) == label else { return nil }
        let courtWords = court.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 2 }
        if same(label, court) || courtWords.contains(where: { same($0, label) }) { return nil }
        if ["sonstiges", "andere", "other", "misc", "diverses", "allgemein", "general", "none"].contains(label.lowercased()) { return nil }
        label = label.prefix(1).uppercased() + label.dropFirst()
        return label
    }

    /// The same name up to case and a plural ending ("Rechnung", "Rechnungen"; "Server", "Servers").
    static func same(_ a: String, _ b: String) -> Bool {
        func stem(_ text: String) -> String {
            var word = text.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
            for ending in ["en", "es", "n", "s", "e"] where word.count > 5 && word.hasSuffix(ending) {
                word.removeLast(ending.count)
                break
            }
            return word
        }
        return stem(a) == stem(b)
    }
}

// MARK: - With a cloud model

extension SubCourtProposer {
    static let cloudSystem = """
    You organise the email topics of one area of someone's life into sub-courts (like sub-folders), so the area \
    stays easy to scan. You get the area's name and a numbered list of its topics (title, keyword, a one-line \
    summary). Group them:
    - 2 to 8 sub-courts, each with at least 2 topics; a topic goes into at most one sub-court.
    - Group by what the topics are about (e.g. "Rechnungen", "Löhne", "Trainingslager", "Kunden", "Server", \
    "Newsletter"), not by sender, and never one sub-court for nearly everything.
    - Names: one to three words, a kind of thing, not a person or company and not the area's own name.
    - Reuse an existing sub-court's name exactly when topics fit it.
    - Leave out topics that fit no group well.
    Answer only with JSON: {"subcourts": [{"name": "...", "topics": [1, 4, 7]}]}
    """

    static func cloudPrompt(court: String, topics: [SubCourtCard], existing: [String], language: String) -> String {
        var lines = ["Area: \(court)", "Write the names in \(language)."]
        if !existing.isEmpty { lines.append("Existing sub-courts: \(existing.joined(separator: ", "))") }
        lines.append("Topics:")
        for (index, card) in topics.enumerated() {
            var line = "\(index + 1). \(card.title.prefix(80))"
            if !card.keyword.isEmpty, card.keyword != card.title { line += " — \(card.keyword.prefix(40))" }
            if !card.summary.isEmpty { line += " — \(card.summary.prefix(120))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// One request for the whole court: a cloud model sees all topics at once and groups them.
    public static func proposeWithCloud(court: String, topics: [SubCourtCard], existing: [(id: UUID, name: String)], language: String,
                                        model: any TextModel) async throws -> (proposals: [ProposedSubCourt], rest: Int) {
        let output = try await model.complete(system: cloudSystem,
                                              user: cloudPrompt(court: court, topics: topics, existing: existing.map(\.name), language: language),
                                              grammar: nil, maxTokens: 4000)
        return try parseCloud(output, topics: topics, existing: existing, court: court)
    }

    /// The model's groups, checked: real topic numbers, each topic once, at least two per new sub-court.
    static func parseCloud(_ json: String, topics: [SubCourtCard], existing: [(id: UUID, name: String)], court: String) throws -> (proposals: [ProposedSubCourt], rest: Int) {
        struct Answer: Decodable {
            struct Group: Decodable { var name: String; var topics: [Int] }
            var subcourts: [Group]
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        var used = Set<Int>()
        var proposals: [ProposedSubCourt] = []
        for group in answer.subcourts {
            guard let name = clean(group.name, court: court) else { continue }
            let numbers = group.topics.filter { (1...topics.count).contains($0) && used.insert($0).inserted }
            let match = existing.first { same($0.name, name) }
            guard numbers.count >= 2 || (match != nil && !numbers.isEmpty) else { continue }
            let keys = numbers.map { topics[$0 - 1].key }
            if let index = proposals.firstIndex(where: { same($0.name, name) }) {
                proposals[index].topics += keys
            } else {
                proposals.append(ProposedSubCourt(name: match?.name ?? name, topics: keys, existing: match?.id))
            }
        }
        proposals.sort { $0.topics.count > $1.topics.count }
        return (proposals, topics.count - proposals.reduce(0) { $0 + $1.topics.count })
    }
}
