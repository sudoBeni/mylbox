import Foundation

/// The header a mail program writes above a quoted or forwarded message ("Von: … Gesendet: … Betreff: …",
/// "Am 7. Okt. schrieb Reto <kasse@vbc.ch>:"), read into fields. It says who wrote the quoted text and when.
public struct QuoteHeader: Equatable, Sendable {
    /// A forwarded message rather than the mail being answered.
    public var isForward = false
    public var from: EmailAddress?
    public var date: Date?
    /// The date as written, when it could not be read.
    public var dateText = ""
    public var subject = ""
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    /// The header lines as written.
    public var raw = ""
}

/// A mail body cut into what the sender newly wrote and what they only quoted or forwarded. The text comes
/// from the HTML part when there is one (mail programs mark quotes and signatures there), else from the text part.
public struct SegmentedBody: Equatable, Sendable {
    /// The whole plain text the body was cut from.
    public var source = ""
    /// Everything above the quote as written, signature and device footer included. The bubble lays this out.
    public var own = ""
    /// The text the sender wrote, without quotes and signature. Empty when they only answered inline.
    public var text = ""
    /// Everything from the first quoted line on, if any.
    public var quoted: String?
    /// Lines the sender wrote inside the quoted part (inline answers), used when `text` is empty.
    public var inlineText = ""
    /// The header above the first quoted or forwarded message.
    public var header: QuoteHeader?
    /// The first quoted message's text without its header, up to the next quoted message inside it.
    public var quotedBody: String?
    /// The forwarded message's own text, when this mail forwards one: what it says, without its header.
    public var forwarded: String?
    /// Lines the HTML marked as the sender's signature.
    public var signatureLines: Set<String> = []

    /// What a chat bubble should show.
    public var display: String { text.isEmpty ? inlineText : text }
    public var isForward: Bool { header?.isForward == true }
}

/// Cuts a mail into its parts. Rules only, no model: quote markers, the header blocks and attribution lines mail
/// programs write in several languages, and the elements they wrap quotes and signatures in.
public enum MailSegmenter {
    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Lines that start a quoted or forwarded message.
    static let quoteHeaders: [NSRegularExpression] = [
        #"^On .{4,200} wrote:\s*$"#,
        #"^Am .{4,200} schrieb .{0,120}:\s*$"#,
        #"^Am .{4,200}:\s*$"#,
        #"^Le .{4,200} a écrit\s*:\s*$"#,
        #"^Il .{4,200} ha scritto:\s*$"#,
        #"^El .{4,200} escribió:\s*$"#,
        #"^-{2,}\s*(Original Message|Ursprüngliche Nachricht|Message d'origine|Forwarded message|Weitergeleitete Nachricht|Messaggio originale|Oorspronkelijk bericht|Doorgestuurd bericht|Message transféré)\s*-{2,}\s*$"#,
        #"^(Begin forwarded message|Anfang der weitergeleiteten Nachricht|Début du message réexpédié|Inizio messaggio inoltrato)\s*:\s*$"#,
        #"^_{5,}\s*$"#,
        #"^\d{1,2}\.? ?[A-Za-zäöü]{3,9}\.? ?\d{4}.{0,40}<.+@.+>:\s*$"#,
    ].map(regex)

    /// Markers that say the quoted message was forwarded, not answered.
    static let forwardMarker = regex(#"forwarded message|weitergeleitete Nachricht|message transféré|message réexpédié|messaggio inoltrato|doorgestuurd bericht"#)

    /// The verb of an attribution line ("Reto <kasse@vbc.ch> schrieb am Di., 7. Okt.:", "Op 4 sep heeft … geschreven:").
    static let attributionVerb = regex(#"\b(wrote|schrieb|geschrieben|geschreven|schreef|a écrit|ha scritto|escribió|skrev)\b"#)
    static let fromField = regex(#"^\*?(From|Von|De|Da|Van)\*?\s*:"#)
    /// Lines a mail client writes above a quoted or forwarded mail: "Gesendet: …", "*An:* …", "Subject: …".
    static let headerField = regex(
        #"^\*?(From|Von|De|Da|Van|Sent|Gesendet|Date|Datum|Envoyé|Inviato|Verzonden|To|An|À|A|Aan|Cc|Kopie|Subject|Betreff|Objet|Oggetto|Onderwerp|Reply-To|Antwort an)\*?\s*:"#)
    /// Header fields that hardly ever start a sentence a person writes ("Datum:" and "Date:" do).
    static let strongHeaderField = regex(
        #"^\*?(From|Von|De|Da|Van|Sent|Gesendet|Envoyé|Inviato|Verzonden|To|An|Aan|Cc|Kopie|Subject|Betreff|Objet|Oggetto|Onderwerp)\*?\s*:"#)
    static let signatureLines = regex(
        #"^(--\s?|__+|(Sent|Gesendet|Envoyé) (from|von|mit|de|depuis) .{1,60}|Von meinem .{1,40} gesendet\.?|Diese Nachricht wurde von meinem .{1,60}|Get Outlook for .{1,60}|Outlook für .{1,60} beziehen)$"#)

    static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // MARK: Entry points

    /// Cuts a mail. The HTML part is read when there is one; `subject` tells a forward from a reply when the
    /// header block does not.
    public static func segment(text: String?, html: String?, subject: String = "") -> SegmentedBody {
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = HTMLText.lines(html)
            if lines.contains(where: { !$0.text.isEmpty }) {
                return segment(lines: lines, subject: subject)
            }
        }
        let lines = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { HTMLLine(text: String($0), region: .text) }
        return segment(lines: lines, subject: subject)
    }

    /// Cuts plain text (a text part, or lines already read out of HTML).
    public static func segment(lines rawLines: [HTMLLine], subject: String = "") -> SegmentedBody {
        let lines = rawLines.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let regions = rawLines.map(\.region)
        var result = SegmentedBody()
        result.source = rawLines.map(\.text).joined(separator: "\n")

        var cut = lines.count
        for index in lines.indices {
            let line = lines[index]
            if regions[index] == .quote, !line.isEmpty { cut = index; break }
            if line.hasPrefix(">") { cut = index; break }
            if quoteHeaders.contains(where: { matches($0, line) }) { cut = index; break }
            // "Am 7. Okt. um 09:12 schrieb Reto <kasse@vbc.ch>:", also when it wraps onto two or three lines.
            if attributionLength(lines, at: index) != nil { cut = index; break }
            // "Von: … Gesendet: … An: … Betreff: …" blocks, in whatever order the program writes the fields.
            if headerBlockLength(lines, at: index) != nil { cut = index; break }
        }
        // An attribution right above the quote belongs to it, also when the client wrapped its end onto the
        // quote marker ("… schreef Benjamin Amhof <ben@example.ch" / ">:").
        if cut < lines.count {
            var start = cut
            while start > 0, lines[start - 1].isEmpty { start -= 1 }
            for take in 1...3 where start - take >= 0 {
                let joined = lines[(start - take)..<start].joined(separator: " ")
                if joined.count < 300, matches(attributionVerb, joined), joined.contains("@") || joined.contains(where: \.isNumber),
                   joined.hasSuffix(":") || lines[cut].hasPrefix(">") || regions[cut] == .quote {
                    cut = start - take
                    break
                }
            }
        }

        var own = Array(lines[..<cut])
        result.own = rawLines[..<cut].map(\.text).joined(separator: "\n")
        result.signatureLines = Set(zip(own, regions[..<cut]).filter { $0.1 == .signature && !$0.0.isEmpty }.map(\.0))
        // Signatures only count in the sender's own part.
        if let signature = own.firstIndex(where: { matches(signatureLines, $0) }) {
            own = Array(own[..<signature])
        }
        result.text = own.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let rest = Array(lines[cut...])
        guard !rest.isEmpty else { return result }
        let quoted = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result.quoted = quoted.isEmpty ? nil : quoted

        // Inline answers: lines inside the quoted part that are not quoted themselves and not generated.
        var inline: [String] = []
        var sawQuote = false
        for line in rest {
            if line.hasPrefix(">") { sawQuote = true; continue }
            if line.isEmpty || isGenerated(line) { continue }
            if sawQuote { inline.append(line) }
        }
        result.inlineText = inline.joined(separator: "\n")

        // The header of the quoted message, and the forwarded message's own text.
        let unquoted = rest.map { line -> String in
            var line = Substring(line)
            if line.hasPrefix(">") { line = line.dropFirst(); if line.hasPrefix(" ") { line = line.dropFirst() } }
            return String(line)
        }
        if let (header, length) = readHeader(unquoted) {
            var header = header
            if !header.isForward, Threading.isForwardSubject(subject), !matches(attributionVerb, header.raw) { header.isForward = true }
            result.header = header
            let body = Array(unquoted[length...])
            var end = body.count
            for index in body.indices where index > 0 {
                if quoteHeaders.contains(where: { matches($0, body[index]) }) || attributionLength(body, at: index) != nil
                    || headerBlockLength(body, at: index) != nil {
                    end = index
                    break
                }
            }
            let quotedBody = body[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            result.quotedBody = quotedBody.isEmpty ? nil : quotedBody
            if header.isForward { result.forwarded = result.quotedBody }
        }
        return result
    }

    // MARK: Lines

    /// How many lines the attribution starting at `index` spans ("On … <x@y>" / "wrote:" wrap), nil if there is none.
    static func attributionLength(_ lines: [String], at index: Int) -> Int? {
        var joined = ""
        for offset in 0..<3 where index + offset < lines.count {
            let line = lines[index + offset]
            if line.isEmpty || line.hasPrefix(">") || joined.count + line.count > 300 { return nil }
            joined += (offset == 0 ? "" : " ") + line
            if joined.hasSuffix(":"), matches(attributionVerb, joined), joined.contains("@") || joined.contains(where: \.isNumber) {
                return offset + 1
            }
        }
        return nil
    }

    /// How many lines a header block starting at `index` spans: a "From" field and at least two other fields
    /// within a few lines, blank lines in between allowed (GMX and Apple Mail leave them). Nil if there is none.
    static func headerBlockLength(_ lines: [String], at index: Int) -> Int? {
        guard matches(headerField, lines[index]) else { return nil }
        var fields = Set<String>()
        var hasFrom = false
        var length = 0
        var blanks = 0
        var cursor = index
        while cursor < lines.count, cursor - index < 14 {
            let line = lines[cursor]
            if line.isEmpty {
                blanks += 1
                if blanks > 2 { break }
            } else if matches(headerField, line) {
                blanks = 0
                fields.insert(fieldName(line))
                if matches(fromField, line) { hasFrom = true }
                length = cursor - index + 1
            } else if cursor > index, !matches(headerField, lines[cursor - 1]) {
                // Two lines in a row that are no fields: the block has ended.
                break
            } else if fields.count >= 1, line.count < 120, cursor + 1 < lines.count, matches(headerField, lines[cursor + 1]) {
                // A wrapped field value ("An: a@b," / "<c@d>").
                length = cursor - index + 1
            } else if fields.count >= 1, line.hasPrefix("<") || line.hasPrefix("("), cursor - index < 10 {
                length = cursor - index + 1
            } else {
                break
            }
            cursor += 1
        }
        return hasFrom && fields.count >= 3 ? length : nil
    }

    static func fieldName(_ line: String) -> String {
        String(line.prefix { $0 != ":" }).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "* "))
    }

    /// True for lines a mail client generates rather than a person writes: attributions, header fields, separators.
    public static func isGenerated(_ line: String) -> Bool {
        quoteHeaders.contains { matches($0, line) } || matches(strongHeaderField, line) || matches(signatureLines, line)
            || line.count < 300 && line.hasSuffix(":") && matches(attributionVerb, line) && (line.contains("@") || line.contains(where: \.isNumber))
    }

    // MARK: Headers

    /// Reads the header at the start of the quoted part (blank lines and a marker line like
    /// "-------- Ursprüngliche Nachricht --------" first): the fields of a header block, or an attribution line.
    /// Returns the header and how many lines it took.
    static func readHeader(_ lines: [String]) -> (QuoteHeader, Int)? {
        var index = 0
        var header = QuoteHeader()
        var rawLines: [String] = []
        while index < lines.count, lines[index].isEmpty { index += 1 }
        guard index < lines.count else { return nil }
        if quoteHeaders.contains(where: { matches($0, lines[index]) }) {
            header.isForward = matches(forwardMarker, lines[index])
            rawLines.append(lines[index])
            if matches(attributionVerb, lines[index]) {
                readAttribution(lines[index], into: &header)
                header.raw = lines[index]
                return (header, index + 1)
            }
            index += 1
            while index < lines.count, lines[index].isEmpty { index += 1 }
        }
        guard index < lines.count else { return nil }
        if let length = attributionLength(lines, at: index) {
            let joined = lines[index..<(index + length)].joined(separator: " ")
            readAttribution(joined, into: &header)
            header.raw = (rawLines + [joined]).joined(separator: "\n")
            return (header, index + length)
        }
        guard let length = headerBlockLength(lines, at: index) else {
            return rawLines.isEmpty ? nil : (header, index)
        }
        var field = ""
        for line in lines[index..<(index + length)] {
            rawLines.append(line)
            if line.isEmpty { continue }
            if matches(headerField, line) {
                field = fieldName(line)
                let value = String(line.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
                set(field, value, into: &header)
            } else if !field.isEmpty {
                append(field, line, into: &header)
            }
        }
        header.raw = rawLines.joined(separator: "\n")
        return (header, index + length)
    }

    static func set(_ field: String, _ value: String, into header: inout QuoteHeader) {
        // Outlook: "Reto <kasse@vbc.ch<mailto:kasse@vbc.ch>>", older Outlook: "Reto [mailto:kasse@vbc.ch]".
        let value = value.replacingOccurrences(of: "<mailto:[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\[mailto:([^\]]+)\]"#, with: "<$1>", options: [.regularExpression, .caseInsensitive])
        switch field {
        case "from", "von", "de", "da", "van": header.from = MIME.parseAddressList(value).first ?? EmailAddress(name: value, address: "")
        case "sent", "gesendet", "date", "datum", "envoyé", "inviato", "verzonden":
            header.dateText = value
            header.date = HeaderDate.parse(value)
        case "to", "an", "à", "a", "aan": header.to = MIME.parseAddressList(value)
        case "cc", "kopie": header.cc = MIME.parseAddressList(value)
        case "subject", "betreff", "objet", "oggetto", "onderwerp": header.subject = value
        default: break
        }
    }

    static func append(_ field: String, _ line: String, into header: inout QuoteHeader) {
        let line = line.replacingOccurrences(of: "<mailto:[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        switch field {
        case "to", "an", "à", "a", "aan": header.to += MIME.parseAddressList(line)
        case "cc", "kopie": header.cc += MIME.parseAddressList(line)
        case "subject", "betreff", "objet", "oggetto", "onderwerp": header.subject += " " + line
        case "from", "von", "de", "da", "van":
            if header.from?.address.isEmpty ?? true, let found = MIME.parseAddressList(line).first {
                header.from = EmailAddress(name: header.from?.name ?? found.name, address: found.address)
            }
        default: break
        }
    }

    /// "Am 7. Okt. 2026 um 09:12 schrieb Reto Kaufmann <kasse@vbc.ch>:", "On Tue, Oct 7, 2026 at 9:12 AM Reto <r@x> wrote:",
    /// "Reto <kasse@vbc.ch> schrieb am Di., 7. Okt. 2026 um 09:12:".
    static func readAttribution(_ text: String, into header: inout QuoteHeader) {
        header.dateText = text
        header.date = HeaderDate.parse(text)
        let ns = text as NSString
        if let match = regex(#"([^<>:,]{0,80}?)\s*<([^<>\s]+@[^<>\s]+)>"#).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            var name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            // "schrieb Reto Kaufmann", "9:12 AM Reto Kaufmann": the name is the capitalised words at the end.
            let words = name.split(separator: " ").map(String.init)
            var tail: [String] = []
            for word in words.reversed() {
                guard word.first?.isUppercase == true || word.first?.isLetter == true && tail.isEmpty == false, !matches(attributionVerb, word),
                      !word.contains(where: \.isNumber), !["AM", "PM", "um", "at", "a", "le"].contains(word) else { break }
                tail.insert(word, at: 0)
            }
            name = tail.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            header.from = EmailAddress(name: name, address: ns.substring(with: match.range(at: 2)))
            return
        }
        // Without an address: "… schrieb Reto Kaufmann:" or "Reto Kaufmann wrote:".
        if let match = regex(#"\b(?:schrieb|a écrit|ha scritto|escribió)\s+(.{2,60}?)\s*:\s*$"#).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            header.from = EmailAddress(name: ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), address: "")
        } else if let match = regex(#"(?:^|\d\s*(?:AM|PM)?\s+|,\s+)([\p{L}][\p{L}' .-]{1,60}?)\s+(?:wrote|schreef|skrev)\s*:"#).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            header.from = EmailAddress(name: ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), address: "")
        }
    }
}

/// Reads dates the way mail programs write them in header lines, in German, English, French, Dutch and Italian:
/// "Donnerstag, 7. Mai 2026 um 20:22", "Tuesday, 13 October 2026 at 15:10", "Oct 7, 2026, 9:12 AM", "23.09.26 21:01".
public enum HeaderDate {
    static let months: [String: Int] = [
        "jan": 1, "gen": 1, "feb": 2, "fev": 2, "mar": 3, "mrz": 3, "maa": 3, "apr": 4, "avr": 4, "mai": 5, "may": 5, "mei": 5, "mag": 5,
        "jun": 6, "giu": 6, "jul": 7, "lug": 7, "aug": 8, "aou": 8, "ago": 8, "sep": 9, "set": 9, "okt": 10, "oct": 10, "ott": 10,
        "nov": 11, "dez": 12, "dec": 12, "dic": 12,
    ]
    static let numeric = try! NSRegularExpression(pattern: #"\b(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})\b"#)
    static let dayMonthYear = try! NSRegularExpression(pattern: #"\b(\d{1,2})\.?\s+(\p{L}{3,10})\.?,?\s+(\d{4})\b"#)
    static let monthDayYear = try! NSRegularExpression(pattern: #"\b(\p{L}{3,10})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#)
    static let time = try! NSRegularExpression(pattern: #"\b(\d{1,2})[:.](\d{2})(?::\d{2})?\s*(AM|PM|am|pm)?\b"#)

    public static func parse(_ text: String) -> Date? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var day = 0, month = 0, year = 0
        var dateEnd = 0
        if let match = dayMonthYear.firstMatch(in: text, range: range), let m = monthNumber(ns.substring(with: match.range(at: 2))) {
            day = Int(ns.substring(with: match.range(at: 1))) ?? 0; month = m; year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            dateEnd = match.range.location + match.range.length
        } else if let match = monthDayYear.firstMatch(in: text, range: range), let m = monthNumber(ns.substring(with: match.range(at: 1))) {
            month = m; day = Int(ns.substring(with: match.range(at: 2))) ?? 0; year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            dateEnd = match.range.location + match.range.length
        } else if let match = numeric.firstMatch(in: text, range: range) {
            day = Int(ns.substring(with: match.range(at: 1))) ?? 0; month = Int(ns.substring(with: match.range(at: 2))) ?? 0
            year = Int(ns.substring(with: match.range(at: 3))) ?? 0
            if year < 100 { year += 2000 }
            dateEnd = match.range.location + match.range.length
        } else {
            return nil
        }
        guard (1...31).contains(day), (1...12).contains(month), (1990...2100).contains(year) else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0)
        if let match = time.firstMatch(in: text, range: NSRange(location: dateEnd, length: ns.length - dateEnd)) {
            var hour = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let minute = Int(ns.substring(with: match.range(at: 2))) ?? 0
            if match.range(at: 3).location != NSNotFound {
                let suffix = ns.substring(with: match.range(at: 3)).uppercased()
                if suffix == "PM", hour < 12 { hour += 12 }
                if suffix == "AM", hour == 12 { hour = 0 }
            }
            if (0...23).contains(hour), (0...59).contains(minute) {
                components.hour = hour
                components.minute = minute
            }
        }
        return Calendar.current.date(from: components)
    }

    static func monthNumber(_ name: String) -> Int? {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        if folded.hasPrefix("juil") { return 7 }
        if folded.hasPrefix("jui") { return 6 }
        return months[String(folded.prefix(3))]
    }
}
