import MylboxCore
import SwiftUI
import WebKit

struct MessageDetail: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    @State private var loadRemoteContent = false
    @State private var showPlainText = false
    @State private var inlineImages: [String: MailAttachment] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            if let html = message.bodyHTML, !showPlainText {
                if !loadRemoteContent, HTMLDocument.hasRemoteContent(html) {
                    HStack {
                        Image(systemName: "eye.slash")
                        Text("Remote images are blocked to protect your privacy.")
                        Spacer()
                        Button("Load Images") { loadRemoteContent = true }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5))
                }
                HTMLView(html: HTMLDocument.prepare(html, inlineImages: inlineImages, allowRemote: loadRemoteContent))
            } else {
                ScrollView {
                    Text(message.bodyText.isEmpty ? message.bodyHTML.map(HTMLText.plainText) ?? "" : message.bodyText)
                        .textSelection(.enabled)
                        .font(.body)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar { toolbar }
        .task(id: message.id) {
            model.opened(message)
            loadInlineImages()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: message.from.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message.from.displayName).font(.headline)
                        if !message.from.name.isEmpty {
                            Text(message.from.address).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    Text(recipients)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.config.accounts.count > 1, let account = model.account(message.accountID) {
                        Text(account.email).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if let summary = message.summary, !summary.isEmpty {
                Label(summary, systemImage: "sparkles")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 6) {
                if message.folderRole == .inbox {
                    Menu {
                        ForEach(MailCategory.allCases.filter { $0 != .spam }) { category in
                            Button(category.displayName) {
                                if message.category == .spam { model.notSpam([message]) }
                                model.setCategory([message], category)
                            }
                        }
                        Divider()
                        if message.category != .spam {
                            Button("Mark as Spam") { model.markSpam([message]) }
                        }
                    } label: {
                        Label((message.category ?? .primary).displayName, systemImage: (message.category ?? .primary).symbol)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                ForEach(model.config.spaces.filter { message.spaceIDs.contains($0.id) }) { space in
                    Chip(text: space.name, symbol: space.symbol, color: .accentColor)
                }
                SpaceMenu(messages: [message])
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Spacer()
                if message.bodyHTML != nil {
                    Toggle("Plain Text", isOn: $showPlainText)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
            .font(.callout)
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { index, attachment in
                            Button { open(attachmentAt: index) } label: {
                                Label("\(attachment.filename)  \(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))",
                                      systemImage: "doc")
                            }
                            .buttonStyle(.bordered)
                            .help("Open \(attachment.filename)")
                        }
                    }
                }
            }
        }
    }

    private var recipients: String {
        var parts = ["To: " + message.to.map(\.displayName).joined(separator: ", ")]
        if !message.cc.isEmpty { parts.append("Cc: " + message.cc.map(\.displayName).joined(separator: ", ")) }
        return parts.joined(separator: "   ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.reply(message, all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply (R)")
            Button { model.reply(message, all: true) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
            Button { model.forward(message) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward (F)")
            if message.isArchived {
                Button { model.unarchive([message]) } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
            } else if message.folderRole == .inbox {
                Button { model.archive([message]) } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive (E)")
            }
            Button { model.toggleFlag([message]) } label: {
                Label("Flag", systemImage: message.isFlagged ? "flag.fill" : "flag")
            }
            Button(role: .destructive) { model.delete([message]) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func loadInlineImages() {
        guard message.bodyHTML?.contains("cid:") == true,
              let raw = try? Data(contentsOf: URL(fileURLWithPath: message.rawPath)) else { return }
        var images: [String: MailAttachment] = [:]
        for attachment in MIME.parse(raw).attachments {
            if let id = attachment.contentID { images[id] = attachment }
        }
        inlineImages = images
    }

    private func open(attachmentAt index: Int) {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: message.rawPath)) else {
            model.banner = "The original mail file is missing."
            return
        }
        let attachments = MIME.parse(raw).attachments.filter { !$0.isInline }
        guard index < attachments.count else { return }
        let attachment = attachments[index]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mylbox/\(message.stableKey)", isDirectory: true)
        let url = directory.appendingPathComponent(attachment.filename.replacingOccurrences(of: "/", with: "_"))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            model.banner = error.localizedDescription
        }
    }
}

struct Avatar: View {
    let name: String

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hue = Double(name.unicodeScalars.reduce(0) { $0 + Int($1.value) * 7 } % 360) / 360
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.75), in: Circle())
    }
}

enum HTMLDocument {
    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(src|background)\s*=\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Wraps mail HTML with a strict content security policy (no scripts; remote images only on request)
    /// and replaces cid: references with inline data.
    static func prepare(_ html: String, inlineImages: [String: MailAttachment], allowRemote: Bool) -> String {
        var body = html
        for (id, image) in inlineImages {
            body = body.replacingOccurrences(of: "cid:\(id)",
                                             with: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())")
        }
        let images = allowRemote ? "data: https: http:" : "data:"
        let csp = "default-src 'none'; img-src \(images); style-src 'unsafe-inline' \(allowRemote ? "https:" : ""); font-src data:"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="color-scheme" content="light">
        <style>
        body { font: 14px -apple-system, system-ui, sans-serif; margin: 20px 24px; color: #1d1d1f; background: #fff; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #555; }
        </style></head><body>\(body)</body></html>
        """
    }
}

struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        /// Links open in the default browser, never inside the mail view.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(action.request.url?.scheme == "about" || action.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}
