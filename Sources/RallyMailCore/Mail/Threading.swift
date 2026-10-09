import Foundation

/// Groups mails into conversations and turns reply chains into clean, chat-like text.
public enum Threading {
    static let replyPrefixes = ["re:", "aw:", "fwd:", "fw:", "wg:", "antw:", "tr:", "rif:", "sv:", "vs:", "ré:"]

    /// The subject without "Re:", "AW:", "Fwd:" and friends.
    public static func normalizedSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in replyPrefixes where result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            // Counted prefixes like "Re[2]:" as well.
            let counted = result.replacingOccurrences(of: #"^(re|aw|fwd?|wg|antw|tr|rif|sv|vs)\[\d+\]:\s*"#, with: "",
                                                      options: [.regularExpression, .caseInsensitive])
            if counted != result { result = counted; changed = true }
        }
        return result
    }

    public static func isReplySubject(_ subject: String) -> Bool {
        normalizedSubject(subject) != subject.trimmingCharacters(in: .whitespaces)
    }

    /// Message ids named in the References and In-Reply-To headers, oldest first.
    public static func referencedIDs(references: String, inReplyTo: String) -> [String] {
        var ids = references.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        let parent = inReplyTo.trimmingCharacters(in: .whitespaces)
        if !parent.isEmpty, !ids.contains(parent) { ids.append(parent) }
        return ids.filter { $0.hasPrefix("<") && $0.hasSuffix(">") }
    }
}

// MARK: - Quotes and signatures

/// A mail body split into what the sender newly wrote and what they only quoted.
public struct StrippedBody: Equatable, Sendable {
    /// The text the sender wrote, without quotes and signature. Empty when they only answered inline.
    public var text: String
    /// Everything from the first quoted line on, if any.
    public var quoted: String?
    /// Lines the sender wrote inside the quoted part (inline answers), used when `text` is empty.
    public var inlineText: String

    /// What a chat bubble should show.
    public var display: String { text.isEmpty ? inlineText : text }
}

public enum QuoteStripper {
    static let quoteHeaders: [NSRegularExpression] = [
        #"^On .{4,200} wrote:\s*$"#,
        #"^Am .{4,200} schrieb .{0,120}:\s*$"#,
        #"^Am .{4,200}:\s*$"#,
        #"^Le .{4,200} a écrit\s*:\s*$"#,
        #"^Il .{4,200} ha scritto:\s*$"#,
        #"^El .{4,200} escribió:\s*$"#,
        #"^-{2,}\s*(Original Message|Ursprüngliche Nachricht|Message d'origine|Forwarded message|Weitergeleitete Nachricht|Messaggio originale)\s*-{2,}\s*$"#,
        #"^_{10,}\s*$"#,
        #"^\d{1,2}\.? ?[A-Za-zäöü]{3,9}\.? ?\d{4}.{0,40}<.+@.+>:\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static let headerBlockStart = try! NSRegularExpression(pattern: #"^(From|Von|De|Da)\s*:\s*\S"#, options: [.caseInsensitive])
    static let headerBlockFollow = try! NSRegularExpression(pattern: #"^(Sent|Gesendet|Date|Datum|Envoyé|Inviato|To|An|À|A)\s*:\s*\S"#,
                                                            options: [.caseInsensitive])
    static let signatureLines = try! NSRegularExpression(
        pattern: #"^(--\s?|__+|(Sent|Gesendet) (from|von|mit) (my|meinem|meiner) .{1,40}|Von meinem .{1,30} gesendet\.?|Diese Nachricht wurde von meinem .{1,40}|Get Outlook for .{1,20}|Outlook für .{1,20} beziehen)$"#,
        options: [.caseInsensitive])

    static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Splits a plain-text body into new text and quoted part.
    public static func strip(_ body: String) -> StrippedBody {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var cut = lines.count
        for (index, line) in lines.enumerated() {
            if line.hasPrefix(">") { cut = index; break }
            if quoteHeaders.contains(where: { matches($0, line) }) { cut = index; break }
            // "On <date>" / "Am <date>" headers that wrap onto a second line.
            if (line.hasPrefix("On ") || line.hasPrefix("Am ")) && line.count < 120, index + 1 < lines.count,
               lines[index + 1].hasSuffix("wrote:") || lines[index + 1].hasSuffix(":") && lines[index + 1].contains("schrieb") {
                cut = index; break
            }
            // Outlook-style "From: … Sent: …" blocks.
            if matches(headerBlockStart, line), lines[(index + 1)..<min(index + 4, lines.count)].contains(where: { matches(headerBlockFollow, $0) }) {
                cut = index; break
            }
        }
        var own = Array(lines[..<cut])
        let rest = Array(lines[cut...])
        // Signatures only count in the sender's own part.
        if let signature = own.firstIndex(where: { matches(signatureLines, $0) }) {
            own = Array(own[..<signature])
        }
        let text = own.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = rest.isEmpty ? nil : rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Inline answers: lines inside the quoted part that are not quoted themselves and not headers.
        var inline: [String] = []
        if !rest.isEmpty {
            var sawQuote = false
            for line in rest {
                if line.hasPrefix(">") { sawQuote = true; continue }
                if line.isEmpty || quoteHeaders.contains(where: { matches($0, line) }) || matches(headerBlockStart, line)
                    || matches(headerBlockFollow, line) || matches(signatureLines, line) { continue }
                if sawQuote { inline.append(line) }
            }
        }
        return StrippedBody(text: text, quoted: quoted.flatMap { $0.isEmpty ? nil : $0 }, inlineText: inline.joined(separator: "\n"))
    }

    /// Removes quoted blocks from HTML before it is turned into text, so HTML-only mails strip as well.
    public static func removeQuotedHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<blockquote[^>]*>[\\s\\S]*?</blockquote>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<div[^>]*class=\"[^\"]*(gmail_quote|moz-cite-prefix|yahoo_quoted|OutlookMessageHeader|divRplyFwdMsg)[^\"]*\"[\\s\\S]*$",
                                         with: "", options: [.regularExpression, .caseInsensitive])
        return text
    }

    /// The best plain text of a message for the conversation view.
    public static func plainBody(text: String, html: String?) -> String {
        if !text.isEmpty { return text }
        return html.map(HTMLText.plainText) ?? ""
    }
}

// MARK: - Line diff

/// A line-based diff, used to show what a reply changed inside the quoted mail.
public enum TextDiff {
    public enum Op: Equatable, Sendable {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    /// Normalizes a line for comparison: quote markers, whitespace and case don't count.
    public static func key(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == ">" || first == " " { text = text.dropFirst() }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func diff(_ old: [String], _ new: [String], maxLines: Int = 400) -> [Op] {
        let a = Array(old.prefix(maxLines)), b = Array(new.prefix(maxLines))
        let ka = a.map(key), kb = b.map(key)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = ka[i] == kb[j] && !ka[i].isEmpty ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if ka[i] == kb[j], !ka[i].isEmpty {
                ops.append(.equal(b[j])); i += 1; j += 1
            } else if ka[i].isEmpty, kb[j].isEmpty {
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                if !ka[i].isEmpty { ops.append(.delete(a[i])) }
                i += 1
            } else {
                if !kb[j].isEmpty { ops.append(.insert(b[j])) }
                j += 1
            }
        }
        while i < a.count { if !ka[i].isEmpty { ops.append(.delete(a[i])) }; i += 1 }
        while j < b.count { if !kb[j].isEmpty { ops.append(.insert(b[j])) }; j += 1 }
        return ops
    }
}

/// How a reply relates to the message it answers: new text on top, and changes inside the quote.
public struct ReplyAnalysis: Equatable, Sendable {
    public struct Hunk: Equatable, Sendable {
        public var ops: [TextDiff.Op]
    }

    /// Text the sender wrote above the quote.
    public var top: String
    /// Changes inside the quoted part, each with a little context.
    public var hunks: [Hunk]
    public var added: Int
    public var removed: Int

    public var hasInlineChanges: Bool { !hunks.isEmpty }
}

public enum ReplyAnalyzer {
    /// Compares a reply with the message it answers. Returns nil when the reply does not quote it.
    public static func analyze(reply: String, previous: String) -> ReplyAnalysis? {
        let replyLines = reply.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let previousBody = QuoteStripper.strip(previous)
        let previousLines = (previousBody.text + "\n" + (previousBody.quoted ?? "")).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ops = TextDiff.diff(previousLines, replyLines)
        guard let firstEqual = ops.firstIndex(where: { if case .equal = $0 { return true } else { return false } }) else { return nil }
        let equalCount = ops.filter { if case .equal = $0 { return true } else { return false } }.count
        // Two matching lines can be coincidence ("Hallo", "Gruss"); a real quote matches more.
        guard equalCount >= 2 else { return nil }

        var topLines: [String] = []
        for op in ops[..<firstEqual] { if case .insert(let line) = op { topLines.append(line) } }
        // The quote header ("On … wrote:") belongs to the quote, not to the new text.
        topLines = topLines.filter { line in !QuoteStripper.quoteHeaders.contains { QuoteStripper.matches($0, line) } }
        if let signature = topLines.firstIndex(where: { QuoteStripper.matches(QuoteStripper.signatureLines, $0) }) {
            topLines = Array(topLines[..<signature])
        }

        // Trailing deletes are the quoter trimming the old mail, not a change worth showing.
        var body = Array(ops[firstEqual...])
        while let last = body.last, case .delete = last { body.removeLast() }
        // Deleted lines that are signatures or quote headers are noise as well.
        body = body.filter { op in
            if case .delete(let line) = op {
                return !QuoteStripper.matches(QuoteStripper.signatureLines, line)
                    && !QuoteStripper.quoteHeaders.contains { QuoteStripper.matches($0, line) }
            }
            return true
        }

        var hunks: [ReplyAnalysis.Hunk] = []
        var added = 0, removed = 0
        var index = 0
        while index < body.count {
            guard case .equal = body[index] else {
                // Start of a change: collect it with one line of context before and after.
                let start = max(0, index - 1)
                var end = index
                while end < body.count, { if case .equal = body[end] { return false } else { return true } }() {
                    if case .insert = body[end] { added += 1 } else { removed += 1 }
                    end += 1
                }
                let stop = min(body.count, end + 1)
                hunks.append(ReplyAnalysis.Hunk(ops: Array(body[start..<stop])))
                index = end
                continue
            }
            index += 1
        }
        return ReplyAnalysis(top: topLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                             hunks: hunks, added: added, removed: removed)
    }
}
