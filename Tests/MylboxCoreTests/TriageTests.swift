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
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MYLBOX_MODEL"] != nil), .serialized)
struct LocalModelTests {
    static let model = try! LocalModel(path: ProcessInfo.processInfo.environment["MYLBOX_MODEL"] ?? "")

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
        (mail("Digitec Galaxus <no-reply@digitecgalaxus.ch>", "Deine Bestellung wurde versandt",
              "Bestellung 123456: Dein Paket ist unterwegs und kommt voraussichtlich morgen an. Sendungsnummer 99.00.123"), .updates),
        (mail("Zalando <news@zalando.ch>", "Bis zu 50% auf Herbstmode 🍂",
              "Entdecke die neuen Trends der Saison. Jetzt shoppen und sparen! Abmelden", bulk: true), .newsletters),
        (mail("Customer Support <secure-alert@paypa1-verify.com>", "Your account has been suspended",
              "Dear customer, we detected unusual activity. Verify your password within 24 hours at http://paypa1-verify.com/login or your account will be closed."), .spam),
    ]

    @Test(arguments: 0..<cases.count)
    func classifiesSampleMails(index: Int) async throws {
        let (message, expected) = Self.cases[index]
        let start = Date()
        let triage = try await TriageService.triage(message, model: Self.model)
        print("[\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(message.subject) → \(triage.category) reply=\(triage.needsReply) “\(triage.summary)”")
        #expect(triage.category == expected)
        #expect(!triage.summary.isEmpty)
    }
}
