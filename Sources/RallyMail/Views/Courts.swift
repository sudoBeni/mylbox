import RallyMailCore
import SwiftUI

/// Where everything lives: the courts on the left, the open court with one card per sub-court, its deadlines and
/// people on the right.
struct CourtsView: View {
    @Environment(AppModel.self) private var model
    let courtID: UUID?
    @State private var editingSpace: Space?
    @State private var showLoose = false

    var body: some View {
        let selected = courtID ?? ownCourts.first?.id ?? model.config.spaces.first?.id
        HStack(spacing: 0) {
            courtList(selected: showLoose ? nil : selected)
                .frame(width: 252)
            Group {
                if showLoose {
                    LoosePage()
                } else if let selected, model.space(selected) != nil {
                    CourtPage(courtID: selected).id(selected)
                } else {
                    VStack(spacing: 12) {
                        Text("No courts yet").font(.system(size: 17, weight: .bold))
                        Text("A court is one area of your life, e.g. a club or your business. Let RallyMail propose them from who writes with whom.")
                            .multilineTextAlignment(.center).foregroundStyle(Palette.muted).frame(maxWidth: 380)
                        Button("Sort Mail…") { model.screen = .sorting }.buttonStyle(SmallButtonStyle(filled: true))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.ground)
        .sheet(item: $editingSpace) { SpaceEditor(space: $0) }
        .onChange(of: courtID) { _, _ in showLoose = false }
    }

    private var ownCourts: [Space] {
        model.config.spaces.filter { $0.id != model.config.infosID && $0.id != model.config.graveyardID }
    }

    private func courtList(selected: UUID?) -> some View {
        let special = model.config.spaces.filter { $0.id == model.config.infosID || $0.id == model.config.graveyardID }
        let loose = model.matters(in: nil).filter { !$0.isFolded }
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ownCourts + special) { court in
                    CourtListItem(court: court, on: court.id == selected) {
                        showLoose = false
                        model.screen = .courts(court.id)
                    }
                }
                if !loose.isEmpty {
                    Button {
                        showLoose = true
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.loose, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                .frame(width: 12, height: 12)
                            Text("No court yet").font(.system(size: 13, weight: .bold))
                            Spacer()
                            Text("\(loose.count)").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(showLoose ? Palette.panel : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(showLoose ? Color(hex: 0xD6D1C8) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { editingSpace = Space(name: "") } label: {
                    Text("+ Court").font(.system(size: 13)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xC9C4BC), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                Button { model.screen = .sorting } label: {
                    Label("Sort Mail…", systemImage: "wand.and.stars").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6).padding(.top, 6)
                .help("Let RallyMail propose courts and topics from who writes with whom")
                if !model.courtsForSubCourts.isEmpty || model.subCourtHelp.isBusy {
                    Button { Task { await model.suggestSubCourtsForAll() } } label: {
                        Label(model.subCourtHelp.isBusy ? "Suggesting sub-courts…" : "Suggest Sub-Courts for All", systemImage: "square.grid.3x1.below.line.grid.1x2")
                            .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.subCourtHelp.isBusy)
                    .padding(.horizontal, 6)
                    .help("The local AI proposes sub-courts for every court in turn; each court shows its proposal to check")
                }
            }
            .padding(10)
        }
        .background(Palette.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
}

/// A court in the list: its color, name, sub-courts and how many topics, and how many balls are on your side.
private struct CourtListItem: View {
    @Environment(AppModel.self) private var model
    let court: Space
    let on: Bool
    let action: () -> Void

    var body: some View {
        let topics = model.matters(in: court.id)
        let mine = topics.filter { $0.ball == .mine }.count
        let subs = model.subCourts(of: court.id)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(CourtColor.of(court.id, model)).frame(width: 12, height: 12)
                    Text(court.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Spacer()
                    if mine > 0 { Text("\(mine)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Palette.meText) }
                }
                if !subs.isEmpty {
                    Text(subs.map(\.name).joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        .padding(.leading, 20)
                }
                Text((subs.isEmpty ? "" : "\(subs.count) sub-court\(subs.count == 1 ? "" : "s") · ") + "\(topics.count) topic\(topics.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.leading, 20)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(on ? Palette.panel : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Color(hex: 0xD6D1C8) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One court: a card per sub-court with its topics, a card for topics without one, deadlines and people aside.
struct CourtPage: View {
    @Environment(AppModel.self) private var model
    let courtID: UUID
    @State private var query = ""
    @State private var editingSpace: Space?
    @State private var addingSub = false
    @State private var newSub = ""

    var body: some View {
        let topics = model.matters(in: courtID)
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? topics : topics.filter { matches($0, needle) }
        let subs = model.subCourts(of: courtID)
        let color = CourtColor.of(courtID, model)
        VStack(spacing: 0) {
            header(topics, subs: subs, color: color)
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                    SubCourtHelpPanel(courtID: courtID, withoutSub: topics.filter { model.subCourt(of: $0) == nil }.count, hasSubs: !subs.isEmpty)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(subs) { sub in
                            SubCourtCard(courtID: courtID, sub: sub, topics: shown.filter { model.subCourt(of: $0)?.id == sub.id },
                                         filtering: !needle.isEmpty)
                        }
                        let without = shown.filter { model.subCourt(of: $0) == nil }
                        if !without.isEmpty || subs.isEmpty {
                            WithoutSubCourtCard(courtID: courtID, topics: without, hasSubs: !subs.isEmpty, filtering: !needle.isEmpty) {
                                addingSub = true
                            }
                        }
                    }
                    }
                    .frame(maxWidth: .infinity)
                    CourtAside(courtID: courtID, topics: topics)
                        .frame(width: 290)
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
        }
        .sheet(item: $editingSpace) { SpaceEditor(space: $0) }
    }

    private func header(_ topics: [Matter], subs: [Project], color: Color) -> some View {
        let mine = topics.filter { $0.ball == .mine }.count, theirs = topics.filter { $0.ball == .theirs }.count
        let mails = topics.reduce(0) { $0 + $1.messageCount }
        let first = topics.compactMap { $0.conversations.map(\.firstDate).min() }.min()
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(color).frame(height: 4)
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.space(courtID)?.name ?? "Court").font(.system(size: 24, weight: .bold))
                    (Text((subs.isEmpty ? "" : "\(subs.count) sub-court\(subs.count == 1 ? "" : "s") · ")
                          + "\(topics.count) topics · \(mails) mails" + (first.map { " since \($0.formatted(.dateTime.year()))" } ?? ""))
                     + Text(mine > 0 ? " · " : "") + Text(mine > 0 ? "\(mine) on your side" : "").bold().foregroundColor(Palette.meText)
                     + Text(theirs > 0 ? " · \(theirs) on theirs" : ""))
                        .font(.system(size: 13)).foregroundStyle(Color(hex: 0x4D4A46))
                }
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Filter topics", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.3)))
                .frame(width: 230)
                Button { Task { await model.suggestSubCourts(for: courtID) } } label: {
                    Label("Suggest Sub-Courts", systemImage: "wand.and.stars")
                }
                .buttonStyle(SmallButtonStyle(filled: false))
                .disabled(model.subCourtHelp.working[courtID] != nil)
                .help("The local AI reads each topic once and proposes sub-courts; you check them before anything changes")
                Button("+ Sub-Court") { addingSub = true }
                    .buttonStyle(SmallButtonStyle(filled: false))
                    .popover(isPresented: $addingSub) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New sub-court in \(model.space(courtID)?.name ?? "")").font(.headline)
                            TextField("e.g. Finanzen", text: $newSub).frame(width: 240).onSubmit(addSub)
                            HStack { Spacer(); Button("Cancel") { addingSub = false }; Button("Add", action: addSub).keyboardShortcut(.defaultAction) }
                        }
                        .padding(14)
                    }
                Button("All Mail") {
                    model.feedQuery = FeedQuery()
                    model.feedQuery.space = courtID
                    model.screen = .inbox
                }
                .buttonStyle(SmallButtonStyle(filled: false))
                if let space = model.space(courtID) {
                    Button { editingSpace = space } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(SmallButtonStyle(filled: false))
                        .help("Edit court: name, senders, export")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .background(color.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(0.2)).frame(height: 1) }
    }

    private func addSub() {
        model.addSubCourt(to: courtID, named: newSub)
        newSub = ""
        addingSub = false
    }

    private func matches(_ matter: Matter, _ needle: String) -> Bool {
        matter.title.lowercased().contains(needle)
            || matter.people(isMe: model.isMe).contains { $0.displayName.lowercased().contains(needle) || $0.address.contains(needle) }
            || (matter.conversations.first?.lastSummary?.lowercased().contains(needle) ?? false)
    }
}

/// The order inside a card: open topics first (your side, then theirs), then the most recent quiet ones.
@MainActor
private func cardOrder(_ topics: [Matter]) -> (open: [Matter], quiet: [Matter]) {
    let open = topics.filter { $0.ball == .mine } + topics.filter { $0.ball == .theirs }
    return (open, topics.filter { $0.ball == .quiet })
}

/// A sub-court and its topics.
private struct SubCourtCard: View {
    @Environment(AppModel.self) private var model
    let courtID: UUID
    let sub: Project
    let topics: [Matter]
    let filtering: Bool
    @State private var showAll = false
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let (open, quiet) = cardOrder(topics)
        let quietShown = showAll || filtering ? quiet : Array(quiet.prefix(3))
        let fresh = topics.filter { $0.unreadCount > 0 }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sub.name).font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(topics.count) topic\(topics.count == 1 ? "" : "s")" + (fresh > 0 ? " · \(fresh) new" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                Menu {
                    Button("Rename…") { name = sub.name; renaming = true }
                    Button("Remove Sub-Court", role: .destructive) { model.removeSubCourt(sub.id, in: courtID) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .popover(isPresented: $renaming) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $name).frame(width: 220).onSubmit(rename)
                    HStack { Spacer(); Button("Cancel") { renaming = false }; Button("Rename", action: rename).keyboardShortcut(.defaultAction) }
                }
                .padding(14)
            }
            Divider().overlay(Color(hex: 0xECE9E4))
            if topics.isEmpty {
                Text(filtering ? "Nothing matches." : "No topics yet. Put one here from its menu or the topic's header.")
                    .font(.system(size: 12)).foregroundStyle(Palette.faint).padding(14)
            }
            ForEach(open + quietShown) { matter in
                CourtTopicRow(matter: matter, courtID: courtID)
                Divider().overlay(Color(hex: 0xF3F1ED))
            }
            if quiet.count > quietShown.count {
                Button("+ \(quiet.count - quietShown.count) quiet topic\(quiet.count - quietShown.count == 1 ? "" : "s")") { showAll = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
    }

    private func rename() {
        model.renameSubCourt(sub.id, in: courtID, to: name)
        renaming = false
    }
}

/// Topics of the court in no sub-court, with suggestions where they probably belong.
private struct WithoutSubCourtCard: View {
    @Environment(AppModel.self) private var model
    let courtID: UUID
    let topics: [Matter]
    let hasSubs: Bool
    let filtering: Bool
    let addSub: () -> Void
    @State private var showAll = false

    var body: some View {
        let (open, quiet) = cardOrder(topics)
        let quietShown = showAll || filtering ? quiet : Array(quiet.prefix(hasSubs ? 3 : 8))
        let guesses = hasSubs ? Dictionary(grouping: topics.compactMap { topic in model.guessSubCourt(for: topic, in: courtID).map { (topic, $0) } }) { $0.1.id } : [:]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(hasSubs ? "Without sub-court" : "Topics").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(hasSubs ? Color(hex: 0x4D4A46) : Palette.ink)
                Spacer()
                Text("\(topics.count) topic\(topics.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            FlowLayout(spacing: 6) {
                ForEach(Array(guesses.keys), id: \.self) { key in
                    if let pairs = guesses[key], let sub = pairs.first?.1 {
                        Button("\(pairs.count) to «\(sub.name)»?") {
                            for (topic, _) in pairs { model.setSubCourt(topic.id, sub.id) }
                        }
                        .buttonStyle(OkChipStyle())
                        .help(pairs.map(\.0.title).joined(separator: ", "))
                    }
                }
                Button(hasSubs ? "+ Sub-Court" : "+ Sub-Court to group them", action: addSub).buttonStyle(ChipButtonStyle())
                if topics.count >= 2 && model.subCourtHelp.proposals[courtID] == nil {
                    Button { Task { await model.suggestSubCourts(for: courtID) } } label: { Label("Ask the AI", systemImage: "wand.and.stars") }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(model.subCourtHelp.working[courtID] != nil)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
            Divider().overlay(Color(hex: 0xECE9E4))
            ForEach(open + quietShown) { matter in
                CourtTopicRow(matter: matter, courtID: courtID)
                Divider().overlay(Color(hex: 0xF3F1ED))
            }
            if quiet.count > quietShown.count {
                Button("+ \(quiet.count - quietShown.count) quiet topics") { showAll = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .background(hasSubs ? Color.clear : Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if hasSubs {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xC9C4BC), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            } else {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line)
            }
        }
    }
}

private struct OkChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.okText)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(Palette.okSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: 0xC9E2D6)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A topic inside a court card, with a menu to move it to another sub-court.
private struct CourtTopicRow: View {
    @Environment(AppModel.self) private var model
    let matter: Matter
    let courtID: UUID

    var body: some View {
        TopicLine(matter: matter, detail: detail)
            .contextMenu {
                Button("Open") { model.open(topic: matter.id) }
                let subs = model.subCourts(of: courtID)
                if !subs.isEmpty {
                    Menu("Sub-Court") {
                        ForEach(subs) { sub in Button(sub.name) { model.setSubCourt(matter.id, sub.id) } }
                        Divider()
                        Button("None") { model.setSubCourt(matter.id, nil) }
                    }
                }
                Button("Quiet") { model.quiet(matter.id) }
            }
    }

    private var detail: String? {
        switch matter.ball {
        case .mine: return matter.ask
        case .theirs: return matter.waitingOn.map { "waiting for \(model.shortName($0)), \(Waiting.since(matter.lastDate))" }
        case .quiet: return topicDetail(matter, model)
        }
    }
}

/// Beside the court: what is due in it, who is in it, where it is mirrored.
private struct CourtAside: View {
    @Environment(AppModel.self) private var model
    let courtID: UUID
    let topics: [Matter]

    var body: some View {
        let due = topics.compactMap { topic in model.dues[topic.id].map { (topic, $0) } }.sorted { $0.1 < $1.1 }
        VStack(alignment: .leading, spacing: 14) {
            if !due.isEmpty {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Deadlines in \(model.space(courtID)?.name ?? "")")
                        ForEach(due.prefix(8), id: \.0.id) { topic, date in
                            Button { model.open(topic: topic.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(DueText.label(date)).font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(DueText.isHot(date) ? Palette.meText : Palette.ink)
                                        .frame(width: 64, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(topic.ask ?? topic.title).font(.system(size: 12.5)).lineLimit(2)
                                        Text(model.subCourt(of: topic)?.name ?? topic.title).font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            people
            if let folder = model.space(courtID)?.exportFolder {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle("Mirrored")
                        Text("Written as Markdown to \((folder as NSString).abbreviatingWithTildeInPath).")
                            .font(.system(size: 12.5)).foregroundStyle(Color(hex: 0x3D3B38))
                    }
                }
            }
        }
    }

    /// The people who write most in the court, with the sub-courts they appear in.
    private var topPeople: [(EmailAddress, Int, Set<String>)] {
        var counts: [String: (EmailAddress, Int, Set<String>)] = [:]
        for topic in topics {
            let sub = model.subCourt(of: topic)?.name
            for person in topic.people(isMe: model.isMe) {
                let key = person.address.lowercased()
                var entry = counts[key] ?? (person, 0, [])
                entry.1 += topic.messageCount
                if let sub { entry.2.insert(sub) }
                counts[key] = entry
            }
        }
        return Array(counts.values.sorted { $0.1 > $1.1 }.prefix(6))
    }

    @ViewBuilder private var people: some View {
        let top = topPeople
        if !top.isEmpty {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("People in \(model.space(courtID)?.name ?? "")")
                    ForEach(Array(top), id: \.0.address) { person, mails, subs in
                        HStack(spacing: 9) {
                            Avatar(person, size: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                Text(([subs.sorted().joined(separator: ", ")].filter { !$0.isEmpty } + ["\(mails) mails"]).joined(separator: " · "))
                                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button("New Mail to \(person.displayName)") { model.newMail(to: [person]) }
                            Button("All Mail from \(person.displayName)") {
                                model.feedQuery = FeedQuery()
                                model.feedQuery.from = person.address.lowercased()
                                model.screen = .inbox
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Topics in no court, with RallyMail's suggestion for each.
private struct LoosePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loose = model.matters(in: nil).filter { !$0.isFolded }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("No court yet").font(.system(size: 24, weight: .bold))
                    Text("\(loose.count) topics · placing is optional").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Sort Mail…") { model.screen = .sorting }.buttonStyle(SmallButtonStyle(filled: false))
                }
                VStack(spacing: 0) {
                    ForEach(loose.prefix(200)) { matter in
                        HStack(spacing: 12) {
                            TopicLine(matter: matter, detail: topicDetail(matter, model))
                            if let placement = model.placement(for: matter) {
                                Button(placement.sub.map { "\(model.space(placement.court)?.name ?? "") › \($0.name)" }
                                       ?? model.space(placement.court)?.name ?? "") { model.accept(placement, for: matter.id) }
                                    .buttonStyle(ChipButtonStyle(bold: true))
                                    .help(placement.why)
                            }
                            CourtMenu(matter: matter, title: "Court…").frame(width: 90)
                        }
                        .padding(.trailing, 12)
                        Divider().overlay(Color(hex: 0xF3F1ED))
                    }
                }
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
            }
            .padding(24)
        }
    }
}

/// Above a court's cards: the AI's sub-court proposal to check, its progress, or a hint for big courts without
/// sub-courts (mostly while setting RallyMail up).
private struct SubCourtHelpPanel: View {
    @Environment(AppModel.self) private var model
    let courtID: UUID
    let withoutSub: Int
    let hasSubs: Bool
    @AppStorage("subCourtHintDismissed") private var dismissed = ""

    var body: some View {
        let help = model.subCourtHelp
        if let working = help.working[courtID] {
            Card(padding: 14, fill: Palette.okSoft, stroke: Color(hex: 0xC9E2D6)) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Proposing sub-courts · \(working)").font(.system(size: 13)).foregroundStyle(Palette.okText)
                }
            }
        } else if help.waiting.contains(courtID) {
            Card(padding: 12, fill: Palette.chip, stroke: Palette.line) {
                Text("Sub-courts for this court come after the others.").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
        } else if let proposals = help.proposals[courtID] {
            proposal(proposals)
        } else if !hasSubs, withoutSub >= 8, !dismissed.contains(courtID.uuidString) {
            Card(padding: 14, fill: Palette.okSoft, stroke: Color(hex: 0xC9E2D6)) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.system(size: 18)).foregroundStyle(Palette.ok)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(withoutSub) topics and no sub-courts yet").font(.system(size: 13, weight: .semibold))
                        Text(model.cloudModel != nil
                             ? "\(model.config.cloudModelID) (OpenRouter) can propose sub-courts from the topics' titles and summaries. You check everything before it changes."
                             : "The local AI can propose sub-courts: it reads each topic once, on your Mac. You check everything before it changes.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("Not now") { dismissed += courtID.uuidString + "," }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("Suggest Sub-Courts") { Task { await model.suggestSubCourts(for: courtID) } }.buttonStyle(SmallButtonStyle(filled: true))
                }
            }
        }
    }

    private func proposal(_ proposals: [ProposedSubCourt]) -> some View {
        let help = model.subCourtHelp
        let checked = proposals.filter(\.include).count
        return Card(padding: 0, fill: Palette.panel, stroke: Color(hex: 0xC9E2D6)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Suggested sub-courts", systemImage: "wand.and.stars").font(.system(size: 15, weight: .bold))
                    Text(proposals.isEmpty ? "nothing in common found" : "rename or uncheck, then create · \(help.rest[courtID] ?? 0) topics stay without")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Discard") { model.discardSubCourts(for: courtID) }.buttonStyle(SmallButtonStyle(filled: false))
                    Button(checked == 1 ? "Create 1 Sub-Court" : "Create \(checked) Sub-Courts") { model.applySubCourts(for: courtID) }
                        .buttonStyle(SmallButtonStyle(filled: true))
                        .disabled(checked == 0)
                }
                .padding(14)
                .background(Palette.okSoft)
                ForEach(proposals.indices, id: \.self) { index in
                    Divider().overlay(Color(hex: 0xECE9E4))
                    row(index, proposals[index])
                }
            }
        }
    }

    private func row(_ index: Int, _ proposal: ProposedSubCourt) -> some View {
        let help = model.subCourtHelp
        let titles = proposal.topics.compactMap { model.matter($0)?.title }
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { help.proposals[courtID]?[safe: index]?.include ?? false },
                                     set: { help.proposals[courtID]?[index].include = $0 }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    TextField("Name", text: Binding(get: { help.proposals[courtID]?[safe: index]?.name ?? "" },
                                                    set: { help.proposals[courtID]?[index].name = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(maxWidth: 220)
                    if proposal.existing != nil {
                        Text("adds to the existing sub-court").font(.system(size: 11)).foregroundStyle(Palette.okText)
                    }
                    Spacer()
                    Text("\(proposal.topics.count) topic\(proposal.topics.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
                Text(titles.prefix(5).joined(separator: " · ") + (titles.count > 5 ? " · …" : ""))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
                    .help(titles.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(proposal.include ? 1 : 0.5)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
