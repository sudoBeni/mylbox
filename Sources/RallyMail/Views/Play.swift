import RallyMailCore
import SwiftUI

/// The start screen: the court. On your side of the net the topics where the ball is with you, on theirs the ones
/// you wait for; quiet topics sit on the bench. Rally sums up on top, new mail without a place comes as tiles,
/// and the to-dos sit in a bar on the right.
struct PlayView: View {
    @Environment(AppModel.self) private var model
    @State private var court: UUID?
    @AppStorage("todoBarOpen") private var todoOpen = true

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RallyCard()
                    if !model.unplaced.isEmpty { LooseSection() }
                    courtFilter
                    FieldView(court: court)
                    BenchView(court: court)
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 32)
                .frame(maxWidth: 1360)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.ground)
            TodoBar(open: $todoOpen)
        }
    }

    private var courtFilter: some View {
        let mine = model.matters.filter { $0.ball == .mine && !$0.isFolded }
        let courts = model.config.spaces.filter { $0.id != model.config.graveyardID }
        return FlowLayout(spacing: 6) {
            Pill(title: "All", on: court == nil, count: mine.isEmpty ? nil : "\(mine.count)") { court = nil }
            ForEach(courts) { space in
                let count = mine.filter { $0.spaceID == space.id }.count
                Pill(title: space.name, on: court == space.id, color: CourtColor.of(space.id, model), count: count > 0 ? "\(count)" : nil) {
                    court = court == space.id ? nil : space.id
                }
            }
        }
    }
}

// MARK: - Rally

/// Rally's few sentences about what came in, read aloud on request, and quick questions.
struct RallyCard: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""

    var body: some View {
        Card(padding: 14, radius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Text("R").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Palette.me, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(briefing).font(.system(size: 14.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == "rallymail", url.host == "topic" else { return .systemAction }
                                model.open(topic: url.lastPathComponent)
                                return .handled
                            })
                            .tint(Palette.ink)
                        Text("From the mail itself, on your Mac.").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Button { model.speaker.toggle(model.spokenBriefing) } label: {
                        Label(model.speaker.isSpeaking ? "Stop" : "Read Aloud", systemImage: model.speaker.isSpeaking ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(ChipButtonStyle(bold: true))
                    ForEach(RallyPrompt.allCases, id: \.self) { prompt in
                        Button(prompt.question) { model.ask(prompt) }.buttonStyle(ChipButtonStyle())
                    }
                    TextField("Ask Rally …", text: $question)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(Palette.line))
                        .frame(maxWidth: 260)
                        .onSubmit {
                            model.ask(question: question)
                            question = ""
                        }
                }
                .padding(.leading, 48)
                if let entry = model.rallyLog.last {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.question).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                            RallyAnswerView(entry: entry)
                        }
                        Spacer()
                        Button { model.rallyLog.removeAll() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(Palette.faint)
                    }
                    .font(.system(size: 13))
                    .padding(12)
                    .background(Palette.chip.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.leading, 48)
                }
            }
        }
        .onDisappear { model.speaker.stop() }
    }

    /// "Good morning, Beni. 23 new mails, 9 of them infos. 14 balls are on your side, 3 due today or tomorrow: …"
    private var briefing: AttributedString {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 11 ? "Good morning" : hour < 18 ? "Hello" : "Good evening"
        let name = model.config.accounts.first?.name.split(separator: " ").first.map(String.init) ?? ""
        var text = AttributedString(name.isEmpty ? "\(greeting). " : "\(greeting), \(name). ")
        text.font = .system(size: 14.5, weight: .bold)
        let fresh = model.fresh
        let infos = fresh.filter { model.matter(of: $0)?.spaceID == model.config.infosID }.count
        var parts: [String] = []
        if fresh.isEmpty {
            parts.append("Nothing new.")
        } else {
            parts.append("\(fresh.count) new mail\(fresh.count == 1 ? "" : "s")" + (infos > 0 ? ", \(infos) of them only infos." : "."))
        }
        let mine = model.matters.filter { $0.ball == .mine && !$0.isFolded }
        let urgent = mine.filter { model.dues[$0.id].map { DueText.isHot($0) } ?? false }
        if mine.isEmpty {
            parts.append(" No ball on your side.")
        } else {
            parts.append(" \(mine.count) ball\(mine.count == 1 ? " is" : "s are") on your side")
            parts.append(urgent.isEmpty ? "." : ", \(urgent.count) due today or tomorrow: ")
        }
        text += AttributedString(parts.joined())
        for (index, matter) in urgent.prefix(3).enumerated() {
            var link = AttributedString(matter.title)
            link.link = URL(string: "rallymail://topic/\(matter.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")
            link.font = .system(size: 14.5, weight: .semibold)
            link.underlineStyle = .single
            text += link
            text += AttributedString(index < min(urgent.count, 3) - 1 ? ", " : ".")
        }
        if let longest = model.matters.filter({ $0.ball == .theirs && Waiting.isLong($0.lastDate) && !Waiting.isStale($0.lastDate) })
            .min(by: { $0.lastDate < $1.lastDate }),
           let person = longest.waitingOn {
            text += AttributedString(" You have waited \(Waiting.since(longest.lastDate)) for \(model.shortName(person)).")
        }
        return text
    }
}

/// Rally's answer to a question: topics, mails or a sentence.
struct RallyAnswerView: View {
    @Environment(AppModel.self) private var model
    let entry: RallyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.intro.isEmpty { Text(entry.intro) }
            switch entry.answer {
            case .text(let text):
                Text(text)
            case .topics(let keys):
                ForEach(keys.prefix(12), id: \.self) { key in
                    if let matter = model.matter(key) {
                        Button { model.open(topic: key) } label: {
                            HStack(spacing: 6) {
                                BallGlyph(ball: matter.ball, width: 18)
                                Text(matter.title).fontWeight(.semibold).underline()
                                if let detail = topicDetail(matter, model) { Text(detail).foregroundStyle(Palette.muted).lineLimit(1) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .mails(let ids):
                ForEach(ids.prefix(12), id: \.self) { id in
                    if let message = try? model.store.message(id) {
                        Button { model.open(topic: message.matterKey, at: id) } label: {
                            HStack(spacing: 6) {
                                Text(message.summary ?? Threading.normalizedSubject(message.subject)).fontWeight(.semibold).underline().lineLimit(1)
                                Text("· \(model.shortName(message.from)), \(DateText.short(message.date))").foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Outlined capsule buttons (Rally's prompts).
struct ChipButtonStyle: ButtonStyle {
    var bold = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: bold ? .semibold : .regular))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Palette.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - New mail without a place

/// New topics in no court as tiles, each with RallyMail's suggestion. Placing is optional.
private struct LooseSection: View {
    @Environment(AppModel.self) private var model
    private static let shown = 6

    var body: some View {
        let loose = model.unplaced
        let suggested = loose.filter { model.placement(for: $0) != nil }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New, not placed yet · \(loose.count)").font(.system(size: 13, weight: .bold))
                Text(suggested == loose.count ? "each with a suggestion · placing is optional" : "\(suggested) with a suggestion · placing is optional")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                if suggested > 0 {
                    Button("Take all \(suggested) suggestions") { model.acceptAllPlacements() }
                        .buttonStyle(SmallButtonStyle(filled: true))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(loose.prefix(Self.shown)) { LooseTile(matter: $0) }
                if loose.count > Self.shown {
                    Button {
                        model.inboxOnlyUnplaced = true
                        model.screen = .inbox
                    } label: {
                        Text("+ \(loose.count - Self.shown) more").font(.system(size: 13)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One new topic without a place: who, what, how it starts, and where it probably belongs.
private struct LooseTile: View {
    @Environment(AppModel.self) private var model
    let matter: Matter

    var body: some View {
        let newest = matter.conversations[0]
        let placement = model.placement(for: matter)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(newest.lastFrom.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                Text(matter.title).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer(minLength: 4)
                Text(DateText.short(matter.lastDate)).font(.system(size: 12)).foregroundStyle(Palette.faint)
            }
            Text(newest.lastSnippet).font(.system(size: 13)).foregroundStyle(Color(hex: 0x3D3B38)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let placement {
                    let color = CourtColor.of(placement.court, model)
                    Button { model.accept(placement, for: matter.id) } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                            Text(title(placement)).lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(color.opacity(0.11), in: Capsule())
                        .overlay(Capsule().strokeBorder(color.opacity(0.33)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Put it there")
                    Text(placement.why).font(.system(size: 12)).foregroundStyle(Palette.faint).lineLimit(1)
                } else {
                    CourtMenu(matter: matter, title: "Choose court…").fixedSize()
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.looseSoft, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.loose, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        .contentShape(Rectangle())
        .onTapGesture { model.open(topic: matter.id) }
    }

    private func title(_ placement: AppModel.Placement) -> String {
        if let topic = placement.topic, let target = model.matter(topic) { return target.title }
        let court = model.space(placement.court)?.name ?? ""
        return placement.sub.map { "\(court) › \($0.name)" } ?? court
    }
}

// MARK: - The field

/// Your side of the net and theirs.
private struct FieldView: View {
    @Environment(AppModel.self) private var model
    let court: UUID?

    var body: some View {
        let topics = model.matters.filter { !$0.isFolded && (court == nil || $0.spaceID == court) }
        HStack(spacing: 0) {
            YourSide(topics: topics.filter { $0.ball == .mine })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Palette.meSoft)
            Net()
            TheirSide(topics: topics.filter { $0.ball == .theirs })
                .frame(minWidth: 300, idealWidth: 420, maxWidth: 440, maxHeight: .infinity, alignment: .topLeading)
                .background(Palette.themSoft)
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(hex: 0xD6D1C8), lineWidth: 1.5))
    }
}

/// The net between the two sides: two posts and the mesh.
private struct Net: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Palette.faint).frame(width: 12, height: 12)
            GeometryReader { geometry in
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
                }
                .stroke(Palette.faint.opacity(0.6), style: StrokeStyle(lineWidth: 5, dash: [2, 5]))
            }
            Circle().fill(Palette.faint).frame(width: 12, height: 12)
        }
        .padding(.vertical, 10)
        .frame(width: 40)
        .background(HStack(spacing: 0) { Palette.meSoft; Palette.themSoft })
    }
}

private struct YourSide: View {
    @Environment(AppModel.self) private var model
    let topics: [Matter]
    @State private var showAllLater = false
    @State private var showStale = false

    var body: some View {
        let sorted = topics.sorted { a, b in
            let da = model.dues[a.id] ?? .distantFuture, db = model.dues[b.id] ?? .distantFuture
            return da != db ? da < db : a.lastDate < b.lastDate
        }
        let week = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let urgent = sorted.filter { model.dues[$0.id].map { DueText.isHot($0) } ?? false }
        let thisWeek = sorted.filter { topic in model.dues[topic.id].map { !DueText.isHot($0) && $0 < week } ?? false }
        // Without a deadline the newest first; questions older than two months fold away (they are rarely still open).
        let undated = sorted.filter { model.dues[$0.id] == nil }.sorted { $0.lastDate > $1.lastDate }
        let later = sorted.filter { topic in model.dues[topic.id].map { $0 >= week } ?? false }
            + undated.filter { !Waiting.isStale($0.lastDate) }
        let stale = undated.filter { Waiting.isStale($0.lastDate) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BallGlyph(ball: .mine, width: 30)
                Text("Your side · \(topics.count)").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.meText)
                Text("by deadline, then the oldest first").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if topics.isEmpty {
                Text("No ball on your side. Nothing is asked of you.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            if !urgent.isEmpty {
                SectionTitle("Today and tomorrow · \(urgent.count)", color: Palette.meText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(urgent) { UrgentCard(matter: $0) }
                }
            }
            if !thisWeek.isEmpty { band("This week · \(thisWeek.count)", thisWeek, limit: nil) }
            if !later.isEmpty {
                band(later.contains { model.dues[$0.id] != nil } ? "Later or no deadline · \(later.count)" : "No deadline · \(later.count)",
                     later, limit: showAllLater ? nil : 6)
            }
            if !stale.isEmpty {
                if showStale {
                    band("Older than two months · \(stale.count)", stale, limit: nil)
                } else {
                    Button("\(stale.count) older than two months, probably settled ›") { showStale = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(16)
    }

    private func band(_ title: String, _ list: [Matter], limit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title, color: Color(hex: 0x8F5A45)).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(list.prefix(limit ?? list.count))) { matter in
                    MineRow(matter: matter)
                    if matter.id != list.prefix(limit ?? list.count).last?.id { Divider().overlay(Color(hex: 0xF6EEE9)) }
                }
                if let limit, list.count > limit {
                    Divider().overlay(Color(hex: 0xF6EEE9))
                    Button("+ \(list.count - limit) more") { showAllLater = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xEFE2DA)))
        }
    }
}

/// A topic due today or tomorrow: a card with where it lives, what is asked, and who.
private struct UrgentCard: View {
    @Environment(AppModel.self) private var model
    let matter: Matter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CourtLabel(court: matter.spaceID, sub: model.subCourt(of: matter), size: 11.5)
                Spacer(minLength: 4)
                if let due = model.dues[matter.id] { DueBadge(date: due) }
            }
            Text(matter.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
            if let ask = matter.ask {
                Text(ask).font(.system(size: 13)).foregroundStyle(Color(hex: 0x3D3B38)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                AvatarStack(people: matter.people(isMe: model.isMe), size: 22)
                Text(matter.conversations.count == 1 ? "1 conversation" : "\(matter.conversations.count) conversations")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                Spacer()
                if matter.unreadCount > 0 {
                    Text("\(matter.unreadCount) new").font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1).background(Palette.me, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.meLine))
        .shadow(color: Color(hex: 0x3C2814).opacity(0.06), radius: 1, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { model.open(topic: matter.id) }
    }
}

/// A topic on your side as one line: path, name, what is asked, deadline.
private struct MineRow: View {
    @Environment(AppModel.self) private var model
    let matter: Matter
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(matter.spaceID, model)).frame(width: 8, height: 8)
            Text(model.path(of: matter) ?? "No court").font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                .frame(width: 150, alignment: .leading)
            (Text(matter.title).fontWeight(matter.unreadCount > 0 ? .bold : .semibold)
             + Text(matter.ask.map { " · \($0)" } ?? "").foregroundColor(Palette.muted))
                .font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 6)
            if matter.unreadCount > 0 { Circle().fill(Palette.me).frame(width: 7, height: 7) }
            if let due = model.dues[matter.id] {
                Text(DueText.label(due)).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            } else {
                Text(DateText.short(matter.lastDate)).font(.system(size: 11.5)).foregroundStyle(Palette.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered ? Palette.meSoft.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.open(topic: matter.id) }
        .help(matter.ask ?? matter.title)
    }
}

private struct TheirSide: View {
    @Environment(AppModel.self) private var model
    let topics: [Matter]
    @State private var showAll = false
    @State private var showStale = false

    var body: some View {
        let sorted = topics.sorted { $0.lastDate < $1.lastDate }
        let long = sorted.filter { Waiting.isLong($0.lastDate) && !Waiting.isStale($0.lastDate) }
        let recent = sorted.filter { !Waiting.isLong($0.lastDate) }.reversed()
        let stale = sorted.filter { Waiting.isStale($0.lastDate) }.reversed()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BallGlyph(ball: .theirs, width: 30)
                Text("Their side · \(topics.count)").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.themText)
                Text("you wait").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if topics.isEmpty {
                Text("Nobody has a mail of yours to answer.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            if !long.isEmpty { band("Longer than a week · \(long.count)", long, limit: showAll ? nil : 5) }
            if !recent.isEmpty { band("Recent · \(recent.count)", Array(recent), limit: showAll ? nil : 5) }
            if !stale.isEmpty {
                if showStale {
                    band("Older than two months · \(stale.count)", Array(stale), limit: nil)
                } else {
                    Button("\(stale.count) older than two months, no answer came ›") { showStale = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(16)
    }

    private func band(_ title: String, _ list: [Matter], limit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title, color: Palette.themText).padding(.top, 2)
            VStack(spacing: 0) {
                ForEach(Array(list.prefix(limit ?? list.count))) { matter in
                    TheirRow(matter: matter)
                    Divider().overlay(Color(hex: 0xEEF2F8))
                }
                if let limit, list.count > limit {
                    Button("+ \(list.count - limit) more") { showAll = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.themLine))
        }
    }
}

private struct TheirRow: View {
    @Environment(AppModel.self) private var model
    let matter: Matter

    var body: some View {
        let long = Waiting.isLong(matter.lastDate)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(matter.spaceID, model)).frame(width: 8, height: 8)
                Text(matter.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Waiting.since(matter.lastDate)).font(.system(size: 11.5, weight: long ? .bold : .regular))
                    .foregroundStyle(long ? Color(hex: 0xA83A16) : Palette.muted)
            }
            Text([matter.waitingOn.map { $0.displayName }, model.path(of: matter)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1).padding(.leading, 16)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.open(topic: matter.id) }
    }
}

// MARK: - The bench

/// Quiet topics with something new, and the infos bundled in one chip; the rest is in Courts.
private struct BenchView: View {
    @Environment(AppModel.self) private var model
    let court: UUID?

    var body: some View {
        let infos = model.config.infosID
        let quiet = model.matters.filter { $0.ball == .quiet && (court == nil || $0.spaceID == court) }
        let news = quiet.filter { $0.unreadCount > 0 && $0.spaceID != infos && !$0.isFolded }
        let infoNews = quiet.filter { $0.unreadCount > 0 && ($0.spaceID == infos || $0.isFolded) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BallGlyph(ball: .quiet, width: 24)
                Text("Quiet · \(quiet.count) topics").font(.system(size: 13, weight: .bold))
                Text(news.isEmpty && infoNews.isEmpty ? "nothing new on the bench; all of it is in Courts"
                     : "here only the \(news.count + infoNews.count) with something new; the rest is in Courts")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            FlowLayout(spacing: 6) {
                ForEach(news.prefix(16)) { matter in
                    Button { model.open(topic: matter.id) } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(matter.spaceID, model)).frame(width: 8, height: 8)
                            Text(matter.title).fontWeight(.semibold).lineLimit(1)
                            if let blurb = matter.conversations.first?.lastSummary ?? matter.conversations.first?.lastTopic {
                                Text("· \(blurb)").foregroundStyle(Palette.muted).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                            }
                            Circle().fill(Palette.me).frame(width: 7, height: 7)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Palette.panel, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.line))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if !infoNews.isEmpty {
                    let count = infoNews.reduce(0) { $0 + $1.unreadCount }
                    Button {
                        model.feedQuery.space = infos
                        model.screen = .inbox
                    } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(infos, model)).frame(width: 8, height: 8)
                            Text("Infos · \(count) new from " + infoNews.prefix(6).map(\.title).joined(separator: ", ")
                                 + (infoNews.count > 6 ? " …" : "")).lineLimit(1)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: 0x4D4A46))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Palette.chip, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button("all in Courts ›") { model.screen = .courts(court) }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
    }
}

// MARK: - To do

/// The to-dos of all topics in a bar on the right: things to do outside mail, due first. Folds into a strip.
struct TodoBar: View {
    @Environment(AppModel.self) private var model
    @Binding var open: Bool

    var body: some View {
        let tasks = model.allTasks
        let dueSoon = tasks.filter { model.due(of: $0.task).map { DueText.isHot($0) } ?? false }.count
        if open {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("To do · \(tasks.count)").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Button { withAnimation(.snappy(duration: 0.2)) { open = false } } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                    }
                    .buttonStyle(.plain)
                    .help("Fold the to-dos away")
                }
                Text("what you do outside mail, from all topics").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .padding(.top, 2).padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if tasks.isEmpty {
                            Text("Nothing to do. Tasks come from mail (pay, sign, send) or from you.")
                                .font(.system(size: 12.5)).foregroundStyle(Palette.muted).padding(.top, 8)
                        }
                        ForEach(tasks, id: \.task.id) { item in
                            TodoItem(task: item.task, matter: item.matter)
                            Divider().overlay(Color(hex: 0xECE9E4))
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 330)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.bar)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
        } else {
            Button { withAnimation(.snappy(duration: 0.2)) { open = true } } label: {
                VStack(spacing: 12) {
                    Text("\(tasks.count)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(dueSoon > 0 ? Palette.hot : Palette.faint, in: Capsule())
                    Text(dueSoon > 0 ? "To do · \(dueSoon) due soon" : "To do")
                        .font(.system(size: 12.5, weight: .bold))
                        .fixedSize()
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: dueSoon > 0 ? 130 : 50)
                    Image(systemName: "chevron.left").foregroundStyle(Palette.muted)
                    Spacer()
                }
                .padding(.vertical, 16)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .background(Palette.bar)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
            .help("Show the to-dos")
        }
    }
}

/// One to-do: tick it off, see when it is due and where it comes from; a "done?" question when your mail sounds so.
private struct TodoItem: View {
    @Environment(AppModel.self) private var model
    let task: MailTask
    let matter: Matter
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button { model.completeTask(task) } label: {
                Image(systemName: hovered ? "checkmark.square" : "square").font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Done")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(task.label).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let due = model.due(of: task) { DueBadge(date: due) }
                }
                Button { model.open(topic: matter.id) } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(matter.spaceID, model)).frame(width: 7, height: 7)
                        Text([model.path(of: matter), matter.title].compactMap { $0 }.joined(separator: " › ")).lineLimit(1)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if task.doneSuggestedBy != nil {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Done? Your mail sounds like it.").font(.system(size: 12))
                        HStack(spacing: 6) {
                            Button("Yes") { model.completeTask(task) }.buttonStyle(OkButtonStyle(filled: true))
                            Button("Not yet") { model.rejectDoneSuggestion(task) }.buttonStyle(OkButtonStyle(filled: false))
                        }
                    }
                    .foregroundStyle(Palette.okText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.okSoft, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 9)
        .contextMenu {
            Button("Open \(matter.title)") { model.open(topic: matter.id) }
            if task.source == .model { Button("Not a Task") { model.dismissTask(task) } }
        }
    }
}

private struct OkButtonStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? Color.white : Palette.okText)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(filled ? Palette.ok : Palette.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filled ? Color.clear : Color(hex: 0xC9E2D6)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
