import Foundation

/// A message body cut into blocks with a role each, so a bubble reads like a chat: runs of blank lines become one
/// paragraph break, hard-wrapped lines flow again, lists get bullets, greeting and sign-off are quiet, and the
/// signature, a legal notice and "Sent from my iPhone" fold away behind a chip.
/// Nothing is rewritten or dropped: blocks differ from the source only in whitespace and invisible characters,
/// list markers are kept, and `MessageFormatter.content` checks exactly that.
public struct FormattedBody: Equatable, Sendable {
    public enum Role: String, Sendable, CaseIterable {
        case greeting, paragraph, list, table, signOff, signature, disclaimer, deviceFooter, template

        /// Not part of the running text: shown behind a chip or in the bubble's meta line.
        public var isFolded: Bool { self == .signature || self == .disclaimer || self == .deviceFooter || self == .template }
    }

    public struct ListItem: Equatable, Sendable {
        /// As written: "-", "*", "•", "1.", "2)".
        public var marker: String
        public var text: String
    }

    public struct Block: Equatable, Sendable {
        public var role: Role
        public var text: String
        public var items: [ListItem] = []
    }

    public var blocks: [Block]

    /// The blocks of the running text, in order.
    public var visible: [Block] { blocks.filter { !$0.role.isFolded } }

    /// All text with this role, e.g. the whole signature.
    public func text(of role: Role) -> String {
        blocks.filter { $0.role == role }.map(\.text).joined(separator: "\n\n")
    }
}

public enum MessageFormatter {
    struct Line {
        var text: String
        var indented: Bool
        var isBlank: Bool { text.isEmpty }
    }

    /// Zero-width spaces and joiners, word joiner, byte order mark, soft hyphen: invisible leftovers of HTML mails.
    static let invisibles: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static let greeting = regex(#"^(hallo|hello|hoi|hi|hey|liebe[rs]?|sehr geehrte[rs]?|geschätzte[rs]?|guten (tag|morgen|abend)|grüezi|grüessech|salü|sali|servus|moin|dear|good (morning|afternoon|evening)|bonjour|bonsoir|salut|ciao|buongiorno|car[ao]|hola)\b"#)
    static let signOff = regex(#"^((((liebe|viele|beste|herzliche|freundliche|sportliche|sonnige|schöne|frohe)|mit (freundlichen|besten|lieben|herzlichen|sportlichen)) )?(grüsse|grüße|gruss|gruß|grüessli|grüess|gruess)|en gruess|lg|mfg|vg|bg|hg|best|best regards|kind regards|warm regards|regards|cheers|thanks|thank you|many thanks|merci|danke|vielen dank|ciao|tschüss|bis bald|bis dann|salut|cordialement|bien à vous|saluti|cordiali saluti|a presto|un saluto|(met )?(vriendelijke|hartelijke) groet(en)?|groeten|with (kind|best|warm) regards|greüssli|liebi grüess)\b"#)
    static let delimiter = regex(#"^(--|_{2,})$"#)
    static let deviceFooter = regex(#"^((sent|gesendet|envoyé) (from|von|mit|de|depuis) .{1,60}|von meinem .{1,40} gesendet\.?|diese nachricht wurde von meinem .{1,60}|get outlook for .{1,60}|outlook für .{1,60} beziehen|envoyé de mon .{1,40}|inviato da .{1,40})$"#)
    static let disclaimer = regex(#"vertraulich|confidential|intended (only )?for|intended recipient|empfänger|privileged|disclaimer|haftung|liability|before printing|ausdrucken|umwelt|environment|virus|unauthori[sz]ed|legally|irrtümlich|in error|nicht für sie bestimmt"#)
    static let contactHint = regex(#"\+?\d[\d ()/.-]{7,}\d|https?://|www\.|@|\b\d{4,5} \p{L}"#)
    static let listItem = regex(#"^([-*•·–+]|\d{1,2}[.)])\s+(\S.*)$"#)

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The characters that carry content: everything except whitespace and invisible formatting characters.
    /// A formatted body must have exactly the content of its source.
    public static func content(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace && !invisibles.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    public static func content(_ body: FormattedBody) -> String {
        content(body.blocks.map { block in
            block.role == .list ? block.items.map { $0.marker + $0.text }.joined() : block.text
        }.joined())
    }

    static func lines(_ source: String) -> [Line] {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { raw in
                let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !invisibles.contains($0) }))
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                return Line(text: visible.trimmingCharacters(in: .whitespaces), indented: visible.first == " " || visible.first == "\t")
            }
    }

    /// `known`: lines this sender ends their mails with (`SenderSignature`), so a signature is found without "-- ".
    /// `template`: lines a service puts in every mail; runs of them at the top and bottom fold away.
    public static func format(_ source: String, known: Set<String> = [], template: Set<String> = []) -> FormattedBody {
        let lines = lines(source)
        var roles = classify(lines, known: known)
        if !template.isEmpty { markTemplate(lines, template: template, roles: &roles) }

        // Hard wrapping: several body lines end close to one width, the longest line, somewhere between 50 and 80.
        let bodyLengths = lines.indices.filter { roles[$0] == .paragraph && !lines[$0].isBlank }.map { lines[$0].text.count }
        let longest = bodyLengths.max() ?? 0
        let width = (50...80).contains(longest) && bodyLengths.filter({ $0 >= longest - 8 }).count >= 3 ? longest : nil

        var blocks: [FormattedBody.Block] = []
        var index = 0
        while index < lines.count {
            if lines[index].isBlank { index += 1; continue }
            let role = roles[index]
            if role == .paragraph {
                var paragraph: [Line] = []
                while index < lines.count, roles[index] == .paragraph, !lines[index].isBlank {
                    paragraph.append(lines[index])
                    index += 1
                }
                blocks += runs(paragraph, width: width)
                continue
            }
            // Other roles gather across blank lines, keeping one blank line where there were some.
            var texts: [String] = []
            var gap = false
            while index < lines.count {
                if lines[index].isBlank { gap = !texts.isEmpty; index += 1; continue }
                guard roles[index] == role else { break }
                if gap, role != .signOff { texts.append("") }
                texts.append(lines[index].text)
                gap = false
                index += 1
            }
            blocks.append(.init(role: role, text: texts.joined(separator: role == .signOff ? " " : "\n")))
        }
        return FormattedBody(blocks: blocks)
    }

    /// A role for every line, from the outside in: device footer and legal notice at the very end, then a
    /// signature after "-- ", then the sign-off with the name and what looks like contact details below it, then
    /// the greeting. Anything not clearly one of these stays running text, so in doubt you see more, not less.
    static func classify(_ lines: [Line], known: Set<String> = []) -> [FormattedBody.Role] {
        var roles = [FormattedBody.Role](repeating: .paragraph, count: lines.count)
        func lastText(before end: Int) -> Int? { (0..<end).last { !lines[$0].isBlank } }
        func paragraphStart(of index: Int) -> Int { ((0..<index).last { lines[$0].isBlank }).map { $0 + 1 } ?? 0 }
        func isDisclaimer(_ range: Range<Int>) -> Bool {
            let text = lines[range].map(\.text).joined(separator: " ")
            return text.count >= 50 && matches(disclaimer, text)
        }

        var end = lines.count
        while let last = lastText(before: end) {
            if matches(deviceFooter, lines[last].text) {
                roles[last] = .deviceFooter
                end = last
                continue
            }
            let start = paragraphStart(of: last)
            if lastText(before: start) != nil, isDisclaimer(start..<(last + 1)) {
                for index in start...last { roles[index] = .disclaimer }
                end = start
                continue
            }
            break
        }

        if let mark = (0..<end).last(where: { matches(delimiter, lines[$0].text) }), lastText(before: mark) != nil,
           lines[mark..<end].filter({ !$0.isBlank }).count <= 25 {
            var index = mark
            while index < end {
                if lines[index].isBlank { index += 1; continue }
                var stop = index
                while stop < end, !lines[stop].isBlank { stop += 1 }
                let notice = index > mark && isDisclaimer(index..<stop)
                for line in index..<stop {
                    roles[line] = notice ? .disclaimer : matches(deviceFooter, lines[line].text) ? .deviceFooter : .signature
                }
                index = stop
            }
            end = mark
        }

        // The sender's learned signature: the run of lines at the end that also end their other mails, plus new
        // contact lines inside it (a changed phone number). It starts with a known line. Sign-off and name stay out
        // of it, they belong to the text.
        var start = end
        var index = end - 1
        while index >= 0, !known.isEmpty, lines[index].isBlank || !isClosing(lines[index].text)
                && (known.contains(lines[index].text) || lines[index].text.count <= 60 && matches(contactHint, lines[index].text)) {
            if !lines[index].isBlank { start = index }
            index -= 1
        }
        while start < end, lines[start].isBlank || !known.contains(lines[start].text) { start += 1 }
        if let first = (start..<end).first(where: { !lines[$0].isBlank }), isNameLike(lines[first].text),
           let above = lastText(before: first), isClosing(lines[above].text) {
            start = ((first + 1)..<end).first { !lines[$0].isBlank } ?? end
        }
        let run = (start..<end).filter { !lines[$0].isBlank }
        // Only with contact details: a name that ends every mail ("Conny") stays in the text.
        if run.count <= 20, run.contains(where: { matches(contactHint, lines[$0].text) }), lastText(before: start) != nil {
            for line in run where roles[line] == .paragraph { roles[line] = .signature }
            end = start
        }

        var textEnd = end
        let candidates = (0..<end).filter { !lines[$0].isBlank }.suffix(10)
        for index in candidates.reversed() {
            guard lastText(before: index) != nil, let length = signOffLength(lines, at: index, end: end) else { continue }
            for line in index..<(index + length) { roles[line] = .signOff }
            let rest = ((index + length)..<end).filter { !lines[$0].isBlank }
            if !rest.isEmpty, isSignatureLike(rest.map { lines[$0].text }) {
                for line in rest { roles[line] = .signature }
            }
            textEnd = index
            break
        }

        if let first = (0..<textEnd).first(where: { !lines[$0].isBlank }),
           isGreeting(lines[first].text), ((first + 1)..<textEnd).contains(where: { !lines[$0].isBlank }) {
            roles[first] = .greeting
        }
        return roles
    }

    static func isClosing(_ text: String) -> Bool { text.count <= 40 && matches(signOff, text) }

    /// Runs of a service's fixed lines at the top and at the bottom of the text become `.template`. Only lines
    /// still counted as text: a signature stays a signature. The run must leave some text, else nothing folds.
    static func markTemplate(_ lines: [Line], template: Set<String>, roles: inout [FormattedBody.Role]) {
        let text = lines.indices.filter { !lines[$0].isBlank && roles[$0] != .deviceFooter && roles[$0] != .disclaimer && roles[$0] != .signature }
        var top: [Int] = []
        for index in text {
            guard template.contains(lines[index].text) else { break }
            top.append(index)
        }
        var bottom: [Int] = []
        for index in text.reversed() where !top.contains(index) {
            guard template.contains(lines[index].text) else { break }
            bottom.append(index)
        }
        guard top.count + bottom.count < text.count else { return }
        for index in top + bottom { roles[index] = .template }
    }

    /// "Liebe Grüsse" with the name on the next line, or a short closing line like "LG Beni" at the very end or
    /// right above a signature.
    static func signOffLength(_ lines: [Line], at index: Int, end: Int) -> Int? {
        let text = lines[index].text
        guard text.count <= 40, !text.hasSuffix("?"), matches(signOff, text) else { return nil }
        // The name, right below or after one blank line.
        if let name = ((index + 1)..<min(index + 3, end)).first(where: { !lines[$0].isBlank }), isNameLike(lines[name].text) {
            return name - index + 1
        }
        let rest = ((index + 1)..<end).map { lines[$0].text }.filter { !$0.isEmpty }
        return text.count <= 30 && (rest.isEmpty || isSignatureLike(rest)) ? 1 : nil
    }

    /// "Beni", "Reto Kaufmann", "Dein Team der Academy", but not "Leicht beschwipst ist gut".
    static func isNameLike(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 30, !text.contains("@"), !text.contains(where: \.isNumber) else { return false }
        guard let last = text.last, !".?:!,".contains(last) else { return false }
        let words = text.split(separator: " ")
        let particles: Set<String> = ["von", "van", "de", "der", "den", "und", "&", "+", "da", "di", "le", "la", "-"]
        return words.count <= 4 && words.allSatisfy { $0.first?.isUppercase == true || particles.contains($0.lowercased()) }
    }

    /// Lines below the sign-off that look like contact details rather than a P.S.
    static func isSignatureLike(_ lines: [String]) -> Bool {
        // Links make lines long ("www.x.ch<http://www.x.ch/>"), so those may be.
        guard lines.count <= 15, lines.allSatisfy({ $0.count <= 80 || $0.contains("http") }) else { return false }
        if lines.contains(where: { $0.lowercased().hasPrefix("ps") || $0.lowercased().hasPrefix("p.s") }) { return false }
        if lines.contains(where: { matches(contactHint, $0) }) { return true }
        // Without contact details only a team or company name: "Das CheersFeed-Team", not "Have a nice day,".
        return lines.count <= 3 && lines.allSatisfy(isNameLike)
    }

    /// "Hoi Beni", "Sehr geehrte Damen und Herren," but not "Hoi Beni, passt!", which already says something.
    static func isGreeting(_ text: String) -> Bool {
        guard text.count <= 60, matches(greeting, text) else { return false }
        var core = text
        while let last = core.last, ",!:.".contains(last) { core.removeLast() }
        return !core.contains(where: { ",.!?;:".contains($0) }) && core.split(separator: " ").count <= 6
    }

    /// One paragraph as text and list runs. Lines of a hard-wrapped paragraph join with a space; other line
    /// breaks stay, since the sender put them there.
    static let columnGap = regex(#"\S(\t| {2,})\S"#)
    static let cellGap = regex(#"\t+| {2,}"#)

    /// "Hallenmiete     4'800": short cells apart by tabs or several spaces. Not a list item with a tab after the bullet.
    static func isTableRow(_ line: Line) -> Bool {
        guard matches(columnGap, line.text), listItem(line.text) == nil else { return false }
        let cells = cellGap.stringByReplacingMatches(in: line.text, range: NSRange(line.text.startIndex..., in: line.text), withTemplate: "\u{0}")
            .split(separator: "\u{0}")
        return cells.count >= 2 && cells.allSatisfy { $0.count <= 30 }
    }

    static func runs(_ paragraph: [Line], width: Int?) -> [FormattedBody.Block] {
        // Columns lined up with spaces or tabs, in most lines: keep every line and space as it is. Not with links,
        // which a table would show long.
        let columns = paragraph.filter(isTableRow).count
        if columns >= 2, columns * 2 >= paragraph.count, !paragraph.contains(where: { $0.text.contains("http") }),
           let first = paragraph.firstIndex(where: isTableRow) {
            // "Stand jetzt:" above the table stays text.
            let table = FormattedBody.Block(role: .table, text: paragraph[first...].map(\.text).joined(separator: "\n"))
            return (first > 0 ? runs(Array(paragraph[..<first]), width: width) : []) + [table]
        }
        var blocks: [FormattedBody.Block] = []
        var text = ""
        var items: [FormattedBody.ListItem] = []
        var previous: String?
        // "22. Mai 2027" alone is a date, not a list: numbered items need a numbered neighbour.
        // Outlook writes a bullet on its own line with the item below: "*" then "Bei den Traktanden …".
        var parsed: [FormattedBody.ListItem?] = []
        var skip = false
        var merged: [Line] = []
        for (index, line) in paragraph.enumerated() {
            if skip { skip = false; continue }
            if ["*", "-", "•", "·", "–"].contains(line.text), index + 1 < paragraph.count, !paragraph[index + 1].isBlank,
               listItem(paragraph[index + 1].text) == nil {
                merged.append(Line(text: line.text + " " + paragraph[index + 1].text, indented: line.indented))
                parsed.append(FormattedBody.ListItem(marker: line.text, text: paragraph[index + 1].text))
                skip = true
            } else {
                merged.append(line)
                parsed.append(listItem(line.text))
            }
        }
        let paragraph = merged
        let isNumbered = parsed.map { $0?.marker.first?.isNumber == true }
        func item(at index: Int) -> FormattedBody.ListItem? {
            guard let item = parsed[index] else { return nil }
            let neighbour = (index > 0 && isNumbered[index - 1]) || (index + 1 < parsed.count && isNumbered[index + 1])
            return !isNumbered[index] || neighbour ? item : nil
        }
        func flush() {
            if !text.isEmpty { blocks.append(.init(role: .paragraph, text: text)) }
            if !items.isEmpty { blocks.append(.init(role: .list, text: "", items: items)) }
            text = ""
            items = []
        }
        for (index, line) in paragraph.enumerated() {
            if let item = item(at: index) {
                if !text.isEmpty { flush() }
                items.append(item)
            } else if !items.isEmpty, line.indented || previous.map({ joins($0, line.text, width: width) }) == true {
                items[items.count - 1].text += " " + line.text
            } else {
                if !items.isEmpty { flush() }
                if text.isEmpty {
                    text = line.text
                } else {
                    text += (previous.map { joins($0, line.text, width: width) } == true ? " " : "\n") + line.text
                }
            }
            previous = line.text
        }
        flush()
        return blocks
    }

    static func listItem(_ text: String) -> FormattedBody.ListItem? {
        let ns = text as NSString
        guard let match = listItem.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return .init(marker: ns.substring(with: match.range(at: 1)), text: ns.substring(with: match.range(at: 2)))
    }

    /// The line break after `line` was forced by the width: the next word would not have fit.
    static func joins(_ line: String, _ next: String, width: Int?) -> Bool {
        guard listItem(next) == nil else { return false }
        let firstWord = next.prefix { !$0.isWhitespace }.count
        if let width {
            return line.count >= width - 20 && line.count + 1 + firstWord > width
        }
        // Without a measured width (short mails): a long line whose next word would not have fit in the usual
        // 72 to 80 columns was wrapped by the program, not by the sender.
        return line.count >= 60 && line.count + 1 + firstWord > 78 && !line.hasSuffix(":")
    }
}
