import Foundation
import Observation
import RallyMailCore

/// The sorting assistant's state: the proposal, and what it is doing.
@MainActor
@Observable
final class SortingSession {
    enum Phase: Equatable {
        case start
        case working(String)
        case review
    }

    var phase: Phase = .start
    var courts: [ProposedCourt] = []
    /// Conversations that fit no group (one-off contacts).
    var rest = 0
    /// Whether the local model named and revised the proposal.
    var withModel = false
    var wish = ""
}

extension AppModel {
    /// Groups the mail into proposed courts and topics, then lets the local model name each, one small step at a time.
    func startSorting() async {
        sorting.phase = .working("Looking at who writes with whom…")
        var query = ConversationQuery(scope: .all)
        query.limit = 1_000_000
        let conversations = (try? store.conversations(query)) ?? []
        let special = Set([config.infosID, config.graveyardID].compactMap { $0 })
        let since = Calendar.current.date(byAdding: .month, value: -18, to: Date())
        let found = SortingEngine.propose(conversations, courts: config.spaces.filter { !special.contains($0.id) }, isMe: isMe, since: since)
        sorting.courts = found.courts
        sorting.rest = found.rest
        sorting.withModel = false
        if let model = await setupModel() {
            defer { releaseSetupModel() }
            sorting.withModel = true
            let unnamed = sorting.courts.indices.filter { sorting.courts[$0].existing == nil }
            for (step, index) in unnamed.enumerated() {
                sorting.phase = .working("Naming area \(step + 1) of \(unnamed.count)…")
                if let named = try? await CourtNaming.name(sorting.courts[index], model: model) {
                    sorting.courts[index].name = named.name
                    sorting.courts[index].about = named.about
                }
            }
        }
        sorting.phase = .review
    }

    /// The user's wish in their own words, worked through by the model in small steps.
    func reviseSorting() async {
        let wish = sorting.wish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wish.isEmpty else { return }
        sorting.phase = .working("Reading your wish…")
        guard let model = await setupModel() else {
            sorting.phase = .review
            banner = "The local AI is off or not downloaded. Turn it on in Settings, or change the proposal by hand."
            return
        }
        defer { releaseSetupModel() }
        let session = sorting
        if let revised = try? await CourtNaming.revise(sorting.courts, wish: wish, model: model, progress: { text in
            await MainActor.run { session.phase = .working(text) }
        }) {
            sorting.courts = revised
            sorting.wish = ""
        } else {
            banner = "The AI could not work out that wish. Try saying it more simply, or change it by hand."
        }
        sorting.phase = .review
    }

    /// Puts one proposed court into another.
    func mergeProposal(_ source: UUID, into target: UUID) {
        guard let from = sorting.courts.firstIndex(where: { $0.id == source }),
              let to = sorting.courts.firstIndex(where: { $0.id == target }) else { return }
        sorting.courts[to] = SortingEngine.merge(sorting.courts[from], into: sorting.courts[to])
        sorting.courts.remove(at: from)
    }

    /// Takes the checked courts and topics over. Mail already in a court or topic stays where the user put it.
    func applySorting() {
        let chosen = sorting.courts.filter(\.include)
        let newCourts = chosen.filter { $0.existing == nil }
        updateConfig { config in
            let before = config.spaces.firstIndex { $0.id == config.infosID } ?? config.spaces.endIndex
            for (offset, court) in newCourts.enumerated() {
                var space = Space(name: court.name)
                space.id = court.id
                config.spaces.insert(space, at: before + offset)
            }
        }
        var topics = 0
        for court in chosen {
            let space = court.existing ?? court.id
            for thread in court.threadIDs { try? store.setSpaceIfNone(thread: thread, space: space, how: "sorting") }
            for topic in court.topics where topic.include && topic.threadIDs.count > 1 {
                guard let matter = try? store.createMatter(title: topic.title) else { continue }
                for thread in topic.threadIDs { try? store.setMatterIfNone(thread: thread, matter: matter) }
                topics += 1
            }
        }
        reload()
        scheduleExport()
        sorting.phase = .start
        sorting.courts = []
        screen = .courts(nil)
        show(Toast(text: "\(newCourts.count) new court\(newCourts.count == 1 ? "" : "s"), \(chosen.count - newCourts.count) filled, \(topics) topic\(topics == 1 ? "" : "s") put together"))
    }

    /// The cloud model for setting up, when the user switched it on and gave a key; nil otherwise.
    var cloudModel: OpenRouter? {
        guard config.cloudForSetup, !config.cloudModelID.isEmpty,
              let key = Keychain.get(OpenRouter.keychainKey), !key.isEmpty else { return nil }
        return OpenRouter(apiKey: key, model: config.cloudModelID)
    }

    /// The model for setting up: the cloud one when switched on, else the local one (borrowed from mail sorting).
    func setupModel() async -> (any TextModel)? {
        if let cloud = cloudModel { return cloud }
        return await borrowModel()
    }

    /// Gives the local model back after `setupModel()`; nothing to do for the cloud one.
    func releaseSetupModel() {
        if cloudModel == nil { returnModel() }
    }

    /// The model for the assistant, once mail sorting is not using it; nil when the AI is off or not downloaded.
    func borrowModel() async -> LocalModel? {
        guard config.aiClassificationEnabled, selectedModel.isDownloaded else { return nil }
        sortingUsesModel = true
        while triageProgress != nil { try? await Task.sleep(for: .milliseconds(300)) }
        let model = await loadedModel()
        if model == nil { sortingUsesModel = false }
        return model
    }

    func returnModel() {
        sortingUsesModel = false
        releaseModel()
        Task { await runTriage() }
    }
}
