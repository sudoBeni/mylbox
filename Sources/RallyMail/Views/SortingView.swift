import RallyMailCore
import SwiftUI

/// The sorting assistant: it proposes courts and topics from the mail; the user checks, renames, merges, asks the
/// AI for changes in their own words, and takes it over.
struct SortingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.sorting
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sort Your Mail").font(.system(size: 15, weight: .semibold))
                    Text("Proposed courts and topics · nothing changes until you take it over")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if session.phase == .review {
                    Button("Start Over") { Task { await model.startSorting() } }
                }
                Button("Close") { model.screen = .courts(nil) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            switch session.phase {
            case .start: start
            case .working(let text):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            case .review: review
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RallyMail looks at who you write with and proposes a court for each area: people who write together, and people of the same organisation, end up together. Conversations with a shared case or order number become one topic.")
            Text(model.config.aiClassificationEnabled && model.selectedModel.isDownloaded
                 ? "The local AI names each area, one small step at a time. Nothing leaves your Mac."
                 : "The local AI is off, so areas are named after their people or organisation. You can rename them.")
                .foregroundStyle(.secondary)
            Text("Mail already in a court stays where it is.").foregroundStyle(.secondary)
            Button {
                Task { await model.startSorting() }
            } label: {
                Label("Propose Courts and Topics", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .font(.system(size: 13))
        .frame(maxWidth: 560, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var review: some View {
        @Bindable var session = model.sorting
        let chosen = session.courts.filter(\.include)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(session.courts.count) areas found. Check what fits, rename, put areas together or leave them out.\(session.rest > 0 ? " \(session.rest) conversation\(session.rest == 1 ? "" : "s") with one-off contacts fit\(session.rest == 1 ? "s" : "") no area and stay\(session.rest == 1 ? "s" : "") without a court." : "")")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    ForEach($session.courts) { $court in
                        ProposedCourtCard(court: $court)
                    }
                    if session.courts.isEmpty {
                        Text("No areas found yet. With more mail from people there is more to group.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 760)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    TextField("Tell the AI what to change, e.g. “Put Training with Volleyball and call Kanzlei Lawyer”", text: $session.wish)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.reviseSorting() } }
                    Button("Improve") { Task { await model.reviseSorting() } }
                        .disabled(session.wish.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text("\(chosen.count) courts · \(chosen.reduce(0) { $0 + $1.threadIDs.count }) conversations · \(chosen.reduce(0) { $0 + $1.topics.filter(\.include).count }) topics")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Take Over") { model.applySorting() }
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen.isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

/// One proposed court: take it or not, its name, what it is about, its people, examples and topics.
private struct ProposedCourtCard: View {
    @Environment(AppModel.self) private var model
    @Binding var court: ProposedCourt
    @State private var showTopics = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $court.include).labelsHidden().toggleStyle(.checkbox).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if let existing = court.existing {
                        Text(model.space(existing)?.name ?? court.name).font(.system(size: 14, weight: .bold))
                        Text("existing court").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.06), in: Capsule())
                    } else {
                        TextField("Name", text: $court.name).textFieldStyle(.plain).font(.system(size: 14, weight: .bold))
                    }
                    Spacer()
                    Text("\(court.threadIDs.count) conversations · \(court.messageCount) mails").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Menu {
                        ForEach(model.sorting.courts.filter { $0.id != court.id }) { other in
                            Button(other.name) { model.mergeProposal(court.id, into: other.id) }
                        }
                    } label: { Image(systemName: "arrow.triangle.merge") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Put this area into another one")
                }
                if !court.about.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("AI").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2)))
                        Text(court.about).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    AvatarStack(people: court.people, size: 20)
                    Text(court.people.prefix(4).map(\.displayName).joined(separator: ", ")
                         + (court.domains.isEmpty ? "" : " · " + court.domains.prefix(2).joined(separator: ", ")))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(court.subjects.prefix(3).map { "„\($0)“" }.joined(separator: "  "))
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                if !court.topics.isEmpty {
                    DisclosureGroup(isExpanded: $showTopics) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach($court.topics) { $topic in
                                Toggle(isOn: $topic.include) {
                                    HStack(spacing: 6) {
                                        Text(topic.title).lineLimit(1)
                                        Text("\(topic.threadIDs.count) conversations\(topic.reference.map { " · \($0)" } ?? "")")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .font(.system(size: 12))
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("\(court.topics.count) topic\(court.topics.count == 1 ? "" : "s") put together").font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .opacity(court.include ? 1 : 0.55)
    }
}

/// Next to the assistant: how it works.
struct SortingSide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("HOW IT WORKS").font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                Text("**Areas** come from who writes with whom, and from organisations (same domain). Mail providers like Gmail or Bluewin don't count as organisations.")
                Text("**Names** come from the local AI in two small steps: what the mail is about, then a short name.")
                Text("**Your wish** is split into single changes; each is checked area by area: does it concern this area, what should happen, and into which area to merge.")
                Text("**Topics** are conversations that share a case or order number.")
                Text("**Taking over** creates the new courts and puts mail without a court into them. Mail you sorted before stays.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(14)
        }
    }
}
