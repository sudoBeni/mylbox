import Foundation
import Testing
@testable import MylboxCore

@Suite struct TriageParsingTests {
    @Test func parsesModelAnswer() throws {
        let triage = try TriageService.parse(#"{"category": "important", "needs_reply": true, "summary": "Frage zur Abrechnung"}"#,
                                             isBulk: false)
        #expect(triage == Triage(category: .primary, needsReply: true, summary: "Frage zur Abrechnung"))
        #expect(try TriageService.parse(#"{"category":"spam","needs_reply":true,"summary":"x"}"#, isBulk: false)
            == Triage(category: .spam, needsReply: false, summary: "x"))
        #expect(try TriageService.parse(#"{"category":"important","needs_reply":true,"summary":"x"}"#, isBulk: true).needsReply == false)
    }

    @Test func oldConfigStillLoads() throws {
        let json = #"{"accounts":[],"spaces":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"VB","symbol":"folder","keepOutOfGit":false,"includeAttachments":true}],"rules":[],"aiClassificationEnabled":false,"initialSyncLimit":300,"syncIntervalMinutes":3}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.spaces.count == 1)
        #expect(config.aiClassificationEnabled == false)
        #expect(config.aiModelID == LocalModelCatalog.defaultModel.id)
    }
}

/// Runs the real model. MYLBOX_MODEL=/path/to/model.gguf swift test --filter LocalModelTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYLBOX_MODEL"] != nil))
struct LocalModelTests {
    static func mail(_ from: String, _ subject: String, _ body: String, bulk: Bool = false) -> MailMessage {
        var message = sampleMessage(subject: subject, from: from)
        message.from = MIME.parseAddressList(from)[0]
        message.bodyText = body
        message.isBulk = bulk
        return message
    }

    static let cases: [(MailMessage, MailCategory)] = [
        (mail("Jürg Meier <juerg.meier@gmail.com>", "Trainingsabrechnung September",
              "Hoi Ben, kannst du mir bis Freitag sagen, ob die Hallenmiete für September schon bezahlt ist? Danke, Jürg"), .primary),
        (mail("Digitec Galaxus <info@digitecgalaxus.ch>", "Deine Bestellung wurde versandt",
              "Bestellung 123456: Dein Paket ist unterwegs und kommt voraussichtlich morgen an. Sendungsnummer 99.00.123"), .updates),
        (mail("Zalando <news@zalando.ch>", "Bis zu 50% auf Herbstmode 🍂",
              "Entdecke die neuen Trends der Saison. Jetzt shoppen und sparen! Abmelden"), .newsletters),
        (mail("Customer Support <secure-alert@paypa1-verify.com>", "Your account has been suspended",
              "Dear customer, we detected unusual activity. Verify your password within 24 hours at http://paypa1-verify.com/login or your account will be closed."), .spam),
        (mail("Sandra Huber <praesidentin@vbc-example.ch>", "GV Traktanden",
              "Liebe Vorstandsmitglieder, im Anhang die Traktandenliste für die GV. Bitte gebt mir bis Sonntag Rückmeldung, ob ihr Ergänzungen habt. Liebe Grüsse, Sandra"), .primary),
        (mail("UBS <no-reply@ubs.com>", "Neue Kontobewegung",
              "Auf Ihrem Konto wurde eine Belastung von CHF 120.00 verbucht. Details finden Sie im E-Banking."), .updates),
    ]

    /// One test that loads and frees the model itself, so llama.cpp is shut down before the process exits.
    @Test func classifiesSampleMails() async throws {
        var correct = 0
        do {
            let model = try LocalModel(path: ProcessInfo.processInfo.environment["MYLBOX_MODEL"] ?? "")
            for (message, expected) in Self.cases {
                let start = Date()
                let triage = try await TriageService.triage(message, model: model)
                let ok = triage.category == expected
                if ok { correct += 1 }
                print("\(ok ? "OK  " : "MISS") [\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(message.subject) → \(triage.category) reply=\(triage.needsReply) “\(triage.summary)”")
            }
        }
        print("Score: \(correct)/\(Self.cases.count)")
        #expect(correct >= Self.cases.count - 1)
    }
}

@Suite struct ModelDownloadTests {
    @Test func downloadsAndVerifiesChecksum() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mylbox-home-\(UUID().uuidString)")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).gguf")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: source)
            unsetenv("MYLBOX_HOME")
        }
        setenv("MYLBOX_HOME", home.path, 1)
        try Data(repeating: 7, count: 300_000).write(to: source)
        let hash = try ModelDownloader.sha256(of: source)
        var info = LocalModelInfo(id: "test", name: "Test", detail: "", url: source, sha256: hash, size: 300_000)
        try await ModelDownloader(info) { _ in }.download()
        #expect(info.isDownloaded)

        info.sha256 = String(repeating: "0", count: 64)
        try FileManager.default.removeItem(at: info.fileURL)
        await #expect(throws: LocalModelError.self) { try await ModelDownloader(info) { _ in }.download() }
        #expect(!info.isDownloaded)
    }
}
