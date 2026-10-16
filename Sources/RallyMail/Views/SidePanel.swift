import RallyMailCore
import SwiftUI

/// The right column: the picked mail read in its topic, what an open topic is about, or what is asked of you.
struct SidePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.screen == .sorting {
                SortingSide()
            } else if case .topic(let key) = model.screen, let matter = model.matter(key) {
                TopicInfo(matter: matter)
            } else if let selection = model.selection {
                ReadingPane(message: selection, context: model.selectionContext).id(selection.id)
            } else {
                VStack(spacing: 6) {
                    Text("No mail picked").font(.system(size: 14, weight: .semibold))
                    Text("Click a mail. You read it here in its topic and can sort it.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.bar)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
}

/// Section titles in the right column.
private struct SideLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
    }
}

/// The model's words: marked so they are never taken for the mail.
private struct AILine: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("AI").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2)))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

// MARK: - Reading pane

/// One mail in its topic: the mails before it, the mail in full, then quietly the model's summary, who is in
/// the topic, where it belongs and whether it is your turn.
struct ReadingPane: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    let context: [MailMessage]
    @State private var original: MailMessage?

    var body: some View {
        let matter = model.matter(of: message)
        let index = context.firstIndex { $0.id == message.id } ?? 0
        let start = max(0, index - 2)
        let shown = context.isEmpty ? [message] : Array(context[start...min(index, context.count - 1)])
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if let matter { BallGlyph(ball: matter.ball, width: 22) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(matter?.title ?? Threading.normalizedSubject(message.subject)).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 6) {
                            CourtLabel(court: matter?.spaceID)
                            if model.config.accounts.count > 1, let account = model.account(message.accountID) {
                                AccountBadge(accountID: message.accountID, size: 12)
                                Text(account.email).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    Button("Open") { model.open(topic: message.matterKey, at: message.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Open the whole topic as a chat")
                }
                VStack(alignment: .leading, spacing: 8) {
                    if start > 0 {
                        Button("\(start) earlier mail\(start == 1 ? "" : "s")…") { model.open(topic: message.matterKey, at: message.id) }
                            .buttonStyle(.link).font(.system(size: 11.5)).frame(maxWidth: .infinity)
                    }
                    let shownIDs = Set(shown.map(\.id))
                    let items = ChatTimeline.build(context.isEmpty ? [message] : context, isMe: { model.isMe($0) }, shortName: { model.shortName($0) })
                        .filter { shownIDs.contains($0.message.id) }
                    ForEach(items) { item in
                        switch item {
                        case .note(_, _, let text):
                            SystemLine(text: text)
                        case .bubble(let bubble):
                            MessageBubble(bubble: bubble, earlier: context.filter { $0.date < bubble.message.date }, edits: [],
                                          onOriginal: { original = bubble.message })
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2)
                                    .opacity(bubble.message.id == message.id && shown.count > 1 && bubble.showsAttachments ? 1 : 0))
                        }
                    }
                    if index < context.count - 1 {
                        Button("\(context.count - 1 - index) later mail\(context.count - 1 - index == 1 ? "" : "s")…") {
                            model.open(topic: message.matterKey, at: message.id)
                        }
                        .buttonStyle(.link).font(.system(size: 11.5)).frame(maxWidth: .infinity)
                    }
                }
                if let summary = message.summary { AILine(text: summary) }
                if let matter {
                    let people = matter.people(isMe: model.isMe)
                    if !people.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SideLabel(text: "In this topic")
                            HStack(spacing: 8) {
                                AvatarStack(people: people, size: 22, me: model.isMe)
                                Text(people.prefix(4).map(model.shortName).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Divider()
                    BelongsSection(message: message, matter: matter)
                }
                if message.folderRole == .inbox {
                    HStack(spacing: 8) {
                        Text("Your turn?").font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("Your turn?", selection: Binding(get: { message.needsReply }, set: { model.judge(message, mine: $0) })) {
                            Text("Yes").tag(true)
                            Text("No").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        if !message.isRead {
                            Button("Seen ✓") { model.markSeen([message]) }.controlSize(.small)
                        }
                    }
                    if message.ask != nil || message.summary != nil {
                        Text(message.needsReply ? "The AI thinks you are asked to do something. Your call decides." : "The AI thinks nothing is asked of you. Your call decides.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
        }
        .sheet(item: $original) { OriginalMessageView(message: $0) }
    }
}

/// Where a mail belongs, and how to change it: suggestions first, then any court or topic.
private struct BelongsSection: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    let matter: Matter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SideLabel(text: "Belongs to")
            if matter.spaceID == nil {
                if let suggestion = model.topicSuggestion(for: matter.id), let target = model.matter(suggestion.matter) {
                    Button { model.move(thread: message.threadID, toTopic: target.id) } label: {
                        Label("Add to \(target.title)", systemImage: "arrow.turn.down.right").lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    Text(MatterSuggestions.explain(suggestion)
                         + (model.suggestionVerdict(for: matter.id) == .same ? " The AI agrees." : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let court = model.courtSuggestions[matter.id], let space = model.space(court) {
                    Button { model.setCourt(matter.id, court) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(CourtColor.of(court, model)).frame(width: 8, height: 8)
                            Text("New topic in \(space.name)")
                        }
                    }
                    .buttonStyle(.bordered)
                    Text("Your topics with these people are there.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if model.topicSuggestion(for: matter.id) == nil && model.courtSuggestions[matter.id] == nil {
                    Text("No court yet, and no hint where it belongs.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Text(matter.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    CourtLabel(court: matter.spaceID)
                }
            }
            HStack(spacing: 8) {
                CourtMenu(matter: matter, title: "Court…")
                    .fixedSize()
                    .help("Puts the whole topic into a court or sub-court")
                Menu("Topic…") {
                    ForEach(model.config.spaces) { court in
                        let topics = model.matters(in: court.id).filter { $0.id != matter.id }
                        if !topics.isEmpty {
                            Menu(court.name) {
                                ForEach(topics.prefix(25)) { topic in
                                    Button(topic.title) { model.move(thread: message.threadID, toTopic: topic.id) }
                                }
                            }
                        }
                    }
                    if matter.conversations.count > 1 {
                        Divider()
                        Button("Own Topic") { model.newTopic(from: message.threadID, in: matter.spaceID) }
                    }
                }
                .help("Moves this conversation into another topic")
            }
            .fixedSize()
        }
    }
}

// MARK: - Topic info

/// What an open topic is about: where the ball is, the model's summary, who is in it, its files and conversations.
private struct TopicInfo: View {
    @Environment(AppModel.self) private var model
    let matter: Matter
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        let messages = model.topicMessages
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ballBox
                if let summary = messages.last(where: { $0.summary != nil && $0.folderRole == .inbox })?.summary {
                    VStack(alignment: .leading, spacing: 6) {
                        SideLabel(text: "Latest, in short")
                        AILine(text: summary)
                    }
                }
                people(messages)
                files(messages)
                VStack(alignment: .leading, spacing: 4) {
                    SideLabel(text: "Conversations · \(matter.conversations.count)")
                    ForEach(matter.conversations) { conversation in
                        HStack {
                            Text("„\(conversation.subject)“").lineLimit(1)
                            Spacer()
                            Text("\(conversation.messageCount)").foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .contextMenu {
                            if matter.conversations.count > 1 {
                                Button("Own Topic") { model.newTopic(from: conversation.id, in: matter.spaceID) }
                            }
                        }
                    }
                }
                related
                VStack(alignment: .leading, spacing: 6) {
                    SideLabel(text: "Court")
                    HStack(spacing: 8) {
                        CourtLabel(court: matter.spaceID, sub: model.subCourt(of: matter), size: 12)
                        CourtMenu(matter: matter, title: "Change…").fixedSize()
                    }
                }
                HStack {
                    Button("Rename…") { newTitle = matter.title; renaming = true }
                    Button("Quiet") { model.quiet(matter.id) }
                    Button("Later") { model.later(matter.id) }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
        .popover(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name of the topic").font(.headline)
                TextField("Name", text: $newTitle).frame(width: 260).onSubmit(rename)
                HStack { Spacer(); Button("Cancel") { renaming = false }; Button("Rename", action: rename).keyboardShortcut(.defaultAction) }
            }
            .padding(14)
        }
    }

    private func rename() {
        model.rename(topic: matter.id, to: newTitle)
        renaming = false
    }

    private var ballBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BallGlyph(ball: matter.ball, width: 30)
                Text(matter.ball == .mine ? "Your turn" : matter.ball == .theirs ? "Waiting" : "Quiet")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(matter.ball == .mine ? Color.orange : matter.ball == .theirs ? Color.blue : Color.secondary)
            }
            switch matter.ball {
            case .mine:
                // A question to answer, then the tasks; a reply finishes the first, only ticking off the others.
                if let ask = matter.ask, !matter.tasks.contains(where: { $0.label == ask }) { Text(ask).font(.system(size: 12.5)) }
                ForEach(matter.tasks) { TaskRow(task: $0) }
                if let person = matter.waitingOn {
                    Text("\(model.shortName(person)) has your reply.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Not right, I'm waiting") { model.giveBall(matter.id) }.buttonStyle(.link).font(.system(size: 11.5))
            case .theirs:
                Text("For \(matter.waitingOn.map(model.shortName) ?? "an answer") since \(DateText.short(matter.lastDate)).").font(.system(size: 12.5))
                Button("Not right, it's my turn") { model.takeBall(matter.id) }.buttonStyle(.link).font(.system(size: 11.5))
            case .quiet:
                Text("Nothing open.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button("It's my turn") { model.takeBall(matter.id) }.buttonStyle(.link).font(.system(size: 11.5))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((matter.ball == .mine ? Color.orange : matter.ball == .theirs ? Color.blue : Color.primary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Everyone in the topic but the user: who wrote, and who only got mail (To, Cc, and Bcc of the user's own mail).
    /// Other topics about the same theme at the same time: a pointer only, nothing is merged.
    @ViewBuilder private var related: some View {
        let others = model.relatedTopics.related(to: matter).compactMap(model.matter)
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SideLabel(text: "Related")
                ForEach(others) { other in
                    Button { model.open(topic: other.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(other.title).lineLimit(1)
                            Spacer()
                            Text(DateText.short(other.lastDate)).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Same theme around the same time · open")
                }
            }
        }
    }

    @ViewBuilder private func people(_ messages: [MailMessage]) -> some View {
        let involved = messages.reversed().flatMap { [$0.from] + $0.to + $0.cc + $0.bcc }
        var seen = Set<String>()
        let everyone = involved.filter { !model.isMe($0) && !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
        let mine = messages.filter { model.isMe($0.from) }.count
        VStack(alignment: .leading, spacing: 6) {
            SideLabel(text: "People · \(everyone.count)")
            ForEach(everyone, id: \.address) { person in
                let address = person.address.lowercased()
                let wrote = messages.filter { $0.from.address.lowercased() == address }
                let got = messages.filter { ($0.to + $0.cc + $0.bcc).contains { $0.address.lowercased() == address } }
                HStack(spacing: 8) {
                    Avatar(person, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(person.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(wrote.last.map { "last wrote \(DateText.short($0.date))" } ?? "got \(got.count) mail\(got.count == 1 ? "" : "s"), wrote none")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !wrote.isEmpty {
                        Text("\(wrote.count) mail\(wrote.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .help(person.formatted)
                .contextMenu {
                    Button("New Mail to \(person.displayName)") { model.newMail(to: [person]) }
                    Button("All Mail from \(person.displayName)") {
                        model.feedQuery.from = person.address.lowercased()
                        model.screen = .inbox
                    }
                }
            }
            if mine > 0 {
                Text("You wrote \(mine) mail\(mine == 1 ? "" : "s").").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func files(_ messages: [MailMessage]) -> some View {
        let withFiles = messages.filter { !$0.attachments.isEmpty }
        if !withFiles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SideLabel(text: "Files")
                ForEach(withFiles) { message in
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { index, file in
                        Button {
                            AttachmentOpener.open(message, index: index) { model.banner = $0 }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill").foregroundStyle(.orange)
                                Text(file.filename).lineLimit(1)
                                Spacer()
                                Text("\(model.shortName(message.from)), \(DateText.short(message.date))").foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .font(.system(size: 11.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Overview side

/// Next to the Overview: what is asked of you, across all courts, and why courts are worth it.
private struct OverviewSide: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let asked = model.matters.filter { $0.ball == .mine && !$0.isFolded }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SideLabel(text: "Asked of you · \(asked.count)")
                    if asked.isEmpty { Text("Nothing. You're through.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(asked) { matter in
                        TopicLine(matter: matter, showCourt: true, detail: matter.ask)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SideLabel(text: "Why courts")
                    Text("They make this map: which area needs you, at a glance. In the Inbox you filter by them, Rally sums up by topic. Ongoing conversations sort themselves; by hand you only sort what is new and unclear.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }
}
