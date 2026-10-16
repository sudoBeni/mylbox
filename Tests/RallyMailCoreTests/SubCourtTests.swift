import Foundation
import Testing
@testable import RallyMailCore

@Suite struct SubCourtGroupingTests {
    @Test func sameNameUpToPluralAndCase() {
        #expect(SubCourtProposer.same("Rechnung", "Rechnungen"))
        #expect(SubCourtProposer.same("server", "Servers"))
        #expect(SubCourtProposer.same("Löhne", "löhne"))
        #expect(!SubCourtProposer.same("Lager", "Löhne"))
    }

    @Test func cleansAnswers() {
        #expect(SubCourtProposer.clean(" rechnungen. ", court: "VBC Finanzen") == "Rechnungen")
        #expect(SubCourtProposer.clean("keine", court: "VBC") == nil)
        #expect(SubCourtProposer.clean("Sonstiges", court: "VBC") == nil)
        #expect(SubCourtProposer.clean("vbc finanzen", court: "VBC Finanzen") == nil)
    }

    @Test func groupsNamesWithTwoTopicsOrAnExistingSubCourt() {
        let existing = UUID()
        let labels: [(key: String, label: String)] = [
            ("a", "Rechnungen"), ("b", "Rechnung"), ("c", "Trainingslager"), ("d", "Löhne"), ("e", "Trainingslager"), ("f", "Lohn"),
        ]
        let result = SubCourtProposer.group(labels, existing: [(existing, "Lohn")], total: 7)
        #expect(result.proposals.map(\.name) == ["Rechnungen", "Trainingslager", "Lohn"])
        #expect(result.proposals[0].topics == ["a", "b"])
        #expect(result.proposals[2].existing == existing && result.proposals[2].topics == ["f"])
        // "Löhne" alone is no proposal; it and the topic without an answer stay without a sub-court.
        #expect(result.rest == 2)
    }
}

@Suite struct CloudSubCourtTests {
    let cards = (1...6).map { SubCourtCard(key: "k\($0)", title: "Topic \($0)") }

    @Test func readsTheGroupsAndChecksThem() throws {
        let existing = UUID()
        let answer = #"{"subcourts": [{"name": "Rechnungen", "topics": [1, 2, 9]}, {"name": "Löhne", "topics": [2, 3]},"# +
            #" {"name": "Trainingslager", "topics": [4]}, {"name": "VBC", "topics": [5, 6]}]}"#
        let result = try SubCourtProposer.parseCloud(answer, topics: cards, existing: [(existing, "Trainingslager")], court: "VBC Finanzen")
        // 9 is no topic, 2 is taken already, the area's own name is no sub-court; an existing one may get a single topic.
        #expect(result.proposals.map(\.name) == ["Rechnungen", "Trainingslager"])
        #expect(result.proposals[0].topics == ["k1", "k2"])
        #expect(result.proposals[1].existing == existing)
        #expect(result.rest == 3)
    }

    @Test func cutsTheJsonOutOfAnAnswer() {
        #expect(OpenRouter.jsonObject(in: "```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
    }
}

/// Real-model check on a copy of the database:
///   RALLYMAIL_MODEL=<gguf> RALLYMAIL_AUDIT=<db copy> RALLYMAIL_AUDIT_CONFIG=<config.json> swift test --filter SubCourtAudit
///   (or RALLYMAIL_OPENROUTER_KEY=<key> [RALLYMAIL_OPENROUTER_MODEL=<id>] instead of RALLYMAIL_MODEL for the cloud way)
@Suite(.enabled(if: (ProcessInfo.processInfo.environment["RALLYMAIL_MODEL"] != nil || ProcessInfo.processInfo.environment["RALLYMAIL_OPENROUTER_KEY"] != nil)
                   && ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"] != nil))
struct SubCourtAudit {
    @Test func proposeForEachCourt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let store = try MailStore(url: URL(fileURLWithPath: environment["RALLYMAIL_AUDIT"]!))
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: environment["RALLYMAIL_AUDIT_CONFIG"]!)))
        // With RALLYMAIL_OPENROUTER_KEY (and RALLYMAIL_OPENROUTER_MODEL) the cloud way is checked instead.
        let cloud = environment["RALLYMAIL_OPENROUTER_KEY"].map { OpenRouter(apiKey: $0, model: environment["RALLYMAIL_OPENROUTER_MODEL"] ?? "anthropic/claude-sonnet-5.5") }
        let model: any TextModel = try cloud ?? LocalModel(path: environment["RALLYMAIL_MODEL"]!)
        let own = Set(config.accounts.map { $0.email.lowercased() })
        var query = ConversationQuery(scope: .all)
        query.limit = 1_000_000
        let matters = Matter.group(try store.conversations(query)) { own.contains($0.address.lowercased()) }
        for court in config.spaces where court.id != config.graveyardID {
            let topics = matters.filter { $0.spaceID == court.id }.prefix(60)
            guard topics.count >= 4 else { continue }
            let cards = topics.map { matter in
                SubCourtCard(key: matter.id, title: matter.title, keyword: matter.conversations[0].lastTopic ?? "",
                             summary: matter.conversations[0].lastSummary ?? "",
                             people: matter.people { own.contains($0.address.lowercased()) }.map(\.displayName))
            }
            if environment["RALLYMAIL_AUDIT_LABELS"] != nil {
                for card in cards.prefix(30) { print("    \(card.title.prefix(50)) → \(try await SubCourtProposer.label(card, court: court.name, language: "German", model: model) ?? "-")") }
                continue
            }
            let start = Date()
            let result = cloud != nil
                ? try await SubCourtProposer.proposeWithCloud(court: court.name, topics: Array(cards), existing: [], language: "German", model: model)
                : try await SubCourtProposer.propose(court: court.name, topics: Array(cards), existing: [], language: "German", model: model) { _, _ in }
            print("== \(court.name): \(cards.count) topics in \(Int(Date().timeIntervalSince(start)))s, \(result.rest) left over")
            for proposal in result.proposals {
                let titles = proposal.topics.compactMap { key in cards.first { $0.key == key }?.title }
                print("  \(proposal.name) (\(proposal.topics.count)): \(titles.prefix(6).joined(separator: " | "))")
            }
        }
    }
}
