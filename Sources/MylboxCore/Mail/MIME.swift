import Foundation

public struct MailAttachment: Sendable {
    public var filename: String
    public var mimeType: String
    public var contentID: String?
    public var isInline: Bool
    public var data: Data
}

/// The useful content of an RFC 5322 message.
public struct ParsedMail: Sendable {
    public var messageID = ""
    public var inReplyTo = ""
    public var references = ""
    public var subject = ""
    public var from: EmailAddress?
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var replyTo: [EmailAddress] = []
    public var date = Date()
    public var text: String?
    public var html: String?
    public var attachments: [MailAttachment] = []
    public var isBulk = false
    public var headers: [(name: String, value: String)] = []

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct MIMEPart {
    var headers: [(name: String, value: String)]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: (type: String, params: [String: String]) {
        MIME.parseParameterized(header("Content-Type") ?? "text/plain")
    }
}

public enum MIME {
    // MARK: Entry point

    public static func parse(_ raw: Data, fallbackDate: Date? = nil) -> ParsedMail {
        let part = splitPart(raw)
        var mail = ParsedMail()
        mail.headers = part.headers.map { ($0.name, decodeEncodedWords($0.value)) }
        mail.subject = mail.header("Subject")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mail.messageID = mail.header("Message-ID")?.trimmingCharacters(in: .whitespaces) ?? ""
        mail.inReplyTo = mail.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces) ?? ""
        mail.references = mail.header("References")?.trimmingCharacters(in: .whitespaces) ?? ""
        mail.from = parseAddressList(rawHeader(part, "From")).first
        mail.to = parseAddressList(rawHeader(part, "To"))
        mail.cc = parseAddressList(rawHeader(part, "Cc"))
        mail.replyTo = parseAddressList(rawHeader(part, "Reply-To"))
        mail.date = mail.header("Date").flatMap(parseDate) ?? fallbackDate ?? Date()
        let precedence = mail.header("Precedence")?.lowercased() ?? ""
        mail.isBulk = mail.header("List-Unsubscribe") != nil || mail.header("List-Id") != nil
            || precedence == "bulk" || precedence == "list"
        collect(part, into: &mail)
        return mail
    }

    /// Address headers are decoded per address so that encoded commas don't break splitting.
    private static func rawHeader(_ part: MIMEPart, _ name: String) -> String {
        part.headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value).joined(separator: ", ")
    }

    // MARK: Structure

    static func splitPart(_ data: Data) -> MIMEPart {
        let bytes = [UInt8](data)
        var headerEnd = bytes.count
        var bodyStart = bytes.count
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    headerEnd = index; bodyStart = index + 2; break
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    headerEnd = index; bodyStart = index + 3; break
                }
            }
            index += 1
        }
        if index == 0 && !bytes.isEmpty && (bytes[0] == 0x0A || bytes[0] == 0x0D) {
            // No headers at all.
            let start = bytes[0] == 0x0D ? 2 : 1
            return MIMEPart(headers: [], body: Data(bytes[min(start, bytes.count)...]))
        }
        let headerText = decodeText(Data(bytes[0..<headerEnd]), charset: nil)
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        return MIMEPart(headers: parseHeaders(headerText), body: body)
    }

    static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for line in text.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                result.append((name, value))
            }
        }
        return result
    }

    private static func collect(_ part: MIMEPart, into mail: inout ParsedMail) {
        let (type, params) = part.contentType
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for child in splitMultipart(part.body, boundary: boundary) {
                collect(child, into: &mail)
            }
            return
        }
        if type == "message/rfc822" {
            // Forwarded message: keep it as an attachment.
            mail.attachments.append(MailAttachment(filename: "forwarded.eml", mimeType: type, contentID: nil,
                                                   isInline: false, data: decodeBody(part)))
            return
        }
        let disposition = parseParameterized(part.header("Content-Disposition") ?? "")
        let filename = disposition.params["filename"] ?? params["name"]
        let isAttachment = disposition.type == "attachment" || (filename != nil && !type.hasPrefix("text/"))
        let data = decodeBody(part)

        if !isAttachment, type == "text/plain", mail.text == nil {
            mail.text = decodeText(data, charset: params["charset"])
        } else if !isAttachment, type == "text/html", mail.html == nil {
            mail.html = decodeText(data, charset: params["charset"])
        } else if isAttachment || filename != nil || !type.hasPrefix("text/") {
            let contentID = part.header("Content-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
            let isInline = disposition.type != "attachment" && contentID != nil
            mail.attachments.append(MailAttachment(
                filename: filename.map(decodeEncodedWords) ?? defaultFilename(type: type),
                mimeType: type, contentID: contentID, isInline: isInline, data: data))
        }
    }

    private static func defaultFilename(type: String) -> String {
        let ext = type.split(separator: "/").last.map(String.init) ?? "bin"
        return "attachment.\(ext)"
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [MIMEPart] {
        let delimiter = Array("--\(boundary)".utf8)
        let bytes = [UInt8](body)
        var parts: [MIMEPart] = []
        var lineStart = 0
        var partStart: Int?
        var index = 0
        while index <= bytes.count {
            if index == bytes.count || bytes[index] == 0x0A {
                var lineEnd = index
                if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                let line = bytes[lineStart..<lineEnd]
                if line.starts(with: delimiter) {
                    let rest = line.dropFirst(delimiter.count)
                    let isEnd = rest.starts(with: [0x2D, 0x2D])
                    let isBoundary = isEnd || rest.allSatisfy { $0 == 0x20 || $0 == 0x09 }
                    if isBoundary {
                        if let start = partStart {
                            // The CRLF before the delimiter belongs to the delimiter.
                            var end = lineStart
                            if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                            if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                            parts.append(splitPart(Data(bytes[start..<max(start, end)])))
                        }
                        if isEnd { return parts }
                        partStart = index + 1
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }
        if let start = partStart, start < bytes.count {
            parts.append(splitPart(Data(bytes[start...])))
        }
        return parts
    }

    static func decodeBody(_ part: MIMEPart) -> Data {
        switch part.header("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": decodeBase64(part.body)
        case "quoted-printable": decodeQuotedPrintable(part.body, underscoreIsSpace: false)
        default: part.body
        }
    }

    // MARK: Encodings

    static func decodeBase64(_ data: Data) -> Data {
        let cleaned = data.filter { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2B || byte == 0x2F
        }
        var string = String(decoding: cleaned, as: UTF8.self)
        let remainder = string.count % 4
        if remainder == 1 { string.removeLast() }
        if remainder > 1 { string += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: string) ?? Data()
    }

    static func decodeQuotedPrintable(_ data: Data, underscoreIsSpace: Bool) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                // Soft line break: "=\r\n" or "=\n"
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                output.append(byte)
            } else if underscoreIsSpace, byte == 0x5F {
                output.append(0x20)
            } else {
                output.append(byte)
            }
            index += 1
        }
        return Data(output)
    }

    public static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(),
           !charset.isEmpty {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let string = String(data: data, encoding: encoding) { return string }
            }
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Decodes RFC 2047 encoded words like `=?UTF-8?Q?Gr=C3=BCezi?=`.
    public static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let pattern = #/=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/#
        var output = ""
        var rest = Substring(input)
        var previousWasEncoded = false
        while let match = rest.firstMatch(of: pattern) {
            let between = rest[rest.startIndex..<match.range.lowerBound]
            // Whitespace between two encoded words is dropped.
            if !(previousWasEncoded && between.allSatisfy(\.isWhitespace)) {
                output += between
            }
            let charset = String(match.output.1).split(separator: "*").first.map(String.init)
            let payload = Data(match.output.3.utf8)
            let data = match.output.2.uppercased() == "B"
                ? decodeBase64(payload)
                : decodeQuotedPrintable(payload, underscoreIsSpace: true)
            output += decodeText(data, charset: charset)
            previousWasEncoded = true
            rest = rest[match.range.upperBound...]
        }
        output += rest
        return output
    }

    /// Parses `type/subtype; key=value; key2="value"` (including RFC 2231 `key*=charset''value`).
    static func parseParameterized(_ value: String) -> (type: String, params: [String: String]) {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        let type = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String)]] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            var extended = false
            if key.hasSuffix("*") {
                extended = true
                key.removeLast()
            }
            if extended, let quote = raw.range(of: "''") {
                let charset = String(raw[..<quote.lowerBound])
                let encoded = String(raw[quote.upperBound...])
                raw = decodeText(percentDecode(encoded), charset: charset.isEmpty ? "utf-8" : charset)
            } else if extended {
                raw = String(decoding: percentDecode(raw), as: UTF8.self)
            }
            // RFC 2231 continuations: filename*0=..., filename*1=...
            if let star = key.firstIndex(of: "*"), let number = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((number, raw))
            } else {
                params[key] = raw
            }
        }
        for (key, pieces) in continuations where params[key] == nil {
            params[key] = pieces.sorted { $0.0 < $1.0 }.map(\.1).joined()
        }
        return (type, params)
    }

    private static func percentDecode(_ string: String) -> Data {
        var output = Data()
        var index = string.startIndex
        while index < string.endIndex {
            if string[index] == "%",
               let end = string.index(index, offsetBy: 3, limitedBy: string.endIndex),
               let byte = UInt8(string[string.index(after: index)..<end], radix: 16) {
                output.append(byte)
                index = end
            } else {
                output.append(contentsOf: String(string[index]).utf8)
                index = string.index(after: index)
            }
        }
        return output
    }

    // MARK: Addresses & dates

    public static func parseAddressList(_ value: String) -> [EmailAddress] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var depth = 0
        for character in value {
            switch character {
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            case "(" where !inQuotes: depth += 1
            case ")" where !inQuotes: depth = max(0, depth - 1)
            default: break
            }
            if (character == "," || character == ";"), !inQuotes, !inAngle, depth == 0 {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items.compactMap { item in
            let item = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return nil }
            if let open = item.lastIndex(of: "<"), let close = item.lastIndex(of: ">"), open < close {
                let address = String(item[item.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                var name = String(item[..<open]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = decodeEncodedWords(name).replacingOccurrences(of: "\\\"", with: "\"")
                return EmailAddress(name: name, address: address)
            }
            // "addr (Name)" form or bare address
            var address = item
            var name = ""
            if let open = item.firstIndex(of: "("), let close = item.lastIndex(of: ")"), open < close {
                name = decodeEncodedWords(String(item[item.index(after: open)..<close]))
                address = String(item[..<open]).trimmingCharacters(in: .whitespaces)
            }
            guard address.contains("@") else { return nil }
            return EmailAddress(name: name, address: address)
        }
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
    private static let dateLock = NSLock()

    public static func parseDate(_ value: String) -> Date? {
        var cleaned = value
        if let comment = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<comment]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
        dateLock.lock()
        defer { dateLock.unlock() }
        for formatter in dateFormatters {
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}

public enum HTMLText {
    /// A cheap HTML → text conversion, good enough for snippets, search and exports.
    public static func plainText(_ html: String) -> String {
        var text = html
        for tag in ["style", "script", "head", "title"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/tr|/h[1-6]|/li|/table)[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
