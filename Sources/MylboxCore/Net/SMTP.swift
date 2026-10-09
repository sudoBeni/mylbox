import Foundation

public enum SMTPError: LocalizedError {
    case rejected(String, String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let step, let reply): "SMTP \(step) rejected: \(reply)"
        }
    }
}

public enum SMTPClient {
    public static func send(_ message: Data, from: String, recipients: [String],
                            endpoint: ServerEndpoint, auth: IMAPAuth) async throws {
        let connection = try await TextConnection.connect(host: endpoint.host, port: endpoint.port,
                                                          tls: endpoint.security == .tls)
        defer { Task { await connection.close() } }

        func reply() async throws -> (code: Int, text: String) {
            var lines: [String] = []
            while true {
                let line = String(decoding: try await connection.readLine(), as: UTF8.self)
                lines.append(line)
                // "250-..." continues, "250 ..." ends a reply.
                if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" {
                    return (Int(line.prefix(3)) ?? 0, lines.joined(separator: "\n"))
                }
            }
        }

        func expect(_ step: String, _ codes: Set<Int>, send command: String?) async throws -> String {
            if let command { try await connection.write(command + "\r\n") }
            let (code, text) = try await reply()
            guard codes.contains(code) else { throw SMTPError.rejected(step, text) }
            return text
        }

        _ = try await expect("greeting", [220], send: nil)
        let hostname = "mylbox.local"
        var capabilities = try await expect("EHLO", [250], send: "EHLO \(hostname)")
        if endpoint.security == .startTLS {
            _ = try await expect("STARTTLS", [220], send: "STARTTLS")
            try await connection.startTLS()
            capabilities = try await expect("EHLO", [250], send: "EHLO \(hostname)")
        }
        _ = capabilities

        switch auth {
        case .password(let user, let password):
            let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
            _ = try await expect("login", [235], send: "AUTH PLAIN \(token)")
        case .xoauth2(let user, let accessToken):
            let token = Data("user=\(user)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
            try await connection.write("AUTH XOAUTH2 \(token)\r\n")
            let (code, text) = try await reply()
            if code == 334 {
                // Error details come as a challenge; an empty answer finishes the exchange.
                _ = try? await expect("login", [235], send: "")
                throw SMTPError.rejected("login", text)
            }
            guard code == 235 else { throw SMTPError.rejected("login", text) }
        }

        _ = try await expect("MAIL FROM", [250], send: "MAIL FROM:<\(from)>")
        for recipient in recipients {
            _ = try await expect("RCPT TO \(recipient)", [250, 251], send: "RCPT TO:<\(recipient)>")
        }
        _ = try await expect("DATA", [354], send: "DATA")
        try await connection.write(dotStuffed(message))
        _ = try await expect("message", [250], send: ".")
        try? await connection.write("QUIT\r\n")
    }

    /// Normalizes line endings to CRLF and escapes lines starting with a dot.
    static func dotStuffed(_ message: Data) -> Data {
        var output = Data()
        output.reserveCapacity(message.count + 64)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if byte == 0x0A, previous != 0x0D { output.append(0x0D) }
            if atLineStart, byte == 0x2E { output.append(0x2E) }
            output.append(byte)
            atLineStart = byte == 0x0A
            previous = byte
        }
        if !atLineStart { output.append(contentsOf: [0x0D, 0x0A]) }
        return output
    }
}
