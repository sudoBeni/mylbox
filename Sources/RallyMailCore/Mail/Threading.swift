import Foundation

/// Groups mails into conversations and turns reply chains into clean, chat-like text.
public enum Threading {
    static let replyPrefixes = ["re:", "aw:", "fwd:", "fw:", "wg:", "antw:", "tr:", "rif:", "sv:", "vs:", "ré:"]

    /// Tags mail gateways put in front: "[External]", "[EXT]", "EXTERN:", "*SPAM*", "[Ext.]".
    static let gatewayTag = try! NSRegularExpression(
        pattern: #"^(\[(external|extern|ext\.?|spam|suspicious|warning|caution|secure)\]|\*(external|extern|spam)\*|(external|extern|ext|spam):)\s*"#,
        options: [.caseInsensitive])

    /// The subject without gateway tags like "[External]".
    static func withoutTags(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        while let match = gatewayTag.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result), !range.isEmpty {
            result.removeSubrange(range)
        }
        return result
    }

    /// The subject without "Re:", "AW:", "Fwd:" and friends, and without gateway tags like "[External]".
    public static func normalizedSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            let untagged = withoutTags(result)
            if untagged != result { result = untagged; changed = true }
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
        normalizedSubject(subject) != withoutTags(subject)
    }

    static let forwardPrefixes = ["fwd:", "fw:", "wg:", "tr:", "rv:", "doorst:", "i:"]

    /// "Fwd:", "WG:", "TR:" as the outermost prefix: the mail passes another one on. "AW: WG: x" answers a forward.
    public static func isForwardSubject(_ subject: String) -> Bool {
        let result = withoutTags(subject).lowercased()
        return forwardPrefixes.contains(where: { result.hasPrefix($0) })
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

/// What `QuoteStripper.strip` returns; the cut is made by `MailSegmenter`.
public typealias StrippedBody = SegmentedBody

/// The old entry points, now thin wrappers around `MailSegmenter`.
public enum QuoteStripper {
    /// Splits a plain-text body into new text and quoted part.
    public static func strip(_ body: String) -> StrippedBody {
        MailSegmenter.segment(text: body, html: nil)
    }

    /// True for lines a mail client generates rather than a person writes: attributions, header fields, separators.
    public static func isGenerated(_ line: String) -> Bool { MailSegmenter.isGenerated(line) }

    /// Removes quoted blocks from HTML before it is turned into text; used to tell pictures of the quote apart.
    public static func removeQuotedHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<blockquote[^>]*>[\\s\\S]*?</blockquote>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<div[^>]*(class|id)=\"[^\"]*(gmail_quote|moz-cite-prefix|yahoo_quoted|OutlookMessageHeader|divRplyFwdMsg|appendonsend|mail-editor-reference-message-container)[^\"]*\"[\\s\\S]*$",
                                         with: "", options: [.regularExpression, .caseInsensitive])
        return text
    }

    /// The best plain text of a message, quotes included.
    public static func plainBody(text: String, html: String?) -> String {
        if let html, !html.isEmpty { return HTMLText.plainText(html) }
        return text
    }
}

public extension MailMessage {
    /// The mail cut into its parts. HTML first, the text part as fallback.
    var segmented: SegmentedBody {
        MailSegmenter.segment(text: bodyText, html: bodyHTML, subject: subject)
    }

    /// What the chat bubble shows: only what the sender newly wrote, without quotes, headers and signature.
    /// A plain forward shows what came along.
    var chatText: String {
        let body = segmented
        if !body.display.isEmpty { return body.display }
        if let forwarded = body.forwarded { return forwarded }
        // Nothing new on top, like an empty reply: show what came along, without its header.
        if let quoted = body.quotedBody { return quoted }
        return body.source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !MailSegmenter.isGenerated($0) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the bubble lays out with `MessageFormatter`: the sender's own text with signature and footer, which
    /// `chatText` drops. Inline answers come first when that is all they wrote above the quote.
    var bubbleSource: String {
        let body = segmented
        if !body.text.isEmpty { return body.own }
        if !body.inlineText.isEmpty { return body.inlineText + "\n\n" + body.own }
        return chatText
    }

    /// Everything the mail says as plain text, quotes included.
    var fullText: String { segmented.source }
}

// MARK: - Changes to earlier messages

/// A reply that changed the text of an earlier message inside its quote: "CHF 4'200" became "CHF 4'800".
public struct HistoryEdit: Equatable, Sendable {
    public enum Piece: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Index of the earlier message that was changed.
    public var message: Int
    /// The changed passages, each with a few words of context.
    public var passages: [[Piece]]
}

/// Finds replies that changed what someone wrote earlier, word by word. Rewrapped quotes, "> " markers, links and
/// the header lines mail clients add don't count; only words a person removed or added inside a quoted message do.
public enum HistoryEdits {
    struct Word: Equatable {
        var text: String
        var key: String
    }

    /// Links and image placeholders that mail clients add or drop when they quote: "<mailto:…>", "[image: Logo]",
    /// "[Fair Deal]", "<image001.png>", and the alt text Office writes for pictures.
    static let addedByClients = try! NSRegularExpression(
        pattern: #"<\s*(mailto:|https?://|tel:)[^>]*>|\[[^\]]{0,120}\]|<[^>\s]*\.(png|jpe?g|gif|bmp)>|(Ein Bild, das .{0,120}?enthält\.\s*Automatisch generierte Beschreibung|A picture containing .{0,120}?Description automatically generated)"#,
        options: [.caseInsensitive])
    /// "1." / "2)": list numbers differ between a mail and its quote (HTML lists lose them).
    static let listNumber = try! NSRegularExpression(pattern: #"^\d{1,2}[.)]$"#)

    /// Words of a text, skipping quote markers, generated header lines, links and image placeholders.
    /// Only letters and digits are compared, so "I’m"/"Im" or "kündigen.Falls"/"kündigen. Falls" are the same;
    /// the punctuation and emoji in between are kept for display only.
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var afterAttribution = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            var line = Substring(raw)
            while let first = line.first, first == ">" || first == " " || first == "\t" { line = line.dropFirst() }
            var plain = String(line).trimmingCharacters(in: .whitespaces)
            // The end of a wrapped attribution: "> um 09:12:" after "Am 7. Okt. 2026 schrieb Reto".
            if afterAttribution, plain.count < 40, plain.hasSuffix(":") { afterAttribution = false; continue }
            afterAttribution = false
            let attribution = plain.count < 300 && MailSegmenter.matches(MailSegmenter.attributionVerb, plain)
                && (plain.contains("@") || plain.contains(where: \.isNumber))
            if QuoteStripper.isGenerated(plain) || attribution {
                afterAttribution = attribution && !plain.hasSuffix(":")
                continue
            }
            plain = HTMLText.decodeEntities(plain)
            plain = addedByClients.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "")
            for token in plain.split(whereSeparator: \.isWhitespace) {
                let lower = token.lowercased()
                if listNumber.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil { continue }
                let bare = lower.drop { !$0.isLetter && !$0.isNumber }
                if ["http", "www.", "mailto:", "tel:"].contains(where: { bare.hasPrefix($0) }) { continue }
                let keys = lower.filter { !"'’‘ʼ`´".contains($0) }
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                    .filter { $0.count > 1 || $0.first?.isNumber == true }
                guard let first = keys.first else {
                    // Only punctuation or an emoji: shown with the word before, never compared.
                    if !result.isEmpty { result[result.count - 1].text += " " + token }
                    continue
                }
                result.append(Word(text: String(token), key: first))
                for key in keys.dropFirst() { result.append(Word(text: "", key: key)) }
            }
        }
        return result
    }

    enum Op: Equatable {
        case same(Word)
        case removed(Word)
        case added(Word)
    }

    /// Aligns all of an earlier text against the part of a quote where it sits (gaps only, the rest of the quote
    /// is free). Words the quoter cut off at the start or end don't count as removed. Nil when nothing matches.
    static func align(_ earlier: [Word], in quote: [Word]) -> [Op]? {
        let a = earlier, b = quote, n = a.count, m = b.count
        guard n > 0, m > 0 else { return nil }
        let width = m + 1
        var score = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 1...n {
            score[i * width] = -Int32(i)
            for j in 1...m {
                var value = max(score[(i - 1) * width + j], score[i * width + j - 1]) - 1
                if a[i - 1].key == b[j - 1].key { value = max(value, score[(i - 1) * width + j - 1] + 2) }
                score[i * width + j] = value
            }
        }
        var j = (1...m).max { score[n * width + $0] < score[n * width + $1] }!
        var i = n
        var ops: [Op] = []
        while i > 0 {
            let value = score[i * width + j]
            if j > 0, a[i - 1].key == b[j - 1].key, value == score[(i - 1) * width + j - 1] + 2 {
                ops.append(.same(b[j - 1])); i -= 1; j -= 1
            } else if j > 0, value == score[i * width + j - 1] - 1 {
                // Walking backwards, so taking "added" first puts removed words before added ones.
                ops.append(.added(b[j - 1])); j -= 1
            } else {
                ops.append(.removed(a[i - 1])); i -= 1
            }
        }
        ops.reverse()
        // Cut off by the quoter, not removed by them.
        while let first = ops.first, case .removed = first { ops.removeFirst() }
        while let last = ops.last, case .removed = last { ops.removeLast() }
        return ops.contains { if case .same = $0 { true } else { false } } ? ops : nil
    }

    /// For each message, the changes it made to what someone else wrote earlier. `texts` is what each message
    /// newly says, `fullTexts` the whole mail with its quotes, `senders` who sent it. A sender re-quoting their own
    /// mail is not an edit: that is mostly a template rendered twice.
    public static func find(texts: [String], fullTexts: [String], senders: [String]) -> [[HistoryEdit]] {
        let maxEarlierWords = 400, maxQuoteWords = 4000, lookBack = 8
        // Every version of each message seen so far: an edit becomes the new version, so it is shown only once.
        var versions: [[[Word]]] = texts.map { [Array(words($0).prefix(maxEarlierWords))] }
        var result: [[HistoryEdit]] = Array(repeating: [], count: texts.count)
        for index in texts.indices where index > 0 {
            guard let quoted = QuoteStripper.strip(fullTexts[index]).quoted else { continue }
            let quote = Array(words(quoted).prefix(maxQuoteWords))
            let quoteKeys = Set(quote.map(\.key))
            for earlier in max(0, index - lookBack)..<index where senders[earlier].lowercased() != senders[index].lowercased() {
                var bestOps: [Op]?
                var bestChanges = Int.max
                for version in versions[earlier] where version.count >= 4 {
                    // Cheap check first: most of the words must appear in the quote at all.
                    guard version.filter({ quoteKeys.contains($0.key) }).count * 2 >= version.count,
                          let ops = align(version, in: quote) else { continue }
                    let same = ops.filter { if case .same = $0 { true } else { false } }.count
                    let removed = ops.filter { if case .removed = $0 { true } else { false } }.count
                    let changes = ops.count - same
                    // A real quote of this message: most of it is there and it is not drowned in changes. People
                    // add a lot when they answer inline but rarely delete much; many deletions mean the quote was
                    // rendered differently (HTML receipts), not edited.
                    guard same >= 4, same * 5 >= version.count * 2, changes <= same,
                          removed <= max(3, same / 20) else { continue }
                    if changes < bestChanges { bestChanges = changes; bestOps = ops }
                }
                guard let ops = bestOps, bestChanges > 0 else { continue }
                result[index].append(HistoryEdit(message: earlier, passages: passages(ops)))
                versions[earlier].append(ops.compactMap { op in
                    switch op {
                    case .same(let word), .added(let word): word
                    case .removed: nil
                    }
                })
            }
        }
        return result
    }

    /// The changes in a conversation. Machine mail (receipts, notifications) is never treated as edited:
    /// quoting it mostly re-renders its HTML differently.
    public static func find(in messages: [MailMessage]) -> [[HistoryEdit]] {
        find(texts: messages.map { $0.isBulk ? "" : $0.chatText }, fullTexts: messages.map(\.fullText),
             senders: messages.map(\.from.address))
    }

    /// Groups the changes into passages with up to `context` unchanged words on each side.
    static func passages(_ ops: [Op], context: Int = 4) -> [[HistoryEdit.Piece]] {
        let changed = ops.indices.filter { if case .same = ops[$0] { false } else { true } }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(ops.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { range in
            var pieces: [HistoryEdit.Piece] = []
            if range.lowerBound > 0 { pieces.append(.same("…")) }
            for op in ops[range] {
                // Consecutive words of the same kind become one piece.
                switch (op, pieces.last) {
                case (.same(let w), .same(let t)?): pieces[pieces.count - 1] = .same(joined(t, w.text))
                case (.removed(let w), .removed(let t)?): pieces[pieces.count - 1] = .removed(joined(t, w.text))
                case (.added(let w), .added(let t)?): pieces[pieces.count - 1] = .added(joined(t, w.text))
                case (.same(let w), _): pieces.append(.same(w.text))
                case (.removed(let w), _): pieces.append(.removed(w.text))
                case (.added(let w), _): pieces.append(.added(w.text))
                }
            }
            if range.upperBound < ops.count - 1 { pieces.append(.same("…")) }
            return pieces.filter { piece in
                switch piece { case .same(let t), .removed(let t), .added(let t): !t.isEmpty }
            }
        }
    }

    static func joined(_ a: String, _ b: String) -> String {
        a.isEmpty || b.isEmpty ? a + b : a + " " + b
    }
}
