import RallyMailCore
import SwiftUI
import WebKit

/// The mail exactly as it arrived: full headers, HTML, quotes, signature. Opened from a bubble's "original".
struct OriginalMessageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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
                if !loadRemoteContent, MailSandbox.hasRemoteContent(html) {
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
                HTMLView(html: MailSandbox.page(for: html, inlineImages: inlineImages.mapValues { ($0.mimeType, $0.data) },
                                                allowRemote: loadRemoteContent))
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
            Divider()
            HStack {
                if message.bodyHTML != nil {
                    Toggle("Plain Text", isOn: $showPlainText).toggleStyle(.button).controlSize(.small)
                }
                Button("Forward…") { model.forward(message); dismiss() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 500, idealHeight: 640)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: message.id) { loadInlineImages() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 10) {
                Avatar(message.from, size: 36)
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
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let account = model.account(message.accountID) {
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
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { index, attachment in
                            Button {
                                AttachmentOpener.open(message, index: index) { model.banner = $0 }
                            } label: {
                                Label("\(attachment.filename)  \(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))",
                                      systemImage: "doc")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var recipients: String {
        var parts = ["To: " + message.to.map(\.formatted).joined(separator: ", ")]
        if !message.cc.isEmpty { parts.append("Cc: " + message.cc.map(\.formatted).joined(separator: ", ")) }
        return parts.joined(separator: "\n")
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
}

struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Belt and braces: JavaScript is off here, and the page's CSP forbids it as well.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: String?

        /// The mail view only ever shows the page we built. A clicked http(s) link goes to the browser;
        /// redirects, form posts, javascript:, file: and other schemes are dropped (see MailSandbox).
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            switch MailSandbox.navigation(to: action.request.url, userClickedLink: action.navigationType == .linkActivated) {
            case .allow:
                decisionHandler(.allow)
            case .openInBrowser(let url):
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .block:
                decisionHandler(.cancel)
            }
        }

        /// target="_blank" and window.open never create a window.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if case .openInBrowser(let url) = MailSandbox.navigation(to: navigationAction.request.url, userClickedLink: true) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        /// Mail cannot show dialogs.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    }
}
