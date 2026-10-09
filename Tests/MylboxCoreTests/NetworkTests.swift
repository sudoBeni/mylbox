import Foundation
import Testing
@testable import MylboxCore

/// Talks to real mail servers without logging in. Run with: MYLBOX_NET_TESTS=1 swift test --filter NetworkTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYLBOX_NET_TESTS"] != nil))
struct NetworkTests {
    @Test(arguments: [Provider.gmail, .icloud, .outlook])
    func imapGreetingAndCapabilities(provider: Provider) async throws {
        let client = try await IMAPClient.connect(provider.defaultIMAP)
        let result = try await client.command("CAPABILITY")
        #expect(result.untagged.contains { String(decoding: $0, as: UTF8.self).contains("IMAP4") })
        await client.logout()
    }

    @Test(arguments: [Provider.gmail, .icloud, .outlook])
    func smtpReachesLogin(provider: Provider) async throws {
        // Wrong credentials must fail at the login step, which proves TLS/STARTTLS and EHLO worked.
        do {
            try await SMTPClient.send(Data("x".utf8), from: "a@b.c", recipients: ["a@b.c"], endpoint: provider.defaultSMTP,
                                      auth: .password(user: "mylbox-test@example.com", password: "wrong"))
            Issue.record("login unexpectedly succeeded")
        } catch let SMTPError.rejected(step, _) {
            #expect(step == "login")
        }
    }
}
