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
        // Personal mail that needs attention
        (mail("Jürg Meier <juerg.meier@gmail.com>", "Trainingsabrechnung September",
              "Hoi Ben, kannst du mir bis Freitag sagen, ob die Hallenmiete für September schon bezahlt ist? Danke, Jürg"), .primary),
        (mail("Sandra Huber <praesidentin@vbc-example.ch>", "GV Traktanden",
              "Liebe Vorstandsmitglieder, im Anhang die Traktandenliste für die GV. Bitte gebt mir bis Sonntag Rückmeldung, ob ihr Ergänzungen habt. Liebe Grüsse, Sandra"), .primary),
        (mail("Lea <lea.brunner@bluewin.ch>", "Samstag",
              "Hey! Chunsch am Samstag au a Geburi vo de Nina? Mir träffed üs am 19i bim Bahnhof. Säg Bscheid 😊"), .primary),
        (mail("Marc Dubois <m.dubois@ecole-example.ch>", "Remboursement du tournoi",
              "Bonjour Benjamin, notre équipe a payé deux fois l'inscription au tournoi. Pourriez-vous nous rembourser CHF 80.-? Merci d'avance, Marc"), .primary),
        (mail("Steueramt Kanton Zürich <steueramt@zh.ch>", "Mahnung: Steuererklärung 2025",
              "Sehr geehrter Herr Amhof, Ihre Steuererklärung 2025 ist noch nicht eingetroffen. Bitte reichen Sie diese bis 31. Oktober ein, sonst erfolgt eine Veranlagung nach Ermessen."), .primary),
        // Automated updates
        (mail("Digitec Galaxus <info@digitecgalaxus.ch>", "Deine Bestellung wurde versandt",
              "Bestellung 123456: Dein Paket ist unterwegs und kommt voraussichtlich morgen an. Sendungsnummer 99.00.123"), .updates),
        (mail("UBS <no-reply@ubs.com>", "Neue Kontobewegung",
              "Auf Ihrem Konto wurde eine Belastung von CHF 120.00 verbucht. Details finden Sie im E-Banking."), .updates),
        (mail("GitHub <notifications@github.com>", "[sudoBeni/mylbox] CI failed on main",
              "The workflow 'build' failed for commit 86eb5a0. View the run to see details."), .updates),
        (mail("Praxis Dr. Keller <termine@praxis-keller.ch>", "Terminbestätigung",
              "Ihr Termin am Dienstag, 14. Oktober um 09:30 ist bestätigt. Bitte melden Sie sich 10 Minuten früher am Empfang."), .updates),
        (mail("Swiss <noreply@swiss.com>", "Your boarding pass ZRH–LIS",
              "Check-in completed. Your boarding pass for LX 2084 on 12 Oct is attached. Gate closes 20 minutes before departure."), .updates),
        // Newsletters and marketing
        (mail("Zalando <news@zalando.ch>", "Bis zu 50% auf Herbstmode 🍂",
              "Entdecke die neuen Trends der Saison. Jetzt shoppen und sparen! Abmelden"), .newsletters),
        (mail("Swiss Volley <newsletter@volleyball.ch>", "Swiss Volley News Oktober",
              "Die Saison startet! Alle Infos zu den Meisterschaften, neue Schiedsrichterregeln und Highlights aus der Nationalmannschaft. Newsletter abbestellen", bulk: true), .newsletters),
        (mail("Notion <team@makenotion.com>", "What's new in Notion: AI meeting notes",
              "We shipped AI meeting notes, faster search and new templates. Read the changelog to learn more."), .newsletters),
        // Spam and phishing
        (mail("Customer Support <secure-alert@paypa1-verify.com>", "Your account has been suspended",
              "Dear customer, we detected unusual activity. Verify your password within 24 hours at http://paypa1-verify.com/login or your account will be closed."), .spam),
        (mail("Post CH <zustellung@post-ch-paket.info>", "Ihr Paket konnte nicht zugestellt werden",
              "Ihr Paket wartet. Bitte bezahlen Sie die Zollgebühr von CHF 1.99 unter post-ch-paket.info/zahlen, sonst wird es zurückgeschickt."), .spam),
        (mail("Dr. James Wilson <jwilson.fund@outlook.com>", "Urgent business proposal",
              "I am a lawyer representing a late client with USD 12.5 million unclaimed. You share his surname. Reply with your bank details to receive 40%."), .spam),
    ]

    /// One test that loads and frees the model itself, so llama.cpp is shut down before the process exits.
    @Test func classifiesSampleMails() async throws {
        var correct = 0
        do {
            let loadStart = Date()
            let model = try LocalModel(path: ProcessInfo.processInfo.environment["MYLBOX_MODEL"] ?? "")
            print("Loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")
            for (message, expected) in Self.cases {
                let start = Date()
                let triage = try await TriageService.triage(message, model: model)
                let ok = triage.category == expected
                if ok { correct += 1 }
                print("\(ok ? "OK  " : "MISS") [\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(message.subject) → \(triage.category) reply=\(triage.needsReply) “\(triage.summary)”")
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Score: \(correct)/\(Self.cases.count), peak memory \(usage.ru_maxrss / 1_048_576) MB")
        #expect(Double(correct) >= Double(Self.cases.count) * 0.8)
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
