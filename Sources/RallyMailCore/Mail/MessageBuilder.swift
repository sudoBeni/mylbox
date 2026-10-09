import Foundation

public struct OutgoingAttachment: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutgoingMail: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: String?
    public var attachments: [OutgoingAttachment]

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String, body: String, inReplyTo: String? = nil, references: String? = nil,
                attachments: [OutgoingAttachment] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }

    public var recipients: [String] { (to + cc + bcc).map(\.address) }
}

public enum MessageBuilder {
    public static func build(_ mail: OutgoingMail, date: Date = Date(), messageID: String? = nil) -> Data {
        let domain = mail.from.address.split(separator: "@").last.map(String.init) ?? "rallymail.local"
        var headers: [String] = []
        headers.append("From: \(encodeAddress(mail.from))")
        if !mail.to.isEmpty { headers.append("To: \(mail.to.map(encodeAddress).joined(separator: ", "))") }
        if !mail.cc.isEmpty { headers.append("Cc: \(mail.cc.map(encodeAddress).joined(separator: ", "))") }
        headers.append("Subject: \(encodeWord(mail.subject))")
        headers.append("Date: \(rfc2822(date))")
        headers.append("Message-ID: \(messageID ?? "<\(UUID().uuidString.lowercased())@\(domain)>")")
        if let inReplyTo = mail.inReplyTo, !inReplyTo.isEmpty { headers.append("In-Reply-To: \(inReplyTo)") }
        if let references = mail.references, !references.isEmpty { headers.append("References: \(references)") }
        headers.append("MIME-Version: 1.0")
        headers.append("X-Mailer: RallyMail")

        var body = ""
        if mail.attachments.isEmpty {
            headers.append("Content-Type: text/plain; charset=utf-8")
            headers.append("Content-Transfer-Encoding: base64")
            body = base64Lines(Data(normalize(mail.body).utf8))
        } else {
            let boundary = "rallymail-\(UUID().uuidString)"
            headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            body += "--\(boundary)\r\n"
            body += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            body += base64Lines(Data(normalize(mail.body).utf8)) + "\r\n"
            for attachment in mail.attachments {
                let name = encodeWord(attachment.filename).replacingOccurrences(of: "\"", with: "")
                body += "--\(boundary)\r\n"
                body += "Content-Type: \(attachment.mimeType); name=\"\(name)\"\r\n"
                body += "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
                body += "Content-Transfer-Encoding: base64\r\n\r\n"
                body += base64Lines(attachment.data) + "\r\n"
            }
            body += "--\(boundary)--"
        }
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func encodeWord(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII && !$0.isNewline }) { return text }
        // Split into chunks so that no encoded word exceeds the 75 character limit.
        var words: [String] = []
        var chunk = ""
        for character in text where !character.isNewline {
            if Data((chunk + String(character)).utf8).count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func encodeAddress(_ address: EmailAddress) -> String {
        guard !address.name.isEmpty else { return address.address }
        let name = address.name.allSatisfy(\.isASCII)
            ? "\"\(address.name.replacingOccurrences(of: "\"", with: "\\\""))\""
            : encodeWord(address.name)
        return "\(name) <\(address.address)>"
    }

    static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
