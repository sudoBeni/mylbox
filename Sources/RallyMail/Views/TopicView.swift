import RallyMailCore
import SwiftUI

/// One topic as a chat: all its conversations in one timeline, inside its court, with the reply at the bottom.
struct TopicView: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var draft = MailDraft()
    @State private var replyThread: String?
    @State private var original: MailMessage?
    @State private var replyFocusToken = 0

    private var messages: [MailMessage] { model.topicMessages }

    var body: some View {
        if let matter = model.matter(key) {
            let people = matter.people(isMe: model.isMe)
            VStack(spacing: 0) {
                TopicHeader(matter: matter)
                MessageTimeline(messages: messages, showTopics: matter.conversations.count > 1, focus: model.focusMessage,
                                onOriginal: { original = $0 })
                Rectangle().fill(Palette.line).frame(height: 1)
                if matter.conversations.count > 1 {
                    HStack(spacing: 6) {
                        Text("Reply in").foregroundStyle(Palette.muted)
                        Picker("Reply in", selection: Binding(get: { replyThread ?? defaultThread(matter) }, set: { replyThread = $0 })) {
                            ForEach(matter.conversations) { conversation in
                                Text("\(model.names(conversation.participants.filter { !model.isMe($0) })) · „\(conversation.subject)“")
                                    .tag(conversation.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                ComposerView(draft: $draft, participants: people, focusToken: replyFocusToken)
            }
            .background(Palette.panel)
            .onAppear { resetDraft(matter) }
            .onChange(of: replyThread) { _, _ in resetDraft(matter, keepText: true) }
            .onChange(of: messages.last?.id) { _, _ in resetDraft(matter, keepText: true) }
            .sheet(item: $original) { message in OriginalMessageView(message: message) }
            .onReceive(NotificationCenter.default.publisher(for: .focusReply)) { _ in replyFocusToken += 1 }
        } else {
            Text("This topic is gone.").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A reply continues the conversation the newest mail from someone else came in.
    private func defaultThread(_ matter: Matter) -> String {
        messages.last { !model.isMe($0.from) }?.threadID ?? messages.last?.threadID ?? matter.conversations[0].id
    }

    private func resetDraft(_ matter: Matter, keepText: Bool = false) {
        let thread = replyThread ?? defaultThread(matter)
        let text = draft.body
        let attachments = draft.attachments
        draft = model.replyDraft(for: messages.filter { $0.threadID == thread })
        if keepText {
            draft.body = text
            draft.attachments = attachments
        }
    }
}

/// The topic inside its court: the court's color band, the path, the title with where the ball is, and the other
/// open topics of the same sub-court as tabs.
private struct TopicHeader: View {
    @Environment(AppModel.self) private var model
    let matter: Matter

    var body: some View {
        let color = CourtColor.of(matter.spaceID, model)
        let sub = model.subCourt(of: matter)
        let siblings = model.matters(in: matter.spaceID).filter { model.subCourt(of: $0)?.id == sub?.id }
        let open = siblings.filter { $0.ball != .quiet || $0.id == matter.id || $0.unreadCount > 0 }
        let quiet = siblings.filter { !open.contains($0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let court = matter.spaceID, let space = model.space(court) {
                    Button(space.name) { model.screen = .courts(court) }.buttonStyle(.plain).fontWeight(.bold).foregroundStyle(color)
                    if let sub {
                        Text("›").foregroundStyle(Palette.faint)
                        Button(sub.name) { model.screen = .courts(court) }.buttonStyle(.plain).foregroundStyle(color)
                    }
                    Menu {
                        let subs = model.subCourts(of: court)
                        ForEach(subs) { other in Button(other.name) { model.setSubCourt(matter.id, other.id) } }
                        if sub != nil {
                            Divider()
                            Button("No Sub-Court") { model.setSubCourt(matter.id, nil) }
                        }
                        if subs.isEmpty { Text("This court has no sub-courts yet") }
                    } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Move to another sub-court")
                } else {
                    Text("No court yet").foregroundStyle(Palette.muted)
                    CourtMenu(matter: matter, title: "Choose court…").fixedSize()
                }
            }
            .font(.system(size: 12))
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(matter.title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Text("\(matter.messageCount) mail\(matter.messageCount == 1 ? "" : "s") · "
                         + (matter.conversations.count > 1 ? "\(matter.conversations.count) conversations · " : "")
                         + model.names(matter.people(isMe: model.isMe)))
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer()
                BallPill(ball: matter.ball)
                Button("Later") { model.later(matter.id) }.buttonStyle(SmallButtonStyle(filled: false)).help("Back tomorrow morning")
                if matter.ball != .quiet {
                    Button("Set Quiet") { model.quiet(matter.id) }.buttonStyle(SmallButtonStyle(filled: false))
                        .help("Nothing left to do: archives its mail; new mail wakes it up")
                }
            }
            if matter.spaceID != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(open) { other in
                            tab(other.title, unread: other.unreadCount > 0 && other.id != matter.id, on: other.id == matter.id) {
                                model.open(topic: other.id)
                            }
                        }
                        if !quiet.isEmpty {
                            Menu {
                                ForEach(quiet.prefix(40)) { other in Button(other.title) { model.open(topic: other.id) } }
                            } label: {
                                Text("\(quiet.count) quiet ▾").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(.horizontal, 10)
                        }
                        if let court = matter.spaceID {
                            tab("All in \(sub?.name ?? model.space(court)?.name ?? "court")", unread: false, on: false, muted: true) {
                                model.screen = .courts(court)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, matter.spaceID == nil ? 12 : 0)
        .background(matter.spaceID == nil ? Palette.bar : color.opacity(0.08))
        .overlay(alignment: .top) { if matter.spaceID != nil { Rectangle().fill(color).frame(height: 4) } }
        .overlay(alignment: .bottom) { Rectangle().fill(matter.spaceID == nil ? Palette.line : color.opacity(0.2)).frame(height: 1) }
    }

    private func tab(_ title: String, unread: Bool, on: Bool, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                if unread { Circle().fill(Palette.me).frame(width: 6, height: 6) }
            }
            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Palette.ink : muted ? Palette.muted : Color(hex: 0x4D4A46))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? Palette.panel : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 240)
    }
}

/// "Ball on your side" / "Ball on their side" / "Quiet".
struct BallPill: View {
    let ball: Ball

    var body: some View {
        HStack(spacing: 7) {
            BallGlyph(ball: ball, width: 22)
            Text(ball == .mine ? "Your side" : ball == .theirs ? "Their side" : "Quiet")
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(ball == .mine ? Color(hex: 0xA83A16) : ball == .theirs ? Palette.themText : Palette.muted)
        .padding(.horizontal, 11).padding(.vertical, 4)
        .background(ball == .mine ? Color(hex: 0xFDE6DC) : ball == .theirs ? Palette.themSoft : Palette.chip, in: Capsule())
    }
}

/// The court in small, left of an open topic: your side, the net, their side; one click to the next ball.
struct MiniField: View {
    @Environment(AppModel.self) private var model
    @State private var showAllTheirs = false

    var body: some View {
        let active: String? = { if case .topic(let key) = model.screen { return key }; return nil }()
        let mine = model.matters.filter { $0.ball == .mine && !$0.isFolded }.sorted { a, b in
            let da = model.dues[a.id] ?? .distantFuture, db = model.dues[b.id] ?? .distantFuture
            return da != db ? da < db : a.lastDate < b.lastDate
        }
        let theirs = model.matters.filter { $0.ball == .theirs && !Waiting.isStale($0.lastDate) }.sorted { $0.lastDate < $1.lastDate }
        let quiet = model.matters.filter { $0.ball == .quiet }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { model.screen = .play } label: {
                    Text("‹ Court").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your side · \(mine.count)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Palette.meText)
                        .padding(.horizontal, 6).padding(.bottom, 4)
                    if mine.isEmpty { Text("Nothing.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 7) }
                    ForEach(mine) { row($0, on: $0.id == active, due: model.dues[$0.id]) }
                }
                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 8)
                .background(Palette.meSoft, in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 400, y: 0)) }
                    .stroke(Palette.faint.opacity(0.5), style: StrokeStyle(lineWidth: 6, dash: [2, 4]))
                    .frame(height: 6)
                    .clipped()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Their side · \(theirs.count)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Palette.themText)
                        .padding(.horizontal, 6).padding(.bottom, 4)
                    if theirs.isEmpty { Text("Nobody.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 7) }
                    ForEach(showAllTheirs ? theirs : Array(theirs.prefix(4))) { matter in
                        row(matter, on: matter.id == active, since: Waiting.since(matter.lastDate), long: Waiting.isLong(matter.lastDate))
                    }
                    if theirs.count > 4 && !showAllTheirs {
                        Button("+ \(theirs.count - 4) more") { showAllTheirs = true }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 7).padding(.top, 2)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
                .background(Palette.themSoft, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                Text("Quiet · \(quiet) topics").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.top, 12)
            }
            .padding(10)
        }
        .background(Palette.side)
    }

    private func row(_ matter: Matter, on: Bool, due: Date? = nil, since: String? = nil, long: Bool = false) -> some View {
        Button { model.open(topic: matter.id) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(matter.spaceID, model)).frame(width: 8, height: 8)
                Text(matter.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if matter.unreadCount > 0 { Circle().fill(Palette.me).frame(width: 7, height: 7) }
                if let due, DueText.isHot(due) {
                    Text(DueText.label(due)).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.hot)
                }
                if let since { Text(since).font(.system(size: 10.5)).foregroundStyle(long ? Color(hex: 0xA83A16) : Palette.faint) }
            }
            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(on ? Palette.panel : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(matter.ask ?? matter.title)
    }
}
