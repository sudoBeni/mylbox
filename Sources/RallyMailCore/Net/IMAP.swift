import Foundation

public enum IMAPError: LocalizedError {
    case commandFailed(String, String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let message): "IMAP \(command) failed: \(message)"
        case .unexpected(let message): "IMAP: \(message)"
        }
    }
}

/// A parsed IMAP data item.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    public var text: String? {
        switch self {
        case .atom(let value): value
        case .string(let data): String(decoding: data, as: UTF8.self)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let value): Data(value.utf8)
        default: nil
        }
    }

    public var list: [IMAPValue] {
        if case .list(let items) = self { return items }
        return []
    }
}

/// Tokenizes an IMAP response (including inline literals) into values.
public struct IMAPParser {
    private let bytes: [UInt8]
    private var index = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public static func parse(_ bytes: [UInt8]) -> [IMAPValue] {
        var parser = IMAPParser(bytes)
        return parser.values(until: nil)
    }

    private mutating func values(until terminator: UInt8?) -> [IMAPValue] {
        var result: [IMAPValue] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x0D || byte == 0x0A { index += 1; continue }
            if let terminator, byte == terminator { index += 1; return result }
            if byte == 0x29 { index += 1; continue } // stray ')'
            result.append(value())
        }
        return result
    }

    private mutating func value() -> IMAPValue {
        let byte = bytes[index]
        switch byte {
        case 0x28: // (
            index += 1
            return .list(values(until: 0x29))
        case 0x22: // "
            index += 1
            var output: [UInt8] = []
            while index < bytes.count, bytes[index] != 0x22 {
                if bytes[index] == 0x5C, index + 1 < bytes.count { index += 1 }
                output.append(bytes[index])
                index += 1
            }
            index += 1
            return .string(Data(output))
        case 0x7B: // {n}\r\n literal
            var end = index + 1
            while end < bytes.count, bytes[end] != 0x7D { end += 1 }
            let digits = String(decoding: bytes[(index + 1)..<min(end, bytes.count)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            let count = Int(digits) ?? 0
            index = end + 1
            if index < bytes.count, bytes[index] == 0x0D { index += 1 }
            if index < bytes.count, bytes[index] == 0x0A { index += 1 }
            let stop = min(index + count, bytes.count)
            let data = Data(bytes[index..<stop])
            index = stop
            return .string(data)
        default:
            var output: [UInt8] = []
            var depth = 0
            while index < bytes.count {
                let current = bytes[index]
                if current == 0x5B { depth += 1 } // [
                if current == 0x5D { depth -= 1 } // ]
                // Inside brackets (e.g. BODY[HEADER.FIELDS (FROM)]) spaces and parens belong to the atom.
                if depth <= 0, current == 0x20 || current == 0x28 || current == 0x29 || current == 0x0D || current == 0x0A {
                    break
                }
                output.append(current)
                index += 1
            }
            let atom = String(decoding: output, as: UTF8.self)
            return atom.uppercased() == "NIL" ? .nil_ : .atom(atom)
        }
    }
}

public struct IMAPMailbox: Sendable, Hashable {
    public var name: String
    public var attributes: Set<String>

    public func has(_ attribute: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }
}

public struct IMAPFetchedMessage: Sendable {
    public var uid: UInt32
    public var flags: Set<String>
    public var internalDate: Date?
    public var raw: Data?
    /// Gmail's conversation id (X-GM-THRID), when asked for.
    public var gmailThread: String? = nil
}

public enum IMAPAuth: Sendable {
    case password(user: String, password: String)
    case xoauth2(user: String, token: String)
}

public final class IMAPClient: @unchecked Sendable {
    private let connection: TextConnection
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []

    private init(connection: TextConnection) {
        self.connection = connection
    }

    public static func connect(_ endpoint: ServerEndpoint) async throws -> IMAPClient {
        let connection = try await TextConnection.connect(host: endpoint.host, port: endpoint.port,
                                                          tls: endpoint.security == .tls)
        let client = IMAPClient(connection: connection)
        let greeting = String(decoding: try await connection.readLine(), as: UTF8.self)
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw IMAPError.unexpected("unexpected greeting: \(greeting)")
        }
        if endpoint.security == .startTLS {
            _ = try await client.command("STARTTLS")
            try await connection.startTLS()
        }
        return client
    }

    public func authenticate(_ auth: IMAPAuth) async throws {
        switch auth {
        case .password(let user, let password):
            _ = try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))", redacted: "LOGIN")
        case .xoauth2(let user, let token):
            let payload = Data("user=\(user)\u{01}auth=Bearer \(token)\u{01}\u{01}".utf8).base64EncodedString()
            _ = try await command("AUTHENTICATE XOAUTH2 \(payload)", redacted: "AUTHENTICATE")
        }
        let result = try await command("CAPABILITY")
        for line in result.untagged {
            let values = IMAPParser.parse(line)
            if values.count > 1, values[1].text?.uppercased() == "CAPABILITY" {
                capabilities = Set(values.dropFirst(2).compactMap { $0.text?.uppercased() })
            }
        }
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        await connection.close()
    }

    public func close() async {
        await connection.close()
    }

    // MARK: Commands

    public struct Result {
        public var untagged: [[UInt8]]
        public var status: String
    }

    /// Sends a command and collects untagged responses until the tagged completion.
    /// `continuation` provides the data to send when the server asks for more (`+`).
    @discardableResult
    public func command(_ text: String, redacted: String? = nil,
                        continuation: (() -> Data)? = nil) async throws -> Result {
        tagCounter += 1
        let tag = String(format: "M%04d", tagCounter)
        try await connection.write("\(tag) \(text)\r\n")
        var untagged: [[UInt8]] = []
        var pendingContinuation = continuation
        while true {
            let response = try await readResponse()
            if response.starts(with: Array("\(tag) ".utf8)) {
                let status = String(decoding: response.dropFirst(tag.count + 1), as: UTF8.self)
                if status.uppercased().hasPrefix("OK") {
                    return Result(untagged: untagged, status: status)
                }
                let name = redacted ?? String(text.prefix(40))
                throw IMAPError.commandFailed(name, status)
            } else if response.first == 0x2B { // "+"
                if let provide = pendingContinuation {
                    pendingContinuation = nil
                    try await connection.write(provide())
                    try await connection.write("\r\n")
                } else {
                    // e.g. a SASL error challenge: answer with an empty line to get the tagged NO.
                    try await connection.write("\r\n")
                }
            } else {
                untagged.append(response)
            }
        }
    }

    /// Reads a full response, including any literals and the lines that follow them.
    private func readResponse() async throws -> [UInt8] {
        var response: [UInt8] = []
        while true {
            let line = try await connection.readLine()
            response.append(contentsOf: line)
            guard line.last == 0x7D, let open = line.lastIndex(of: 0x7B) else { return response }
            let digits = String(decoding: line[(open + 1)..<(line.count - 1)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
            guard let count = Int(digits) else { return response }
            response.append(contentsOf: [0x0D, 0x0A])
            response.append(contentsOf: try await connection.readBytes(count))
        }
    }

    static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func mailboxArgument(_ name: String) -> String {
        quote(ModifiedUTF7.encode(name))
    }

    // MARK: Mailboxes

    public func listMailboxes() async throws -> [IMAPMailbox] {
        let result = try await command("LIST \"\" \"*\"")
        return result.untagged.compactMap { line in
            let values = IMAPParser.parse(line)
            guard values.count >= 5, values[1].text?.uppercased() == "LIST", let name = values[4].text else { return nil }
            let attributes = Set(values[2].list.compactMap(\.text))
            return IMAPMailbox(name: ModifiedUTF7.decode(name), attributes: attributes)
        }
    }

    public struct SelectInfo: Sendable {
        public var uidValidity: UInt32
        public var exists: Int
    }

    public func select(_ mailbox: String) async throws -> SelectInfo {
        let result = try await command("SELECT \(Self.mailboxArgument(mailbox))")
        var info = SelectInfo(uidValidity: 0, exists: 0)
        for line in result.untagged {
            let text = String(decoding: line, as: UTF8.self)
            if let range = text.range(of: "[UIDVALIDITY ") {
                let number = text[range.upperBound...].prefix { $0.isNumber }
                info.uidValidity = UInt32(number) ?? 0
            } else if text.hasSuffix(" EXISTS") {
                info.exists = Int(text.dropFirst(2).prefix { $0.isNumber }) ?? 0
            }
        }
        return info
    }

    public func uidSearch(_ criteria: String = "ALL") async throws -> [UInt32] {
        let result = try await command("UID SEARCH \(criteria)")
        var uids: [UInt32] = []
        for line in result.untagged {
            let values = IMAPParser.parse(line)
            guard values.count >= 2, values[1].text?.uppercased() == "SEARCH" else { continue }
            uids += values.dropFirst(2).compactMap { $0.text.flatMap { UInt32($0) } }
        }
        return uids
    }

    public func uidFetch(_ uids: [UInt32], items: String) async throws -> [IMAPFetchedMessage] {
        guard !uids.isEmpty else { return [] }
        return try await uidFetch(set: Self.sequenceSet(uids), items: items)
    }

    public func uidFetch(set: String, items: String) async throws -> [IMAPFetchedMessage] {
        let result = try await command("UID FETCH \(set) (\(items))")
        return result.untagged.compactMap(Self.parseFetch)
    }

    static func parseFetch(_ line: [UInt8]) -> IMAPFetchedMessage? {
        let values = IMAPParser.parse(line)
        guard values.count >= 4, values[2].text?.uppercased() == "FETCH" else { return nil }
        let items = values[3].list
        var message = IMAPFetchedMessage(uid: 0, flags: [], internalDate: nil, raw: nil)
        var index = 0
        while index + 1 < items.count {
            let key = items[index].text?.uppercased() ?? ""
            let value = items[index + 1]
            switch key {
            case "UID": message.uid = value.text.flatMap { UInt32($0) } ?? 0
            case "FLAGS": message.flags = Set(value.list.compactMap(\.text))
            case "INTERNALDATE": message.internalDate = value.text.flatMap(parseInternalDate)
            case "X-GM-THRID": message.gmailThread = value.text
            default:
                if key.hasPrefix("BODY[") || key == "RFC822" { message.raw = value.data }
            }
            index += 2
        }
        return message.uid == 0 ? nil : message
    }

    private static let internalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    static func parseInternalDate(_ value: String) -> Date? {
        internalDateFormatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    public func uidStore(_ uids: [UInt32], add: Bool, flags: [String]) async throws {
        guard !uids.isEmpty else { return }
        try await command("UID STORE \(Self.sequenceSet(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flags.joined(separator: " ")))")
    }

    /// Moves messages and returns the new UIDs in the target mailbox when the server reports them (UIDPLUS).
    public func uidMove(_ uids: [UInt32], to mailbox: String) async throws -> [UInt32: UInt32] {
        guard !uids.isEmpty else { return [:] }
        let set = Self.sequenceSet(uids)
        let target = Self.mailboxArgument(mailbox)
        let result: Result
        if capabilities.contains("MOVE") {
            result = try await command("UID MOVE \(set) \(target)")
        } else {
            result = try await command("UID COPY \(set) \(target)")
            try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                try await command("UID EXPUNGE \(set)")
            } else {
                try await command("EXPUNGE")
            }
        }
        let texts = result.untagged.map { String(decoding: $0, as: UTF8.self) } + [result.status]
        for text in texts {
            if let mapping = Self.parseCopyUID(text) { return mapping }
        }
        return [:]
    }

    static func parseCopyUID(_ text: String) -> [UInt32: UInt32]? {
        guard let range = text.range(of: "[COPYUID ", options: .caseInsensitive),
              let end = text[range.upperBound...].firstIndex(of: "]") else { return nil }
        let parts = text[range.upperBound..<end].split(separator: " ")
        guard parts.count == 3 else { return nil }
        let source = expandSet(String(parts[1]))
        let target = expandSet(String(parts[2]))
        guard source.count == target.count else { return nil }
        return Dictionary(zip(source, target), uniquingKeysWith: { first, _ in first })
    }

    public func append(_ data: Data, to mailbox: String, flags: [String]) async throws {
        try await command("APPEND \(Self.mailboxArgument(mailbox)) (\(flags.joined(separator: " "))) {\(data.count)}",
                          continuation: { data })
    }

    // MARK: Sequence sets

    static func sequenceSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var end = start
            while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
                index += 1
                end = sorted[index]
            }
            ranges.append(start == end ? "\(start)" : "\(start):\(end)")
            index += 1
        }
        return ranges.joined(separator: ",")
    }

    static func expandSet(_ set: String) -> [UInt32] {
        set.split(separator: ",").flatMap { part -> [UInt32] in
            let bounds = part.split(separator: ":").compactMap { UInt32($0) }
            if bounds.count == 2 { return Array(min(bounds[0], bounds[1])...max(bounds[0], bounds[1])) }
            return bounds
        }
    }
}

/// IMAP mailbox names use a modified UTF-7 encoding (RFC 3501 §5.1.3).
public enum ModifiedUTF7 {
    public static func decode(_ input: String) -> String {
        var output = ""
        var rest = Substring(input)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let dash = after.firstIndex(of: "-") else { output += rest[amp...]; return output }
            let encoded = after[..<dash]
            if encoded.isEmpty {
                output += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64) {
                    let units = stride(from: 0, to: data.count - 1, by: 2).map { UInt16(data[$0]) << 8 | UInt16(data[$0 + 1]) }
                    output += String(decoding: units, as: UTF16.self)
                }
            }
            rest = after[after.index(after: dash)...]
        }
        output += rest
        return output
    }

    public static func encode(_ input: String) -> String {
        var output = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var data = Data()
            for unit in pending { data.append(UInt8(unit >> 8)); data.append(UInt8(unit & 0xFF)) }
            let base64 = data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",")
            output += "&\(base64)-"
            pending = []
        }
        for scalar in input.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                output += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += Array(String(scalar).utf16)
            }
        }
        flush()
        return output
    }
}
