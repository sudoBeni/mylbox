import MylboxCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var showCc = false
    @State private var isSending = false
    @State private var error: String?
    @State private var importing = false
    @FocusState private var focus: Field?

    enum Field { case to, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.config.accounts.count > 1 {
                    field("From") {
                        Picker("", selection: $draft.accountID) {
                            ForEach(model.config.accounts) { account in
                                Text("\(account.name) <\(account.email)>").tag(Optional(account.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                field("To") {
                    TextField("", text: $draft.to, prompt: Text("name@example.com, …"))
                        .focused($focus, equals: .to)
                    if !showCc {
                        Button("Cc") { showCc = true }.buttonStyle(.borderless)
                    }
                }
                if showCc {
                    field("Cc") { TextField("", text: $draft.cc) }
                }
                field("Subject") {
                    TextField("", text: $draft.subject)
                        .focused($focus, equals: .subject)
                }
            }
            .textFieldStyle(.plain)

            TextEditor(text: $draft.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .focused($focus, equals: .body)

            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(draft.attachments, id: \.self) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(attachment.filename)
                                Button {
                                    draft.attachments.removeAll { $0 == attachment }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            Divider()
            HStack {
                Button { importing = true } label: { Label("Attach", systemImage: "paperclip") }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    send()
                } label: {
                    if isSending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending)
                .help("Send (⌘↩)")
            }
            .padding(12)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 480, idealHeight: 560)
        .onAppear {
            showCc = !draft.cc.isEmpty
            focus = draft.to.isEmpty ? .to : .body
        }
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

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            Divider()
        }
    }

    private func send() {
        isSending = true
        error = nil
        Task {
            do {
                try await model.send(draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }
}
