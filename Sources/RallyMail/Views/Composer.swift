import RallyMailCore
import SwiftUI
import UniformTypeIdentifiers

/// The reply box: who gets it, in words and as chips, then the text.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: MailDraft
    /// People in the conversation, so the audience line can warn when one is left out.
    let participants: [EmailAddress]
    var focusToken = 0
    var startWithPeople = false
    var onSent: (() -> Void)?
    @State private var isSending = false
    @State private var error: String?
    @State private var importing = false
    @State private var adding = false
    @FocusState private var bodyFocused: Bool

    private var missing: [EmailAddress] {
        participants.filter { person in !draft.recipients.contains { $0.id == person.address.lowercased() } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudienceEditor(draft: $draft, missing: missing, adding: $adding)
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $draft.body)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 44, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(bodyFocused ? Color.accentColor : Color.primary.opacity(0.1)))
                    .focused($bodyFocused)
                    .overlay(alignment: .topLeading) {
                        if draft.body.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 10).allowsHitTesting(false)
                        }
                    }
                VStack(spacing: 6) {
                    Button { importing = true } label: { Image(systemName: "paperclip") }
                        .buttonStyle(.borderless)
                        .help("Attach a file")
                    Button(action: send) {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(sendTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isSending || draft.recipients.isEmpty)
                    .help("Send (⌘↩)")
                }
            }
            if !draft.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(draft.attachments, id: \.self) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: "doc")
                            Text(attachment.filename).lineLimit(1)
                            Button { draft.attachments.removeAll { $0 == attachment } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: focusToken) { _, _ in bodyFocused = true }
        .onAppear { if startWithPeople { adding = true } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
            }
        }
    }

    private var placeholder: String {
        if let first = draft.to.first { return "Reply to \(model.shortName(first))…" }
        return "Write…"
    }

    private var sendTitle: String {
        guard let first = draft.recipients.first(where: { $0.role != .bcc }) ?? draft.recipients.first else { return "Send" }
        let more = draft.recipients.count - 1
        return "Send to \(model.shortName(first.address))" + (more > 0 ? " +\(more)" : "")
    }

    private func send() {
        isSending = true
        error = nil
        let draft = draft
        Task {
            do {
                try await model.send(draft)
                self.draft.body = ""
                self.draft.attachments = []
                onSent?()
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }
}

/// "To Reto · copy to Lea" plus one chip per person; click the role to change it, × to remove, + to add.
struct AudienceEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: MailDraft
    let missing: [EmailAddress]
    @Binding var adding: Bool
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(audienceLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(draft.recipients) { recipient in
                    RecipientChip(recipient: recipient,
                                  name: model.shortName(recipient.address),
                                  cycle: { draft.cycleRole(recipient) },
                                  remove: { draft.remove(recipient) })
                }
                ForEach(Array(missing.enumerated()), id: \.offset) { _, person in
                    Button("+ \(model.shortName(person))") { draft.add(person, as: .cc) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                if adding {
                    AddressField(query: $query, focused: $queryFocused) { address in
                        draft.add(address, as: draft.recipients.isEmpty ? .to : .cc)
                        query = ""
                    } cancel: {
                        adding = false
                        query = ""
                    }
                } else {
                    Button("+ someone") { adding = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }
            if !missing.isEmpty {
                Text("\(missing.map(model.shortName).joined(separator: " and ")) \(missing.count > 1 ? "are" : "is") in this conversation but won't get this reply.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onChange(of: adding) { _, value in if value { queryFocused = true } }
    }

    private var audienceLine: AttributedString {
        var result = AttributedString(draft.audienceText(nameOf: model.shortName))
        if !draft.bcc.isEmpty, let range = result.range(of: "hidden copy") {
            result[range].foregroundColor = .orange
            result.append(AttributedString(" · only you see this"))
        }
        return result
    }
}

struct RecipientChip: View {
    let recipient: Recipient
    let name: String
    let cycle: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Avatar(recipient.address, size: 18)
            Text(name).font(.system(size: 12))
            Button(recipient.role.label, action: cycle)
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(recipient.role == .bcc ? .orange : .secondary)
                .background(recipient.role == .bcc ? Color.orange.opacity(0.15) : Color.primary.opacity(0.08), in: Capsule())
                .help("Click to change: To → Cc → Bcc")
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove")
        }
        .padding(.leading, 2).padding(.trailing, 7).padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(recipient.role == .bcc ? Color.orange : Color.primary.opacity(0.15),
                                        style: StrokeStyle(lineWidth: 1, dash: recipient.role == .bcc ? [3, 2] : [])))
        .help(recipient.address.formatted)
    }
}

/// Type a name or address; known people from past mail are suggested.
struct AddressField: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let add: (EmailAddress) -> Void
    let cancel: () -> Void

    private var suggestions: [EmailAddress] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        return (try? model.store.knownAddresses(matching: trimmed, limit: 6)) ?? []
    }

    var body: some View {
        TextField("name or address", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(width: 180)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .focused(focused)
            .onSubmit { commit() }
            .onKeyPress(.escape) { cancel(); return .handled }
            .popover(isPresented: Binding(get: { !suggestions.isEmpty && focused.wrappedValue }, set: { _ in }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.address) { address in
                        Button {
                            add(address)
                        } label: {
                            HStack(spacing: 8) {
                                Avatar(address, size: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(address.displayName).font(.system(size: 12))
                                    if !address.name.isEmpty { Text(address.address).font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .frame(width: 280)
            }
    }

    private func commit() {
        let text = query.trimmingCharacters(in: .whitespaces)
        if let first = suggestions.first, !text.contains("@") {
            add(first)
        } else if let parsed = MIME.parseAddressList(text).first, parsed.address.contains("@") {
            add(parsed)
        } else if text.isEmpty {
            cancel()
        }
    }
}

/// Wraps chips onto several lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
