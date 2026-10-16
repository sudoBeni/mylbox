import Foundation

/// One line of text read out of an HTML mail, with what the HTML said about where it sits.
public struct HTMLLine: Equatable, Sendable {
    public enum Region: Equatable, Sendable {
        /// The sender's own text.
        case text
        /// Inside a quoted or forwarded message (a blockquote, Gmail's quote div, Outlook's reply header and
        /// everything after it).
        case quote
        /// Inside an element the sender's program marked as the signature.
        case signature
    }

    public var text: String
    public var region: Region
}

/// Reads mail HTML into lines, the way a person sees it: paragraphs and line breaks become lines, list items
/// get their marker, table cells are set apart by tabs, links keep their address. Quoted messages and
/// signatures are marked by the elements mail programs wrap them in, which is far more reliable than
/// guessing from the text alone.
///
/// Foundation's tidy HTML parser (libxml2) copes with broken mail HTML. Nothing in the mail runs: this
/// only reads text.
public enum HTMLText {
    /// A cheap HTML → text conversion for snippets, search and exports.
    public static func plainText(_ html: String) -> String {
        lines(html).map(\.text).joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let blockElements: Set<String> = [
        "p", "div", "li", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre",
        "section", "article", "header", "footer", "address", "center", "dl", "dt", "dd", "form", "fieldset",
        "figure", "figcaption", "nav", "aside", "main", "hr", "body", "html", "tbody", "thead", "tfoot", "caption",
    ]
    static let paragraphElements: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "ul", "ol", "pre"]
    static let skippedElements: Set<String> = ["script", "style", "head", "title", "meta", "link", "noscript", "template", "o:p"]

    /// Classes and ids of elements that hold a whole quoted or forwarded message.
    static let quoteMarkers = ["gmail_quote", "mail-editor-reference-message-container", "moz-cite-prefix", "yahoo_quoted",
                               "protonmail_quote", "zmail_extra", "x_gmail_quote"]
    /// Elements after which the rest of the mail is the quoted message (Outlook's reply header and its variants).
    static let quoteFromHereMarkers = ["divrplyfwdmsg", "x_divrplyfwdmsg", "appendonsend", "outlookmessageheader", "x_outlookmessageheader",
                                       "mail-editor-reference-message-container"]
    static let signatureMarkers = ["signature", "gmail_signature", "composer_signature", "ms-outlook-mobile-signature", "x_signature",
                                   "moz-signature", "x_gmail_signature"]
    /// Outlook's reply header is a div with a thin top border, in every language.
    static let outlookHeaderStyle = try! NSRegularExpression(
        pattern: #"border-top:\s*(solid\s+)?(#e1e1e1|#b5c4df|rgb\(181,\s*196,\s*223\))|border-color:\s*rgb\(181,\s*196,\s*223\)"#,
        options: [.caseInsensitive])

    public static func lines(_ html: String) -> [HTMLLine] {
        guard let document = parse(html) else {
            return legacyLines(html)
        }
        var reader = Reader()
        reader.walk(document)
        reader.endLine()
        return reader.lines
    }

    static func parse(_ html: String) -> XMLDocument? {
        // The text was decoded already; a charset the mail declares would make the parser decode it again.
        var cleaned = html.replacingOccurrences(of: "<meta[^>]*charset[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: "<\\?xml[^>]*\\?>", with: "", options: [.regularExpression, .caseInsensitive])
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? XMLDocument(xmlString: cleaned, options: [.documentTidyHTML])
    }

    struct Reader {
        var lines: [HTMLLine] = []
        private var current = ""
        private var currentRegion: HTMLLine.Region = .text
        private var regionStack: [HTMLLine.Region] = []
        private var restIsQuote = false
        private var preDepth = 0
        private var listCounters: [Int?] = []
        private var cellInRow = false

        private var region: HTMLLine.Region {
            if restIsQuote { return .quote }
            return regionStack.last ?? .text
        }

        mutating func walk(_ node: XMLNode) {
            switch node.kind {
            case .text:
                append(node.stringValue ?? "")
            case .element:
                guard let element = node as? XMLElement else { return }
                visit(element)
            case .document:
                for child in node.children ?? [] { walk(child) }
            default:
                break
            }
        }

        private mutating func visit(_ element: XMLElement) {
            let name = (element.name ?? "").lowercased()
            if HTMLText.skippedElements.contains(name) { return }
            let classes = (element.attribute(forName: "class")?.stringValue ?? "").lowercased()
            let id = (element.attribute(forName: "id")?.stringValue ?? "").lowercased()
            let style = (element.attribute(forName: "style")?.stringValue ?? "").lowercased()
            let names = classes.split(separator: " ").map(String.init) + [id]
            if HTMLText.quoteFromHereMarkers.contains(where: { marker in names.contains(marker) }) {
                restIsQuote = true
            }
            if name == "div", HTMLText.outlookHeaderStyle.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)) != nil {
                restIsQuote = true
            }
            var pushed = false
            if name == "blockquote" || HTMLText.quoteMarkers.contains(where: { marker in names.contains(marker) }) {
                regionStack.append(.quote)
                pushed = true
            } else if region == .text, HTMLText.signatureMarkers.contains(where: { marker in names.contains(marker) }) {
                regionStack.append(.signature)
                pushed = true
            }
            defer { if pushed { regionStack.removeLast() } }

            let isBlock = HTMLText.blockElements.contains(name)
            if isBlock { flush() }
            switch name {
            case "br":
                endLine()
                return
            case "hr":
                flush()
                append("________________________________")
                flush()
                return
            case "img":
                return
            case "ul":
                listCounters.append(nil)
            case "ol":
                listCounters.append(1)
            case "li":
                if let last = listCounters.indices.last, let number = listCounters[last] {
                    append("\(number). ")
                    listCounters[last] = number + 1
                } else {
                    append("• ")
                }
            case "td", "th":
                if cellInRow, !current.isEmpty {
                    while current.hasSuffix(" ") { current.removeLast() }
                    current += "\t"
                }
                cellInRow = true
            case "tr":
                cellInRow = false
            case "pre":
                preDepth += 1
            default:
                break
            }
            for child in element.children ?? [] { walk(child) }
            switch name {
            case "ul", "ol": listCounters.removeLast()
            case "pre": preDepth -= 1
            case "tr": cellInRow = false
            case "a":
                if let href = element.attribute(forName: "href")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   href.lowercased().hasPrefix("http"), let text = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, !href.contains(text), !text.contains(href) {
                    append(" <\(href)>")
                }
            default: break
            }
            if isBlock { flush() }
            if HTMLText.paragraphElements.contains(name) { blankLine() }
        }

        /// Ends the line if something is on it; a block boundary alone makes no blank line.
        private mutating func flush() {
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { endLine() } else { current = "" }
        }

        /// A paragraph ends with a blank line, so the formatter sees a paragraph break.
        private mutating func blankLine() {
            if let last = lines.last, !last.text.isEmpty { lines.append(HTMLLine(text: "", region: last.region)) }
        }

        private mutating func append(_ text: String) {
            guard !text.isEmpty else { return }
            if preDepth > 0 {
                let parts = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
                for (index, part) in parts.enumerated() {
                    if index > 0 { endLine() }
                    current += part
                }
                return
            }
            let collapsed = text.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
            if current.isEmpty {
                currentRegion = region
                current = String(collapsed.drop { $0 == " " })
            } else if current.hasSuffix(" ") || current.hasSuffix("\t") {
                current += collapsed.drop { $0 == " " }
            } else {
                current += collapsed
            }
        }

        /// Ends the line, also when it is empty (a line break on its own is a blank line).
        mutating func endLine() {
            let text = current.trimmingCharacters(in: .whitespaces)
            current = ""
            // One blank line in a row is enough; several say nothing.
            if text.isEmpty {
                guard let last = lines.last, !last.text.isEmpty else { return }
                lines.append(HTMLLine(text: "", region: last.region))
                return
            }
            lines.append(HTMLLine(text: text, region: currentRegion))
        }
    }

    /// Without a parser (empty or hopeless input): tags stripped by regex.
    static func legacyLines(_ html: String) -> [HTMLLine] {
        var text = html
        for tag in ["style", "script", "head", "title"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/tr|/h[1-6]|/li|/table)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { HTMLLine(text: $0.trimmingCharacters(in: .whitespaces), region: .text) }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'",
                     "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
                     "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "euro": "€", "hellip": "…",
                     "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "zwnj": ""]
        var output = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let entity = String(after[..<semi])
                var replacement: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[entity]
                }
                if let replacement {
                    output += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            output += "&"
            rest = after
        }
        output += rest
        return output
    }
}
