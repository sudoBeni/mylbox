import Foundation

/// Everything that stands between mail content and the Mac.
///
/// A mail is hostile input. These rules make sure it can only ever be *looked at*:
/// no scripts, no automatic navigation, no remote loads without consent, no file that runs itself.
/// The policies are pure functions, so the tests feed real attack mails through them.
public enum MailSandbox {
    // MARK: HTML

    /// The content security policy under which mail HTML is shown. Scripts, frames, forms, fonts and
    /// media are blocked outright; images only from inline data unless the user asked for remote ones.
    public static func contentSecurityPolicy(allowRemote: Bool) -> String {
        let images = allowRemote ? "data: https: http:" : "data:"
        let styles = allowRemote ? "'unsafe-inline' https:" : "'unsafe-inline'"
        return "default-src 'none'; img-src \(images); style-src \(styles); font-src data:; "
            + "script-src 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
    }

    /// Does the HTML try to load anything from the network (images, backgrounds, CSS urls)?
    public static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(src|background|href)\s*=\s*["']?\s*(https?:|//)"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?\s*(https?:|//)"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"@import"#, options: [.caseInsensitive]) != nil
    }

    /// Strips what must never run or redirect, even though the web view already refuses it (defense in depth):
    /// scripts, event handlers, javascript: URLs, meta refresh, base, frames, objects, forms and imports.
    public static func sanitize(_ html: String) -> String {
        var text = html
        func drop(_ pattern: String) {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        drop(#"<script\b[^>]*>[\s\S]*?</script\s*>"#)
        drop(#"<script\b[^>]*/?>"#)
        drop(#"<(iframe|frame|frameset|object|embed|applet|base|link|meta|form|input|button|textarea|select|svg|math|template|noscript)\b[^>]*>"#)
        drop(#"</(iframe|frame|frameset|object|embed|applet|form|svg|math|template|noscript)\s*>"#)
        // on* event handlers, quoted or bare.
        drop(#"\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#)
        // javascript:, vbscript:, data:text/html and similar in any URL attribute.
        drop(#"\s+(href|src|action|formaction|xlink:href|poster|background)\s*=\s*("\s*(javascript|vbscript|data:text/html|data:application)[^"]*"|'\s*(javascript|vbscript|data:text/html|data:application)[^']*'|\s*(javascript|vbscript):[^\s>]*)"#)
        // CSS can also pull in remote content or (on old engines) run expressions.
        drop(#"@import[^;]*;"#)
        drop(#"expression\s*\([^)]*\)"#)
        return text
    }

    /// Wraps mail HTML into a page the view can show safely, replacing cid: images with inline data.
    public static func page(for html: String, inlineImages: [String: (mimeType: String, data: Data)], allowRemote: Bool) -> String {
        var body = sanitize(html)
        for (id, image) in inlineImages {
            body = body.replacingOccurrences(of: "cid:\(id)", with: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemote: allowRemote))">
        <meta name="referrer" content="no-referrer">
        <meta name="color-scheme" content="light">
        <style>
        body { font: 14px -apple-system, system-ui, sans-serif; margin: 20px 24px; color: #1d1d1f; background: #fff; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #555; }
        </style></head><body>\(body)</body></html>
        """
    }

    // MARK: Navigation

    public enum Navigation: Equatable, Sendable {
        /// The view may show this (only the page we built ourselves).
        case allow
        /// Hand the URL to the system browser; the mail view itself never leaves its page.
        case openInBrowser(URL)
        /// Nothing happens.
        case block
    }

    /// Decides what a navigation inside the mail view may do. Only the initial page load (about:blank)
    /// is shown; a clicked http(s) link goes to the browser; everything else, including meta refresh,
    /// form posts, javascript:, file: and custom schemes, is dropped.
    public static func navigation(to url: URL?, userClickedLink: Bool) -> Navigation {
        guard let url else { return .block }
        let scheme = url.scheme?.lowercased() ?? ""
        if userClickedLink {
            return scheme == "http" || scheme == "https" ? .openInBrowser(url) : .block
        }
        return scheme == "about" ? .allow : .block
    }

    // MARK: Attachments

    /// File types that can run code or scripts when opened. They are revealed in Finder instead of opened.
    public static let riskyExtensions: Set<String> = [
        "app", "action", "workflow", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "fish", "pkg", "mpkg", "dmg",
        "scpt", "scptd", "applescript", "osa", "jar", "js", "jse", "mjs", "vbs", "vbe", "wsf", "wsh", "ps1", "psm1", "bat", "cmd", "com",
        "exe", "msi", "scr", "pif", "reg", "hta", "py", "pyc", "rb", "pl", "php", "lua", "html", "htm", "xhtml", "shtml", "svg", "xml",
        "webloc", "inetloc", "url", "fileloc", "ftploc", "iso", "img", "prefpane", "qlgenerator", "saver", "service", "plugin",
        "bundle", "dylib", "so", "framework", "kext", "xpc", "mobileconfig", "configprofile", "webarchive", "lnk", "chm", "class",
    ]

    public static let riskyMIMETypes: Set<String> = [
        "application/x-sh", "application/x-shellscript", "application/x-csh", "application/javascript", "text/javascript",
        "application/x-apple-diskimage", "application/vnd.apple.installer+xml", "application/x-executable",
        "application/x-mach-binary", "application/x-msdownload", "application/x-msdos-program", "application/java-archive",
        "text/html", "application/xhtml+xml", "image/svg+xml", "application/x-apple-aspen-config",
    ]

    /// True when opening the file could run code. Double extensions ("Rechnung.pdf.app") count as the last one.
    public static func isRisky(filename: String, mimeType: String) -> Bool {
        let name = filename.lowercased().trimmingCharacters(in: .whitespaces)
        if riskyMIMETypes.contains(mimeType.lowercased().split(separator: ";").first.map(String.init) ?? "") { return true }
        guard let dot = name.lastIndex(of: ".") else { return false }
        return riskyExtensions.contains(String(name[name.index(after: dot)...]))
    }

    /// A file name that cannot escape its folder or hide: no path separators, no leading dot, no control characters.
    public static func safeFilename(_ name: String) -> String {
        var cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
        cleaned = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\u{202E}" && $0 != "\u{202D}" })
            .trimmingCharacters(in: .whitespaces)
        if cleaned == ".." || cleaned == "." { cleaned = "attachment" }
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "attachment\(cleaned)" : cleaned
    }

    /// Marks a file the way Safari marks downloads, so Gatekeeper checks it before it is opened.
    public static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "RallyMail",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        var target = url
        try target.setResourceValues(values)
    }
}
