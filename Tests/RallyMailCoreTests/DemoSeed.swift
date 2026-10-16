import Foundation
import Testing
@testable import RallyMailCore

/// Fills a data folder with example conversations, so the app can be looked at without a real account:
///   RALLYMAIL_SEED=/tmp/rallymail-demo swift test --filter DemoSeed
///   RALLYMAIL_HOME=/tmp/rallymail-demo swift run RallyMail
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RALLYMAIL_SEED"] != nil))
struct DemoSeed {
    @Test func seed() throws {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_SEED"]!, isDirectory: true)
        try? FileManager.default.removeItem(at: home)
        try Paths.ensure(home)
        let store = try MailStore(url: home.appendingPathComponent("rallymail.sqlite"))

        var account = Account(provider: .imap, name: "Benjamin Amhof", email: "ben@example.ch")
        account.imap = ServerEndpoint(host: "127.0.0.1", port: 1, security: .tls)
        account.smtp = ServerEndpoint(host: "127.0.0.1", port: 1, security: .tls)
        var config = AppConfig()
        config.accounts = [account]
        config.aiClassificationEnabled = false
        var finance = Space(name: "Volleyball Finance", symbol: "volleyball")
        finance.exportFolder = home.appendingPathComponent("vbc-finance/mail").path
        let taxes = Space(name: "Taxes 2025", symbol: "banknote")
        let homeSpace = Space(name: "Home", symbol: "house")
        config.spaces = [finance, taxes, homeSpace]
        try ConfigStore(url: home.appendingPathComponent("config.json")).save(config)

        let me = EmailAddress(name: "Benjamin Amhof", address: "ben@example.ch")
        let reto = EmailAddress(name: "Reto Kaufmann", address: "kasse@vbc.ch")
        let lea = EmailAddress(name: "Lea Brunner", address: "lea.brunner@gmx.ch")
        let jonas = EmailAddress(name: "Jonas Meier", address: "jonas@vbc.ch")
        let marco = EmailAddress(name: "Marco Steiner", address: "m.steiner@bluewin.ch")
        let sarah = EmailAddress(name: "Sarah Vogel", address: "sarah@slackers.dev")
        let tax = EmailAddress(name: "Steueramt Luzern", address: "steuern@stadtluzern.ch")
        let now = Date()
        var uid: UInt32 = 1

        @discardableResult
        func mail(_ from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], subject: String, text: String,
                  id: String, replyTo: String? = nil, refs: [String] = [], daysAgo: Double, hour: Int = 9,
                  sent: Bool = false, read: Bool? = nil, bulk: Bool = false,
                  attachments: [(String, Int)] = [], summary: String? = nil, topic: String? = nil, needsReply: Bool = false,
                  category: MailCategory? = nil) throws {
            var parsed = ParsedMail()
            parsed.messageID = id
            parsed.inReplyTo = replyTo ?? ""
            parsed.references = refs.joined(separator: " ")
            parsed.subject = subject
            parsed.from = from
            parsed.to = to
            parsed.cc = cc
            parsed.bcc = bcc
            parsed.text = text
            parsed.isBulk = bulk
            let day = Calendar.current.date(byAdding: .day, value: -Int(daysAgo), to: now)!
            parsed.date = Calendar.current.date(bySettingHour: hour, minute: Int(daysAgo * 7) % 60, second: 0, of: day)!
            parsed.attachments = attachments.map {
                MailAttachment(filename: $0.0, mimeType: "application/pdf", contentID: nil, isInline: false, data: Data(count: $0.1))
            }
            let incoming = IncomingMessage(accountID: account.id, folder: sent ? "Sent" : "INBOX", folderRole: sent ? .sent : .inbox,
                                           uid: uid, flags: (read ?? sent) ? ["\\Seen"] : [], parsed: parsed, rawPath: "")
            uid += 1
            guard let rowID = try store.insert(incoming) else { return }
            if summary != nil || needsReply {
                try store.setTriage(rowID, category: category, needsReply: needsReply, summary: summary, topic: topic)
            } else if let category {
                try store.setCategory(rowID, category, source: .ai)
            }
        }

        // Reto: a reply chain with an inline answer and a second attachment version.
        try mail(reto, to: [me], subject: "Jahresabrechnung 25/26 – bitte prüfen",
                 text: "Hoi Beni\n\n\n\nAnbei die Jahresabrechnung 25/26. Kannst du sie bis Freitag prüfen? Die GV ist am 20. Oktober.\n\nOffene Posten:\n1. Sponsoring Raiffeisen – Rechnung fehlt\n2. Schiri-Spesen Herbstturnier\n3. Hallenmiete Stadt Luzern CHF 4'200\n\n\n\nLiebe Grüsse\nReto\n\nReto Kaufmann | Kassier VBC Luzern\n079 123 45 67 | vbc.ch\n\nDiese E-Mail ist vertraulich und nur für den bezeichneten Empfänger bestimmt.\n\nVon meinem iPhone gesendet",
                 id: "<1@vbc.ch>", daysAgo: 2, hour: 9, read: true, attachments: [("Abrechnung_25-26.pdf", 1_200_000)],
                 summary: "Reto asks you to check the 25/26 season accounts by Friday", topic: "Jahresabrechnung", needsReply: true)
        try mail(me, to: [reto], cc: [lea], bcc: [jonas], subject: "Re: Jahresabrechnung 25/26 – bitte prüfen",
                 text: "Merci Reto, schaue ich mir diese Woche an.\n\nAm 07.10.2026 um 09:12 schrieb Reto Kaufmann <kasse@vbc.ch>:\n> Hoi Beni\n> Anbei die Jahresabrechnung 25/26.",
                 id: "<2@example.ch>", replyTo: "<1@vbc.ch>", refs: ["<1@vbc.ch>"], daysAgo: 2, hour: 11, sent: true)
        try mail(lea, to: [reto], cc: [me], subject: "AW: Jahresabrechnung 25/26 – bitte prüfen",
                 text: "Habe direkt in deiner Liste geantwortet, siehe unten.\n\nAm 07.10.2026 schrieb Reto Kaufmann <kasse@vbc.ch>:\n> Hoi Beni\n> Anbei die Jahresabrechnung 25/26. Kannst du sie bis Freitag prüfen? Die GV ist am 20. Oktober.\n>\n> Offene Posten:\n> 1. Sponsoring Raiffeisen – Rechnung fehlt\nRechnung ist bei mir, schicke sie Beni morgen. – Lea\n> 2. Schiri-Spesen Herbstturnier\n> 3. Hallenmiete Stadt Luzern CHF 4'800 (neuer Tarif ab Sept)\n>\n> Merci! Reto",
                 id: "<3@gmx.ch>", replyTo: "<1@vbc.ch>", refs: ["<1@vbc.ch>"], daysAgo: 1, hour: 21, read: true,
                 summary: "Lea answered inline: she has the Raiffeisen invoice, hall rent is now CHF 4'800", topic: "Jahresabrechnung")
        try mail(reto, to: [me], cc: [lea], subject: "Re: Jahresabrechnung 25/26 – bitte prüfen",
                 text: "Kurze Erinnerung – der Sponsoring-Posten fehlt noch. Neue Version mit Leas Korrektur anbei.\n\nStand jetzt:\nPosten          Betrag\nHallenmiete     4'800\nSchiri-Spesen     850\n\nLiebe Grüsse\nReto\n\nReto Kaufmann | Kassier VBC Luzern\n078 555 12 34 | vbc.ch\n\nAm 08.10.2026 schrieb Lea Brunner <lea.brunner@gmx.ch>:\n> Habe direkt in deiner Liste geantwortet, siehe unten.",
                 id: "<4@vbc.ch>", replyTo: "<3@gmx.ch>", refs: ["<1@vbc.ch>", "<3@gmx.ch>"], daysAgo: 0, hour: 8,
                 attachments: [("Abrechnung_25-26.pdf", 1_250_000)],
                 summary: "Reto reminds you about the sponsoring invoice and sends the corrected accounts", topic: "Sponsoring-Rechnung", needsReply: true)
        let retoThread = try #require(try store.message(1)).threadID
        try store.setSpace(thread: retoThread, space: finance.id)

        try mail(lea, to: [me], subject: "Re: Helfereinsatz Turnier",
                 text: "Hoi Beni, könntest du am Samstag den Schichtblock 13–16 Uhr an der Kasse übernehmen? Jonas fällt aus.",
                 id: "<5@gmx.ch>", daysAgo: 1, hour: 19,
                 summary: "Lea asks if you can take the 13–16 shift at the cash desk on Saturday", topic: "Kassendienst", needsReply: true)
        try mail(tax, to: [me], subject: "Rückfrage Steuererklärung 2025",
                 text: "Sehr geehrter Herr Amhof\nFür die Veranlagung 2025 fehlt der Beleg zu den Weiterbildungskosten (CHF 1'450). Bitte reichen Sie ihn bis 31. Oktober nach.\n\nFreundliche Grüsse\nSteueramt der Stadt Luzern",
                 id: "<6@stadtluzern.ch>", daysAgo: 1, hour: 10,
                 summary: "The tax office needs the receipt for CHF 1'450 training costs by 31 October", topic: "Weiterbildungskosten", needsReply: true)
        try store.setSpace(thread: "<6@stadtluzern.ch>", space: taxes.id)
        // Tasks: one the model found, with a sent mail that sounds like it is done.
        let review = try store.addTask(thread: "<1@vbc.ch>", text: "Jahresabrechnung bis Freitag prüfen", message: 0, date: now.addingTimeInterval(-2 * 86400))
        if let review { try store.suggestDone(review, by: 0) }
        try store.addTask(thread: "<1@vbc.ch>", text: "Sponsoring-Rechnung an Raiffeisen schicken", message: -1, date: now.addingTimeInterval(-86400))
        try mail(marco, to: [me], subject: "Heizungskontrolle",
                 text: "Hallo Benjamin\nDer Techniker hätte am Dienstag um 8 Uhr Zeit. Passt dir das? Dauert ca. 30 Minuten.\n\nGruss Marco\n\nVon meinem iPhone gesendet",
                 id: "<7@bluewin.ch>", daysAgo: 2, hour: 16,
                 summary: "Marco proposes Tuesday 8:00 for the heating check, about 30 minutes", topic: "Heizungskontrolle")
        try store.setSpace(thread: "<7@bluewin.ch>", space: homeSpace.id)
        try mail(sarah, to: [me], subject: "Onboarding flow – feedback?",
                 text: "Hey! Figma link below, would love your thoughts on the onboarding flow before Thursday's review.\nhttps://figma.com/file/abc\n\n-- \nSarah Vogel\nSlackers",
                 id: "<8@slackers.dev>", daysAgo: 2, hour: 14,
                 summary: "Sarah shares the Figma onboarding flow and would like your thoughts before Thursday", topic: "Onboarding-Flow")

        // Machine mail: folded into Updates and Newsletters.
        let machines: [(String, String, String, String, Double, MailCategory)] = [
            ("GitHub", "notifications@github.com", "[rallymail] CI failed on main", "swift test failed: 1 test", 0, .updates),
            ("Galaxus", "noreply@galaxus.ch", "Bestellung 48213 unterwegs", "Dein Paket kommt am Donnerstag.", 0, .updates),
            ("Twint", "noreply@twint.ch", "CHF 25.00 erhalten", "Lea Brunner hat dir CHF 25.00 gesendet.", 0, .updates),
            ("SBB", "noreply@sbb.ch", "Ihr Ticket Luzern–Zürich", "Fr 10. Okt, 07:35, Gleis 7.", 1, .updates),
            ("Swisscom", "noreply@swisscom.ch", "Rechnung Oktober", "CHF 64.00, fällig am 25. Oktober.", 2, .updates),
            ("Swiss Volley", "news@volleyball.ch", "Newsletter Oktober", "Nationalliga-Start und neue Schiri-Tarife.", 0, .newsletters),
            ("Swift Weekly Brief", "hello@swiftweekly.github.io", "Issue 214", "Strict concurrency, SwiftPM traits.", 2, .newsletters),
            ("Galaxus Deals", "deals@galaxus.ch", "Weekend Deals: bis 40% auf Home Office", "Nur bis Sonntag.", 3, .newsletters),
        ]
        for (index, machine) in machines.enumerated() {
            try mail(EmailAddress(name: machine.0, address: machine.1), to: [me], subject: machine.2, text: machine.3,
                     id: "<m\(index)@\(machine.1.split(separator: "@").last!)>", daysAgo: machine.4, hour: 7 + index,
                     bulk: machine.5 == .newsletters, summary: machine.3, category: machine.5)
        }

        // Several confirmations from the same sender: one chat, three topics.
        let tickets = EmailAddress(name: "Eventfrog", address: "bestellung@eventfrog.ch")
        let orders = [("Bestellbestätigung Beachturnier Luzern", "2 Tickets, Sa 18. Okt. Bestellnummer 88412.", 6.0),
                      ("Deine Tickets sind da", "Die Tickets für das Beachturnier Luzern findest du im Anhang.", 5.0),
                      ("Programmänderung Beachturnier", "Start neu um 10:00 statt 09:00. Deine Tickets bleiben gültig.", 0.0)]
        for (index, order) in orders.enumerated() {
            try mail(tickets, to: [me], subject: order.0, text: order.1, id: "<t\(index)@eventfrog.ch>", daysAgo: order.2,
                     hour: 12 + index, read: index < 2, attachments: index == 1 ? [("Tickets.pdf", 180_000)] : [], summary: order.1)
        }

        // Waiting for: a question to Jonas that got no answer.
        try mail(me, to: [jonas], subject: "Schiri-Rechnungen September",
                 text: "Hoi Jonas, kannst du mir die Schiri-Rechnungen vom September schicken? Merci!",
                 id: "<9@example.ch>", daysAgo: 4, hour: 18, sent: true)
        try store.setSpace(thread: "<9@example.ch>", space: finance.id)

        // Earlier: done conversations over the last two years.
        let topics = ["Training times after the autumn break", "Minutes of the board meeting", "Photos from the tournament",
                      "Can you check the hall booking?", "Dinner on Friday?", "Insurance question about the bike",
                      "Offer for the new kitchen", "Season tickets order", "Thanks for the help on Saturday",
                      "Flat inspection in November", "Your opinion on the new logo", "Budget 25/26"]
        let people = [reto, lea, jonas, marco, sarah]
        var seed = 11
        func random(_ n: Int) -> Int { seed = (seed * 48271) % 2147483647; return seed % n }
        for index in 0..<70 {
            let person = people[random(people.count)]
            let daysAgo = Double(5 + index * 10 + random(6))
            let id = "<old\(index)@\(person.address.split(separator: "@").last!)>"
            try mail(person, to: [me], subject: topics[random(topics.count)], text: "Hoi Beni, \(topics[random(topics.count)].lowercased()) – was meinst du?",
                     id: id, daysAgo: daysAgo, hour: 8 + random(10), read: true,
                     attachments: random(3) == 0 ? [("Protokoll.pdf", 300_000)] : [],
                     summary: "\(person.name.split(separator: " ").first!) about \(topics[random(topics.count)].lowercased())")
            try store.update(try #require(try store.message(Int64(uid - 1))).id, archived: true)
            if person.address.hasSuffix("vbc.ch") { try store.setSpace(thread: id, space: finance.id) }
        }
        #expect(try store.openCount() == 16) // 5 from people, 3 from Eventfrog, 8 folded
    }
}
