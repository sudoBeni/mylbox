import Foundation
import Observation
import RallyMailCore

/// Sub-courts the local model proposes, per court: what it is doing, and the proposal to check.
@MainActor
@Observable
final class SubCourtHelp {
    var proposals: [UUID: [ProposedSubCourt]] = [:]
    /// Topics that fit no proposal, per court.
    var rest: [UUID: Int] = [:]
    /// What the model is doing for a court ("Reading topic 12 of 40…").
    var working: [UUID: String] = [:]
    /// Courts waiting for their turn when all are asked at once.
    var waiting: [UUID] = []

    var isBusy: Bool { !working.isEmpty || !waiting.isEmpty }
}

extension AppModel {
    /// Courts worth sub-courts: the user's own, with a few topics not in a sub-court yet.
    var courtsForSubCourts: [Space] {
        config.spaces.filter { space in
            space.id != config.graveyardID
                && matters(in: space.id).filter { subCourt(of: $0) == nil }.count >= 6
        }
    }

    /// Lets the local model propose sub-courts for one court: one small question per topic, then rules group them.
    func suggestSubCourts(for court: UUID) async {
        guard let space = space(court), subCourtHelp.working[court] == nil else { return }
        subCourtHelp.waiting.removeAll { $0 == court }
        // A cloud model sees the whole court at once; the local one goes topic by topic.
        let cloud = cloudModel
        let topics = Array(matters(in: court).filter { subCourt(of: $0) == nil }.prefix(cloud == nil ? 80 : 300))
        guard topics.count >= 2 else {
            show(Toast(text: "\(space.name) has too few topics without a sub-court"))
            return
        }
        subCourtHelp.working[court] = cloud.map { "Asking \($0.model) via OpenRouter about \(topics.count) topics…" } ?? "Waiting for the local AI…"
        defer { subCourtHelp.working[court] = nil }
        if let cloud {
            let cards = topics.map { matter in
                SubCourtCard(key: matter.id, title: matter.title, keyword: matter.conversations[0].lastTopic ?? "",
                             summary: matter.conversations[0].lastSummary ?? "")
            }
            do {
                let result = try await SubCourtProposer.proposeWithCloud(court: space.name, topics: cards,
                                                                         existing: subCourts(of: court).map { ($0.id, $0.name) },
                                                                         language: Self.userLanguage, model: cloud)
                subCourtHelp.proposals[court] = result.proposals
                subCourtHelp.rest[court] = result.rest
                if result.proposals.isEmpty { show(Toast(text: "No sub-courts found for \(space.name)")) }
            } catch {
                banner = "OpenRouter could not propose sub-courts: \(error.localizedDescription)"
            }
            return
        }
        guard let model = await borrowModel() else {
            banner = "The local AI is off or not downloaded. Turn it on in Settings, or add sub-courts by hand."
            return
        }
        defer { returnModel() }
        let cards = topics.map { matter in
            SubCourtCard(key: matter.id, title: matter.title, keyword: matter.conversations[0].lastTopic ?? "",
                         summary: matter.conversations[0].lastSummary ?? "",
                         people: matter.people(isMe: isMe).map(\.displayName))
        }
        let help = subCourtHelp
        do {
            let result = try await SubCourtProposer.propose(court: space.name, topics: cards,
                                                            existing: subCourts(of: court).map { ($0.id, $0.name) },
                                                            language: Self.userLanguage, model: model) { done, total in
                await MainActor.run { help.working[court] = "Reading topic \(done) of \(total)…" }
            }
            subCourtHelp.proposals[court] = result.proposals
            subCourtHelp.rest[court] = result.rest
            if result.proposals.isEmpty { show(Toast(text: "No sub-courts found for \(space.name): its topics have little in common")) }
        } catch {
            banner = "The local AI could not propose sub-courts: \(error.localizedDescription)"
        }
    }

    /// Asks for every court in turn (for setting RallyMail up).
    func suggestSubCourtsForAll() async {
        let courts = courtsForSubCourts.map(\.id).filter { subCourtHelp.proposals[$0] == nil }
        subCourtHelp.waiting = courts
        for court in courts where subCourtHelp.waiting.contains(court) {
            await suggestSubCourts(for: court)
        }
        subCourtHelp.waiting = []
    }

    /// The language sub-courts are named in: the Mac's first language ("German").
    static var userLanguage: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// Creates the checked sub-courts and puts their topics in. Topics already in a sub-court stay where they are.
    func applySubCourts(for court: UUID) {
        guard let proposals = subCourtHelp.proposals[court] else { return }
        let chosen = proposals.filter { $0.include && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        var created: [UUID: Project] = [:]
        for proposal in chosen where proposal.existing == nil {
            created[proposal.id] = Project(name: proposal.name.trimmingCharacters(in: .whitespaces))
        }
        updateConfig { config in
            if let index = config.spaces.firstIndex(where: { $0.id == court }) {
                config.spaces[index].projects += chosen.compactMap { created[$0.id] }
            }
        }
        var moved = 0
        for proposal in chosen {
            guard let sub = proposal.existing ?? created[proposal.id]?.id else { continue }
            for key in proposal.topics {
                guard let matter = matter(key), matter.spaceID == court, subCourt(of: matter) == nil else { continue }
                for thread in matter.threadIDs { try? store.setProject(thread: thread, project: sub) }
                moved += 1
            }
        }
        subCourtHelp.proposals[court] = nil
        subCourtHelp.rest[court] = nil
        reload()
        scheduleExport()
        show(Toast(text: "\(created.count) sub-court\(created.count == 1 ? "" : "s") made, \(moved) topic\(moved == 1 ? "" : "s") sorted in"))
    }

    func discardSubCourts(for court: UUID) {
        subCourtHelp.proposals[court] = nil
        subCourtHelp.rest[court] = nil
    }
}
