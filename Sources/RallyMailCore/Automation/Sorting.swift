import Foundation

/// A topic the sorting assistant proposes: conversations that belong together, usually by a shared reference.
public struct ProposedTopic: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var threadIDs: [String]
    /// The case or order number they share, when that is why.
    public var reference: String?
    public var include = true
}

/// A court the sorting assistant proposes: a group of people (and their organisations) the user writes with.
public struct ProposedCourt: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// An existing court most of this group's mail is in already; the group then fills that court.
    public var existing: UUID?
    /// The people, the most active first.
    public var people: [EmailAddress]
    public var domains: [String]
    public var threadIDs: [String]
    public var messageCount: Int
    /// Recent subjects and the model's keywords, for naming and for the user to recognise the group.
    public var subjects: [String]
    public var keywords: [String]
    public var topics: [ProposedTopic]
    public var lastDate: Date
    public var include = true
    /// What the group's mail is about, in the model's words (empty without the model).
    public var about = ""
}

/// Finds the areas of someone's mail without a model: people who write together, and people of the same
/// organisation, end up in one group. Each group is a proposed court; conversations inside it that share a
/// reference become proposed topics.
public enum SortingEngine {
    /// Mail providers anyone can use: their domain says nothing about the area.
    static let publicDomains: Set<String> = [
        "gmail.com", "googlemail.com", "gmx.ch", "gmx.net", "gmx.de", "gmx.at", "bluewin.ch", "hotmail.com", "hotmail.ch",
        "outlook.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "yahoo.de", "proton.me",
        "protonmail.com", "web.de", "t-online.de", "sunrise.ch", "hispeed.ch", "swissonline.ch", "posteo.de", "aol.com",
    ]

    /// Groups the personal conversations (no notifications, no spam) into proposed courts, largest first.
    /// `rest` counts the conversations that fit no group (one-off contacts).
    public static func propose(_ conversations: [Conversation], courts: [Space], isMe: (EmailAddress) -> Bool,
                               since: Date? = nil, minimumConversations: Int = 2) -> (courts: [ProposedCourt], rest: Int) {
        let personal = conversations.filter { conversation in
            !conversation.isSpam && !conversation.isFolded && (since.map { conversation.lastDate >= $0 } ?? true)
        }
        // Union-find over people: those in one conversation (not a mass mail) are one group, and so are colleagues.
        var parent: [String: String] = [:]
        func find(_ key: String) -> String {
            var key = key
            while let next = parent[key], next != key { key = next }
            return key
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var names: [String: EmailAddress] = [:]
        var counts: [String: Int] = [:]
        var others: [String: [String]] = [:]
        for conversation in personal {
            let people = Array(Set(conversation.participants.filter { !isMe($0) && !$0.address.isEmpty }.map { $0.address.lowercased() })).sorted()
            others[conversation.id] = people
            for address in conversation.participants where !isMe(address) && !address.address.isEmpty {
                let key = address.address.lowercased()
                if parent[key] == nil { parent[key] = key }
                if names[key]?.name.isEmpty ?? true { names[key] = address }
                counts[key, default: 0] += conversation.messageCount
            }
            if people.count <= 6, let first = people.first {
                for person in people.dropFirst() { union(first, person) }
            }
        }
        var byDomain: [String: String] = [:]
        for key in parent.keys {
            guard let domain = domain(of: key), !publicDomains.contains(domain) else { continue }
            if let other = byDomain[domain] { union(key, other) } else { byDomain[domain] = key }
        }
        // Each conversation joins the group of its most active person.
        var groups: [String: [Conversation]] = [:]
        for conversation in personal {
            guard let lead = others[conversation.id]?.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) else { continue }
            groups[find(lead), default: []].append(conversation)
        }
        var result: [ProposedCourt] = []
        var rest = 0
        for (_, list) in groups {
            guard list.count >= minimumConversations else { rest += list.count; continue }
            result.append(court(from: list, courts: courts, isMe: isMe, names: names, counts: counts))
        }
        return (result.sorted { $0.messageCount > $1.messageCount }, rest)
    }

    static func court(from list: [Conversation], courts: [Space], isMe: (EmailAddress) -> Bool,
                      names: [String: EmailAddress], counts: [String: Int]) -> ProposedCourt {
        let sorted = list.sorted { $0.lastDate > $1.lastDate }
        var people: [String: Int] = [:]
        for conversation in sorted {
            for address in conversation.participants where !isMe(address) && !address.address.isEmpty {
                people[address.address.lowercased(), default: 0] += conversation.messageCount
            }
        }
        let topPeople = people.sorted { $0.value > $1.value }.prefix(8).compactMap { names[$0.key] }
        let domains = Array(Set(people.keys.compactMap(domain(of:)).filter { !publicDomains.contains($0) })).sorted()
        // Most of the group already in one court: propose filling that court instead of a new one.
        var inCourt: [UUID: Int] = [:]
        for conversation in sorted { if let space = conversation.spaceID { inCourt[space, default: 0] += 1 } }
        let existing = inCourt.max { $0.value < $1.value }.flatMap { $0.value * 2 >= sorted.count ? $0.key : nil }
        let existingName = existing.flatMap { id in courts.first { $0.id == id }?.name }
        return ProposedCourt(
            name: existingName ?? fallbackName(people: topPeople, domains: domains),
            existing: existingName == nil ? nil : existing,
            people: topPeople,
            domains: domains,
            threadIDs: sorted.map(\.id),
            messageCount: sorted.reduce(0) { $0 + $1.messageCount },
            subjects: Array(sorted.map(\.subject).filter { !$0.isEmpty }.prefix(12)),
            keywords: Array(Set(sorted.compactMap(\.lastTopic).filter { !$0.isEmpty })).sorted().prefix(12).map { $0 },
            topics: topics(in: sorted),
            lastDate: sorted.first?.lastDate ?? .distantPast)
    }

    /// Conversations of a group that share a reference (case number, order number) form one topic.
    static func topics(in conversations: [Conversation]) -> [ProposedTopic] {
        var byReference: [String: [Conversation]] = [:]
        for conversation in conversations where conversation.matterID == nil {
            for reference in Set(MatterSuggestions.references(conversation.subject)) {
                byReference[reference, default: []].append(conversation)
            }
        }
        var used = Set<String>()
        var result: [ProposedTopic] = []
        for (reference, list) in byReference.sorted(by: { $0.value.count > $1.value.count }) {
            let fresh = list.filter { !used.contains($0.id) }
            guard fresh.count >= 2 else { continue }
            used.formUnion(fresh.map(\.id))
            let newest = fresh.max { $0.lastDate < $1.lastDate }!
            result.append(ProposedTopic(title: newest.subject.isEmpty ? reference : newest.subject,
                                        threadIDs: fresh.map(\.id), reference: reference))
        }
        return result
    }

    /// A name without the model: the organisation's domain, else the people.
    public static func fallbackName(people: [EmailAddress], domains: [String]) -> String {
        if let domain = domains.first {
            let base = domain.split(separator: ".").dropLast().last.map(String.init) ?? domain
            return base.prefix(1).uppercased() + base.dropFirst()
        }
        let first = people.prefix(2).map { $0.name.isEmpty ? $0.address : $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
        return first.joined(separator: " & ") + (people.count > 2 ? " +\(people.count - 2)" : "")
    }

    /// Puts one proposed court into another: their people, mail and topics together.
    public static func merge(_ source: ProposedCourt, into target: ProposedCourt) -> ProposedCourt {
        var merged = target
        merged.people = Array((target.people + source.people).reduce(into: [String: EmailAddress]()) { result, person in
            result[person.address.lowercased()] = result[person.address.lowercased()] ?? person
        }.values.prefix(8))
        merged.domains = Array(Set(target.domains + source.domains)).sorted()
        merged.threadIDs = target.threadIDs + source.threadIDs.filter { !target.threadIDs.contains($0) }
        merged.messageCount = target.messageCount + source.messageCount
        merged.subjects = Array((target.subjects + source.subjects).prefix(12))
        merged.keywords = Array(Set(target.keywords + source.keywords)).sorted()
        merged.topics = target.topics + source.topics
        merged.lastDate = max(target.lastDate, source.lastDate)
        merged.existing = target.existing ?? source.existing
        return merged
    }

    static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        return domain.isEmpty ? nil : domain
    }
}

/// The local model names proposed courts and revises the proposal from the user's words. A small model does well
/// with small questions, so every step is one short prompt with a tightly constrained answer; the app puts the
/// answers together.
public enum CourtNaming {
    static let char = #"char ::= [^"\\\x00-\x1f]"#

    // MARK: Naming: first what it is about, then a name for that

    static let aboutSystem = """
    You look at the email someone exchanges with a group of people. Say in one short sentence what these emails \
    are about (the area of life or work). Write in the same language as the subjects: German subjects, German \
    sentence. Answer only with JSON: {"about": "..."}
    """

    static let nameSystem = """
    Give a short name for an area of someone's email, like a folder name: one to three words, in the same language \
    as the subjects. Name the area, not the people (e.g. "Volleyball Finanzen", "Wohnung", "Steuern", "Cheersfeed"). \
    Answer only with JSON: {"name": "..."}
    """

    static func textGrammar(_ key: String, max: Int) -> String {
        """
        root ::= "{" ws "\\"\(key)\\":" ws "\\"" char{1,\(max)} "\\"" ws "}"
        \(char)
        ws ::= [ \\n]?
        """
    }

    static func describe(_ court: ProposedCourt) -> String {
        let people = court.people.prefix(5).map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }
        return """
        People: \(people.joined(separator: "; "))
        Organisations: \(court.domains.prefix(4).joined(separator: ", "))
        Keywords: \(court.keywords.prefix(10).joined(separator: ", "))
        Subjects: \(court.subjects.prefix(10).joined(separator: " | "))
        """
    }

    static func ask(_ model: any TextModel, system: String, user: String, key: String, max: Int) async throws -> String {
        let output = try await model.complete(system: system, user: user, grammar: textGrammar(key, max: max), maxTokens: max + 20)
        let object = try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
        return (object[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two steps: what the group's mail is about, then a short name for that.
    public static func name(_ court: ProposedCourt, model: any TextModel) async throws -> (name: String, about: String) {
        let about = try await ask(model, system: aboutSystem, user: describe(court), key: "about", max: 160)
        let name = try await ask(model, system: nameSystem, user: "Description: \(about)\nSubjects: \(court.subjects.prefix(5).joined(separator: " | "))",
                                 key: "name", max: 40)
        return (name.isEmpty ? court.name : name, about)
    }

    // MARK: Revising from the user's words, one area at a time

    /// What the user's wish means for one area.
    public enum Change: Equatable, Sendable {
        case keep
        case rename(String)
        case drop
        case merge(into: Int)
    }

    static let concernsSystem = """
    Someone sorts their email into areas and says what they want changed. Does the wish concern THIS area? \
    Answer only with JSON: {"concerns": true} or {"concerns": false}
    """
    static let concernsGrammar = #"""
    root ::= "{" ws "\"concerns\":" ws ("true" | "false") ws "}"
    ws ::= [ \n]?
    """#

    static let actionSystem = """
    Someone sorts their email into areas and wants THIS area changed. What should happen to it? \
    "rename": give it another name; "merge": put it together with another area; "drop": leave it out; "keep": nothing. \
    Answer only with JSON: {"action": "rename" | "merge" | "drop" | "keep"}
    """
    static let actionGrammar = #"""
    root ::= "{" ws "\"action\":" ws ("\"rename\"" | "\"merge\"" | "\"drop\"" | "\"keep\"") ws "}"
    ws ::= [ \n]?
    """#

    static let renameSystem = """
    Someone sorts their email into areas and wants THIS area renamed. Give the new name the wish asks for, one to \
    three words. Answer only with JSON: {"name": "..."}
    """

    static let targetSystem = """
    Someone sorts their email into areas and wants THIS area put together with another one. Which of the listed \
    areas should it go into? Answer only with JSON: {"into": number}
    """
    static let targetGrammar = #"""
    root ::= "{" ws "\"into\":" ws [0-9] [0-9]? ws "}"
    ws ::= [ \n]?
    """#

    static func card(_ court: ProposedCourt) -> String {
        "Area \"\(court.name)\" – people: \(court.people.prefix(3).map(\.displayName).joined(separator: ", ")); subjects: \(court.subjects.prefix(4).joined(separator: " | "))"
    }

    static let splitSystem = """
    Someone sorts their email into areas and says what they want changed. Split the wish into single changes, each \
    about one area, in the person's words. Answer only with JSON: {"steps": ["...", "..."]}
    """
    static let splitGrammar = #"""
    root ::= "{" ws "\"steps\":" ws "[" ws step (ws "," ws step){0,5} ws "]" ws "}"
    step ::= "\"" char{1,160} "\""
    char ::= [^"\\\x00-\x1f]
    ws ::= [ \n]*
    """#

    /// The wish as single changes ("put A with B", "call C lawyer"); the whole wish when it is one already.
    static func steps(of wish: String, model: any TextModel) async throws -> [String] {
        let output = try await model.complete(system: splitSystem, user: wish, grammar: splitGrammar, maxTokens: 200)
        let steps = (try? JSONDecoder().decode([String: [String]].self, from: Data(output.utf8)))?["steps"] ?? []
        let clean = steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return clean.isEmpty ? [wish] : clean
    }

    /// Works out the wish in small steps: split it into single changes; then for each change and each area, does it
    /// concern this area, what should happen, and (to merge) into which. Each change is applied before the next
    /// one is read, so names stay current. `progress` reports what is being done.
    public static func revise(_ courts: [ProposedCourt], wish: String, model: any TextModel,
                              progress: @Sendable (String) async -> Void = { _ in }) async throws -> [ProposedCourt] {
        var result = courts
        let steps = try await steps(of: wish, model: model)
        for (number, step) in steps.enumerated() {
            await progress("Change \(number + 1) of \(steps.count): \(step)")
            var changes: [Change] = []
            for (index, court) in result.enumerated() {
                changes.append(try await change(for: court, at: index, in: result, step: step, model: model))
            }
            result = apply(changes, to: result)
        }
        return result
    }

    static func change(for court: ProposedCourt, at index: Int, in courts: [ProposedCourt], step: String, model: any TextModel) async throws -> Change {
        let question = "\(card(court))\n\nWish: \(step)"
        // Named in the wish: no need to ask.
        let named = step.lowercased().contains(court.name.lowercased())
        if !named {
            let concerns = try await model.complete(system: concernsSystem, user: question, grammar: concernsGrammar, maxTokens: 12)
            guard concerns.contains("true") else { return .keep }
        }
        let action = try await model.complete(system: actionSystem, user: question, grammar: actionGrammar, maxTokens: 14)
        if action.contains("rename") {
            let name = try await ask(model, system: renameSystem, user: question, key: "name", max: 40)
            return name.isEmpty ? .keep : .rename(name)
        }
        if action.contains("drop") { return .drop }
        if action.contains("merge") {
            let others = courts.enumerated().filter { $0.offset != index }
            // The other area named in the wish, else the model's pick.
            // "Put A with B": A goes into B; B itself stays.
            let lower = step.lowercased()
            if let target = others.first(where: { lower.contains($0.element.name.lowercased()) }) {
                let own = lower.range(of: court.name.lowercased())?.lowerBound
                let theirs = lower.range(of: target.element.name.lowercased())?.lowerBound
                if let own, let theirs, own > theirs { return .keep }
                return .merge(into: target.offset)
            }
            let list = others.map { "\($0.offset). \($0.element.name)" }.joined(separator: "\n")
            let output = try await model.complete(system: targetSystem, user: "\(question)\n\nOther areas:\n\(list)",
                                                  grammar: targetGrammar, maxTokens: 12)
            let target = (try? JSONDecoder().decode([String: Int].self, from: Data(output.utf8)))?["into"]
            if let target, target != index, courts.indices.contains(target) { return .merge(into: target) }
        }
        return .keep
    }

    /// Applies the changes: renames and drops in place, merges into areas that are not merged away themselves.
    public static func apply(_ changes: [Change], to courts: [ProposedCourt]) -> [ProposedCourt] {
        var result = courts
        var removed = Set<Int>()
        for (index, change) in changes.enumerated() where result.indices.contains(index) {
            switch change {
            case .keep: break
            case .rename(let name): if result[index].existing == nil { result[index].name = name }
            case .drop: result[index].include = false
            case .merge(let target):
                guard result.indices.contains(target), !removed.contains(target) else { continue }
                result[target] = SortingEngine.merge(result[index], into: result[target])
                removed.insert(index)
            }
        }
        return result.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }
}
