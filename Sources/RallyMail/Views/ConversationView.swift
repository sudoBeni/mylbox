import RallyMailCore
import SwiftUI

/// A conversation as a chat: one bubble per message, only the new text, who got it under each bubble.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    @State private var draft = MailDraft()
    @State private var showSpacePicker = false
    @State private var original: MailMessage?
    @State private var replyFocusToken = 0

    private var messages: [MailMessage] { model.threadMessages }
    private var conversation: Conversation? { model.conversation(threadID) }
    private var others: [EmailAddress] {
        var seen = Set<String>()
        return messages.flatMap { [$0.from] + $0.to + $0.cc }
            .filter { !model.isMe($0) && !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            subheader
            Divider()
            MessageTimeline(messages: messages, onOriginal: { original = $0 })
            Divider()
            ComposerView(draft: $draft, participants: others, focusToken: replyFocusToken)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { draft = model.replyDraft(for: messages) }
        .onChange(of: messages.last?.id) { _, _ in
            // A new message in this thread changes who the reply goes to; keep typed text.
            let text = draft.body
            draft = model.replyDraft(for: messages)
            draft.body = text
        }
        .sheet(item: $original) { message in OriginalMessageView(message: message) }
        .onReceive(NotificationCenter.default.publisher(for: .focusReply)) { _ in replyFocusToken += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .openSpacePicker)) { _ in showSpacePicker = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarStack(people: others, size: 28, me: model.isMe)
            VStack(alignment: .leading, spacing: 1) {
                Text(others.isEmpty ? "Just you" : others.map(model.shortName).joined(separator: ", ") + " and you")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(others.map(\.formatted).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let conversation {
                if conversation.openCount > 0 {
                    Button("Done") { model.done(threadID) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    Button("Later") { model.later(threadID) }
                } else {
                    Button("Reopen") { model.reopen(threadID) }
                }
            }
            Button { model.openedThread = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subheader: some View {
        HStack(spacing: 8) {
            Text(conversation?.subject ?? Threading.normalizedSubject(messages.first?.subject ?? ""))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button {
                showSpacePicker.toggle()
            } label: {
                let space = model.space(conversation?.spaceID ?? messages.first?.spaceIDs.first)
                Chip(text: space?.name ?? "+ Space", symbol: space?.symbol, color: space == nil ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSpacePicker, arrowEdge: .bottom) {
                SpacePicker(threadID: threadID, currentSpace: conversation?.spaceID ?? messages.first?.spaceIDs.first,
                            sender: others.first) { showSpacePicker = false }
            }
            .help("Put this conversation into a space (P)")
            Spacer()
            Text("\(messages.count) message\(messages.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Puts a conversation into a space; optionally all future mail from the sender too.
struct SpacePicker: View {
    @Environment(AppModel.self) private var model
    let threadID: String
    let currentSpace: UUID?
    let sender: EmailAddress?
    let dismiss: () -> Void
    @State private var alsoSender = true
    @State private var editingSpace: Space?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This conversation belongs to").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4)
            ForEach(model.config.spaces) { space in
                Button {
                    model.setSpace(threadID, space: currentSpace == space.id ? nil : space.id,
                                   alsoSender: alsoSender && currentSpace != space.id ? sender : nil)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: currentSpace == space.id ? "checkmark" : space.symbol)
                            .frame(width: 16)
                            .foregroundStyle(currentSpace == space.id ? Color.accentColor : .secondary)
                        Text(space.name)
                        Spacer()
                        if space.exportFolder != nil {
                            Text("shared").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                editingSpace = Space(name: "")
            } label: {
                HStack { Image(systemName: "plus").frame(width: 16); Text("New space…") }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            if let sender {
                Divider()
                Toggle(isOn: $alsoSender) {
                    Text("Also put future mail from **\(sender.address)** here, so you don't sort it again.")
                        .font(.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .padding(6)
        .frame(width: 320)
        .sheet(item: $editingSpace) { SpaceEditor(space: $0) }
    }
}

// MARK: - Timeline

/// The messages of a thread, with system lines where the audience changed.
struct MessageTimeline: View {
    @Environment(AppModel.self) private var model
    let messages: [MailMessage]
    let onOriginal: (MailMessage) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index > 0, let change = audienceChange(from: messages[index - 1], to: message) {
                            SystemLine(text: change)
                        }
                        if message.folderRole == .inbox, !isAddressed(message) {
                            HiddenCopyNote()
                        }
                        MessageBubble(message: message,
                                      previous: index > 0 ? messages[index - 1] : nil,
                                      earlier: Array(messages[..<index]),
                                      onOriginal: { onOriginal(message) })
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
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

/// One message: the new text, attachments with versions, inline changes as a diff, and who got it.
struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    let previous: MailMessage?
    let earlier: [MailMessage]
    let onOriginal: () -> Void
    @State private var showDiff = false

    private var isMe: Bool { model.isMe(message.from) }
    private var fullText: String { QuoteStripper.plainBody(text: message.bodyText, html: message.bodyHTML.map(QuoteStripper.removeQuotedHTML)) }
    private var analysis: ReplyAnalysis? {
        guard let previous else { return nil }
        let previousText = QuoteStripper.plainBody(text: previous.bodyText, html: previous.bodyHTML)
        return ReplyAnalyzer.analyze(reply: fullText, previous: previousText)
    }
    private var stripped: StrippedBody { QuoteStripper.strip(fullText) }

    private var bubbleText: String {
        if let analysis {
            if !analysis.top.isEmpty { return analysis.top }
            if analysis.hasInlineChanges { return stripped.text.isEmpty ? "" : stripped.text }
        }
        let text = stripped.display
        return text.isEmpty ? fullText.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMe { Spacer(minLength: 40) } else { Avatar(message.from, size: 28) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    if !bubbleText.isEmpty {
                        Text(bubbleText)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !message.attachments.isEmpty {
                        attachments
                    }
                    if let analysis, analysis.hasInlineChanges {
                        InlineDiffView(analysis: analysis, open: $showDiff)
                            .onAppear { showDiff = analysis.top.isEmpty }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(isMe ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                            in: UnevenRoundedRectangle(topLeadingRadius: isMe ? 14 : 4, bottomLeadingRadius: 14,
                                                       bottomTrailingRadius: 14, topTrailingRadius: isMe ? 4 : 14))
                meta
            }
            .frame(maxWidth: 440, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .contextMenu {
            Button("Show Original") { onOriginal() }
            Button("Forward…") { model.forward(message) }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bubbleText, forType: .string)
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

    private var meta: some View {
        HStack(spacing: 6) {
            if !isMe {
                Text(model.shortName(message.from)).fontWeight(.medium)
            }
            HStack(spacing: 2) {
                Image(systemName: "arrow.right").font(.system(size: 8))
                ForEach(Array(message.to.prefix(6).enumerated()), id: \.offset) { _, address in
                    Avatar(address, size: 13, isMe: model.isMe(address))
                }
                if !message.cc.isEmpty {
                    Text("cc").padding(.leading, 3)
                    ForEach(Array(message.cc.prefix(6).enumerated()), id: \.offset) { _, address in
                        Avatar(address, size: 13, isMe: model.isMe(address))
                    }
                }
            }
            .help(recipientsHelp)
            Text(DateText.long(message.date))
            Button("original") { onOriginal() }
                .buttonStyle(.plain)
                .underline(true, pattern: .dot)
                .help("Show the mail exactly as it arrived")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private var recipientsHelp: String {
        var parts = ["To: " + message.to.map(\.formatted).joined(separator: ", ")]
        if !message.cc.isEmpty { parts.append("Cc: " + message.cc.map(\.formatted).joined(separator: ", ")) }
        return parts.joined(separator: "\n")
    }
}

/// Changes a reply made inside the quoted mail, like a diff: green added, orange removed, grey context.
struct InlineDiffView: View {
    let analysis: ReplyAnalysis
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("Replied inline in \(analysis.hunks.count) place\(analysis.hunks.count == 1 ? "" : "s")")
                    Text("+\(analysis.added)").foregroundStyle(.green)
                    Text("−\(analysis.removed)").foregroundStyle(.orange)
                    Spacer()
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(analysis.hunks.enumerated()), id: \.offset) { index, hunk in
                        if index > 0 {
                            Text("···").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).padding(.vertical, 2)
                        }
                        ForEach(Array(hunk.ops.enumerated()), id: \.offset) { _, op in
                            diffLine(op)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder private func diffLine(_ op: TextDiff.Op) -> some View {
        switch op {
        case .equal(let text):
            row(" ", text, .clear, .secondary, strike: false)
        case .insert(let text):
            row("+", text, Color.green.opacity(0.15), .primary, strike: false)
        case .delete(let text):
            row("−", text, Color.orange.opacity(0.15), .secondary, strike: true)
        }
    }

    private func row(_ marker: String, _ text: String, _ background: Color, _ color: Color, strike: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 10)
            Text(TextDiff.key(text).isEmpty ? " " : text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 12))
                .foregroundStyle(color)
                .strikethrough(strike)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(background)
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
