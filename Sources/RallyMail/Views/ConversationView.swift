import RallyMailCore
import SwiftUI

// MARK: - Timeline

/// The messages of a topic, with system lines where the audience changed.
struct MessageTimeline: View {
    @Environment(AppModel.self) private var model
    let messages: [MailMessage]
    /// In a topic with several conversations, a divider marks where each one picks up.
    var showTopics = false
    /// A mail to scroll to and mark (opened from the Inbox or Rally).
    var focus: Int64? = nil
    let onOriginal: (MailMessage) -> Void
    /// Per message, what it changed in earlier messages. Worked out off the main thread, once per thread.
    @State private var edits: [Int64: [HistoryEdit]] = [:]
    /// When the timeline appeared: size changes right after (the reply box filling in) land it again.
    @State private var appeared = Date.distantPast

    /// The chat items (bubbles and notes) of the messages, built once per set of messages.
    private var items: [ChatItem] {
        TimelineCache.shared.items(for: messages) { messages in
            ChatTimeline.build(messages, isMe: { model.isMe($0) }, shortName: { model.shortName($0) })
        }
    }

    var body: some View {
        let items = items
        let sorted = messages.sorted { $0.date < $1.date }
        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: every bubble has its real height, so jumping to a mail lands exactly on it.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let message = item.message
                        let previous = index > 0 ? items[index - 1] : nil
                        let newDay = previous.map { !Calendar.current.isDate(date(of: $0), inSameDayAs: date(of: item)) } ?? true
                        let newTopic = showTopics && previous?.message.threadID != message.threadID
                        let firstOfMail = previous?.message.id != message.id
                        if newDay {
                            DayLine(date: date(of: item)).padding(.top, index == 0 ? 0 : 14)
                        }
                        if newTopic {
                            ThreadDivider(message: message).padding(.top, newDay ? 2 : 12)
                        } else if firstOfMail, let previous, let change = audienceChange(from: previous.message, to: message) {
                            SystemLine(text: change).padding(.top, 8)
                        }
                        if firstOfMail, message.folderRole == .inbox, !isAddressed(message) {
                            HiddenCopyNote().padding(.top, 8)
                        }
                        if firstOfMail, message.id == firstNew {
                            NewLine().padding(.top, 12)
                        }
                        switch item {
                        case .note(_, _, let text):
                            SystemLine(text: text).padding(.top, 8)
                        case .bubble(let bubble):
                            // Several messages in a row from the same person read as one block, like in a messenger.
                            let continues = previous.flatMap { item -> Bool? in
                                guard case .bubble(let before) = item else { return nil }
                                return before.author.address.lowercased() == bubble.author.address.lowercased()
                                    && bubble.date.timeIntervalSince(before.date) < 3600 && !newDay && !newTopic
                            } ?? false
                            MessageBubble(bubble: bubble,
                                          earlier: Array(sorted.prefix { $0.date < message.date || $0.id < message.id && $0.date == message.date }),
                                          edits: bubble.isForwarded ? [] : edits[message.id] ?? [],
                                          continues: continues && message.id != firstNew,
                                          onOriginal: { onOriginal(message) })
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, lineWidth: 2)
                                    .opacity(message.id == focus && bubble.showsAttachments ? 1 : 0))
                                .padding(.top, continues ? -3 : 4)
                                .id(bubble.showsAttachments ? "\(message.id)" : bubble.id)
                        }
                    }
                }
                .padding(16)
                Color.clear.frame(height: 1).id(Self.end)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Without a picked mail the timeline stays at its end while bubbles grow (changes, quotes, the reply box).
            .defaultScrollAnchor(focusInside ? nil : .bottom, for: .sizeChanges)
            .onAppear {
                appeared = Date()
                land(proxy, after: .milliseconds(60))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                if Date().timeIntervalSince(appeared) < 2 { land(proxy, after: .milliseconds(20)) }
            }
            .onChange(of: focus) { _, _ in land(proxy, after: .zero) }
            .onChange(of: items.map(\.id)) { _, _ in land(proxy, after: .milliseconds(30)) }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .task(id: messages.map(\.id)) {
                let messages = messages
                let found = await Task.detached(priority: .userInitiated) {
                    HistoryEdits.find(in: messages)
                }.value
                edits = Dictionary(uniqueKeysWithValues: zip(messages.map(\.id), found))
                // The changes make bubbles taller: land again once they are in.
                land(proxy, after: .milliseconds(30))
            }
        }
    }

    private static let end = "timeline-end"

    /// A picked mail that is not the newest: the timeline opens there instead of at its end.
    private var focusInside: Bool {
        guard let focus, focus != messages.last?.id else { return false }
        return messages.contains { $0.id == focus }
    }

    /// Opens at the picked mail, or at the bottom when it is the newest or none was picked.
    private func land(_ proxy: ScrollViewProxy, after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            if focusInside, let focus {
                proxy.scrollTo("\(focus)", anchor: .center)
            } else {
                proxy.scrollTo(Self.end, anchor: .bottom)
            }
        }
    }

    /// The first unread mail, to mark "New" above it.
    private var firstNew: Int64? {
        messages.sorted { $0.date < $1.date }.first { !$0.isRead && $0.folderRole == .inbox }?.id
    }

    /// When an item was written: the forwarded message's date for a forwarded bubble.
    private func date(of item: ChatItem) -> Date {
        if case .bubble(let bubble) = item { return bubble.date }
        return item.message.date
    }

    private func isAddressed(_ message: MailMessage) -> Bool {
        (message.to + message.cc).contains { model.isMe($0) }
    }

    /// "Reto added Lea (copy)" / "Reto left out Jonas"
    private func audienceChange(from previous: MailMessage, to message: MailMessage) -> String? {
        func room(_ m: MailMessage) -> [String: EmailAddress] {
            var result: [String: EmailAddress] = [:]
            for address in [m.from] + m.to + m.cc where !address.address.isEmpty { result[address.address.lowercased()] = address }
            return result
        }
        let before = room(previous), after = room(message)
        let senderKey = message.from.address.lowercased()
        let added = after.filter { before[$0.key] == nil && $0.key != senderKey }.values.filter { !model.isMe($0) }
        let removed = before.filter { after[$0.key] == nil }.values.filter { !model.isMe($0) }
        let joined = before[senderKey] == nil && !model.isMe(message.from)
        guard !added.isEmpty || !removed.isEmpty || joined else { return nil }
        let actor = model.isMe(message.from) ? "You" : model.shortName(message.from)
        var parts: [String] = []
        if joined { parts.append("joined") }
        if !added.isEmpty {
            parts.append("added " + added.map { address in
                let role = message.cc.contains(address) ? " (copy)" : ""
                return model.shortName(address) + role
            }.joined(separator: ", "))
        }
        if !removed.isEmpty { parts.append("left out " + removed.map(model.shortName).joined(separator: ", ")) }
        return "\(actor) \(parts.joined(separator: " and "))"
    }
}

/// "Today", "Yesterday", "Monday, 6 October" between the messages of different days.
struct DayLine: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

/// "New" above the first unread mail of a topic.
struct NewLine: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
            Text("NEW").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor).fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
        }
    }
}

/// Where another conversation of the topic picks up: its subject, as it came by mail.
struct ThreadDivider: View {
    let message: MailMessage

    var body: some View {
        let subject = Threading.normalizedSubject(message.subject)
        Label(subject.isEmpty ? "(no subject)" : subject, systemImage: "arrow.turn.down.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 36)
            .help("Another conversation in this topic")
    }
}

struct SystemLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

struct HiddenCopyNote: View {
    var body: some View {
        Label("You got this as a hidden copy. Replying would reveal that to the others.", systemImage: "eye.slash")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Chat items per set of messages, so the segmenter runs once per conversation, not once per redraw.
@MainActor
final class TimelineCache {
    static let shared = TimelineCache()
    private var key: [Int64] = []
    private var items: [ChatItem] = []

    func items(for messages: [MailMessage], build: ([MailMessage]) -> [ChatItem]) -> [ChatItem] {
        let ids = messages.map(\.id)
        if ids != key || messages.map(\.isRead) != items.map { $0.message.isRead }.prefix(ids.count).map { $0 } {
            key = ids
            items = build(messages)
        }
        return items
    }
}

/// One bubble: the text, attachments with versions, changes to earlier messages, and who got it. A forwarded
/// message shows under its author's name, "via" the person who passed it on.
struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let bubble: ChatBubble
    let earlier: [MailMessage]
    let edits: [HistoryEdit]
    /// Follows a message from the same person: no avatar, no name.
    var continues = false
    let onOriginal: () -> Void
    @State private var hovered = false
    @State private var showsRepeated = false

    private var message: MailMessage { bubble.message }
    private var isMe: Bool { model.isMe(bubble.author) }

    /// The text as written, signature included. Answers written into the quote already show up in the changes
    /// below, so they are left out then.
    private var source: String {
        if !edits.isEmpty { return message.segmented.own }
        return bubble.source
    }

    /// Their signature in their previous message here, to mark what changed.
    private func previousSignature(_ signature: SenderSignature) -> String {
        let address = bubble.author.address.lowercased()
        guard let previous = earlier.last(where: { $0.from.address.lowercased() == address }) else { return "" }
        return MessageFormatter.format(previous.bubbleSource, known: signature.known).text(of: .signature)
    }

    /// The badge is for people; newsletters and notifications would show address fragments.
    private var showsBadge: Bool {
        !isMe && !continues && !message.isBulk && message.category != .newsletters && message.category != .updates
    }

    var body: some View {
        let signature = SignatureBook.shared.signature(for: bubble.author, newest: bubble.date, store: model.store)
        let formatted = MessageFormatter.format(source, known: signature.known.union(message.segmented.signatureLines),
                                                template: signature.boilerplate)
        return HStack(alignment: .top, spacing: 8) {
            if isMe { Spacer(minLength: 40) } else if continues { Color.clear.frame(width: 28, height: 1) } else { Avatar(bubble.author, size: 28) }
            // Recipients beside the bubble, centred on it.
            HStack(alignment: .center, spacing: 10) {
                if isMe, !bubble.isForwarded { RecipientColumn(message: message) }
                VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        if formatted.blocks.contains(where: { $0.role != .deviceFooter }) {
                            MessageBodyView(formatted: formatted,
                                            previousSignature: formatted.text(of: .signature).isEmpty ? "" : previousSignature(signature))
                        }
                        if let repeated = bubble.repeated {
                            repeatedChip(repeated)
                        }
                        if bubble.showsAttachments, !message.attachments.isEmpty {
                            attachments
                        }
                        ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                            if earlier.indices.contains(edit.message) {
                                HistoryEditView(edit: edit, edited: earlier[edit.message])
                            }
                        }
                        if bubble.isEmpty, bubble.repeated == nil, message.attachments.isEmpty || !bubble.showsAttachments {
                            Text("(no text)").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(isMe ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                                in: UnevenRoundedRectangle(topLeadingRadius: isMe || continues ? 14 : 4, bottomLeadingRadius: 14,
                                                           bottomTrailingRadius: 14, topTrailingRadius: isMe && !continues ? 4 : 14))
                    meta(device: formatted.text(of: .deviceFooter), signature: signature)
                }
                .frame(maxWidth: 440, alignment: isMe ? .trailing : .leading)
                // The message gets the room first; the recipients take what is left.
                .layoutPriority(1)
                if !isMe, !bubble.isForwarded { RecipientColumn(message: message) }
            }
            if !isMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Show Original") { onOriginal() }
            Button("Forward…") { model.forward(message) }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
            }
        }
    }

    /// "Repeats Reto’s message from 14 Oct": text pasted below instead of quoted, one click away.
    private func repeatedChip(_ repeated: ChatBubble.Repeated) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showsRepeated.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("\(bubble.isEmpty ? "Same as" : "Repeats") \(model.isMe(repeated.author) ? "your" : model.shortName(repeated.author) + "’s") message from \(DateText.short(repeated.of.date))")
                    Image(systemName: showsRepeated ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("The mail contains this earlier message word for word")
            if showsRepeated {
                Text(BodyText.attributed(repeated.text))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { index, attachment in
                Button {
                    AttachmentOpener.open(message, index: index) { model.banner = $0 }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(attachment.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if let version = version(of: attachment) {
                                    Text(version).font(.system(size: 10, design: .monospaced))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .foregroundStyle(Color.accentColor)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Open \(attachment.filename)")
            }
        }
    }

    /// "v2 · replaces Tue 7 Oct" when the same file name came earlier in the thread with other content.
    private func version(of attachment: AttachmentInfo) -> String? {
        let name = attachment.filename.lowercased()
        let previousVersions = earlier.flatMap { message in message.attachments.filter { $0.filename.lowercased() == name }.map { (message.date, $0) } }
        guard let last = previousVersions.last else { return nil }
        guard last.1.size != attachment.size else { return nil }
        return "v\(previousVersions.count + 1) · replaces \(DateText.short(last.0))"
    }

    /// The text with links shown as their host ("galaxus.ch") and clickable.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString()
        for segment in LinkText.segments(text) {
            switch segment {
            case .text(let part):
                result += AttributedString(part)
            case .link(let url, let host):
                // "Label (https://…)" loses the space before the link; put one back.
                let gap = result.characters.last.map { $0.isWhitespace ? "" : " " } ?? ""
                var part = AttributedString(gap + host + "\u{00A0}↗")
                part.link = url
                part.foregroundColor = .accentColor
                result += part
            }
        }
        return result
    }

    /// The time, quietly, and a phone for "Sent from my iPhone". A forwarded message says via whom it came and
    /// when the forward was sent; a mail sent twice says so. The way to the original appears on hover.
    private func meta(device: String, signature: SenderSignature) -> some View {
        HStack(spacing: 6) {
            if !isMe && !continues {
                Text(model.shortName(bubble.author)).fontWeight(.medium)
            }
            if showsBadge, !signature.card.isEmpty {
                SenderBadge(signature: signature)
            }
            Text(bubble.date.formatted(date: .omitted, time: .shortened))
            if bubble.showsAttachments { AccountBadge(accountID: message.accountID, size: 13) }
            if let via = bubble.via {
                Label("via \(model.isMe(via) ? "you" : model.shortName(via)), \(DateText.short(message.date)) \(message.date.formatted(date: .omitted, time: .shortened))",
                      systemImage: "arrowshape.turn.up.right")
                    .help("Forwarded by \(via.formatted) on \(DateText.long(message.date)); the text above is from \(bubble.author.formatted)")
            }
            ForEach(bubble.sentAgain, id: \.id) { again in
                let others = (again.to + again.cc).filter { !model.isMe($0) && !(message.to + message.cc).contains($0) }
                Text("sent again \(again.date.formatted(date: .omitted, time: .shortened))"
                     + (others.isEmpty ? "" : " to " + others.map(model.shortName).joined(separator: ", ")))
                    .help("The same mail arrived twice; the second copy is folded in here")
            }
            if !device.isEmpty {
                Image(systemName: device.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                    .help(device)
            }
            if hovered {
                Button("original") { onOriginal() }
                    .buttonStyle(.plain)
                    .underline(true, pattern: .dot)
                    .help("Show the mail exactly as it arrived")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .frame(height: 14)
        // Name and time are never cut off; the line may run a little past a narrow bubble.
        .fixedSize(horizontal: true, vertical: false)
    }

}

/// What a reply changed in an earlier message: removed words struck through, added words highlighted.
struct HistoryEditView: View {
    @Environment(AppModel.self) private var model
    let edit: HistoryEdit
    let edited: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Changed \(model.isMe(edited.from) ? "your" : model.shortName(edited.from) + "’s") message from \(DateText.short(edited.date))",
                  systemImage: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(edit.passages.enumerated()), id: \.offset) { _, passage in
                Text(attributed(passage))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func attributed(_ passage: [HistoryEdit.Piece]) -> AttributedString {
        var result = AttributedString()
        for (index, piece) in passage.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            switch piece {
            case .same(let text):
                var part = AttributedString(text)
                part.foregroundColor = .secondary
                result += part
            case .removed(let text):
                var part = AttributedString(text)
                part.strikethroughStyle = .single
                part.foregroundColor = .secondary
                part.backgroundColor = .orange.opacity(0.18)
                result += part
            case .added(let text):
                var part = AttributedString(text)
                part.backgroundColor = .green.opacity(0.2)
                result += part
            }
        }
        return result
    }
}

enum AttachmentOpener {
    /// Writes the attachment to a temporary folder with a safe name, marks it as a downloaded mail attachment
    /// (Gatekeeper then checks it) and opens it. Files that could run code are only revealed in Finder.
    static func open(_ message: MailMessage, index: Int, onError: (String) -> Void) {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: message.rawPath)) else {
            onError("The original mail file is missing.")
            return
        }
        let attachments = MIME.parse(raw).attachments.filter { !$0.isInline }
        guard index < attachments.count else { return }
        let attachment = attachments[index]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RallyMail/\(message.stableKey)", isDirectory: true)
        let url = directory.appendingPathComponent(MailSandbox.safeFilename(attachment.filename))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: url, options: .atomic)
            try MailSandbox.quarantine(url)
        } catch {
            onError(error.localizedDescription)
            return
        }
        if MailSandbox.isRisky(filename: attachment.filename, mimeType: attachment.mimeType) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            onError("\(attachment.filename) could run code, so RallyMail only shows it in Finder. Open it there if you trust the sender.")
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - New mail

/// A new conversation: pick the people first, then write. Same composer as a reply.
struct NewMailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Text("New conversation").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.newDraft = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let binding = Binding($model.newDraft) {
                if model.config.accounts.count > 1 {
                    Picker("From", selection: binding.accountID) {
                        ForEach(model.config.accounts) { account in
                            Text("\(account.name) <\(account.email)>").tag(Optional(account.id))
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 10)
                }
                TextField("Subject", text: binding.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                Spacer()
                ComposerView(draft: binding, participants: [], focusToken: 0, startWithPeople: true) {
                    model.newDraft = nil
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
