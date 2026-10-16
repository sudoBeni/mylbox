import Foundation
import Testing
@testable import RallyMailCore

@Suite struct FormatterTests {
    /// Every formatted body keeps exactly the content of its source.
    func formatted(_ source: String) -> FormattedBody {
        let body = MessageFormatter.format(source)
        #expect(MessageFormatter.content(body) == MessageFormatter.content(source))
        return body
    }

    @Test func collapsesBlankLinesAndTrims() {
        let body = formatted("\n\n  Hallo zusammen  \n\n\n\n\nDas Turnier ist am Samstag.\u{200B}\n\n\n")
        #expect(body.blocks.map(\.text) == ["Hallo zusammen", "Das Turnier ist am Samstag."])
        #expect(body.blocks.map(\.role) == [.greeting, .paragraph])
    }

    @Test func lineBreaksTheSenderTypedStay() {
        let body = formatted("Adresse:\nSporthalle Tribschen\nTribschenstrasse 1\n6005 Luzern")
        #expect(body.blocks == [.init(role: .paragraph, text: "Adresse:\nSporthalle Tribschen\nTribschenstrasse 1\n6005 Luzern")])
    }

    @Test func hardWrappedLinesFlowAgain() {
        let source = """
        Die Abrechnung fuer die Saison ist jetzt im Ordner, bitte schaut sie
        euch bis Freitag an. Besonders die Hallenmiete ist hoeher als letztes
        Jahr, weil die Stadt die Tarife fuer Vereine angepasst hat und wir
        mehr Trainings hatten.

        Kurz:
        Danke
        """
        let body = formatted(source)
        #expect(body.blocks[0].text.contains("sie euch bis Freitag"))
        #expect(!body.blocks[0].text.contains("\n"))
        #expect(body.blocks[1].text == "Kurz:")
    }

    @Test func listsKeepTheirMarkers() {
        let body = formatted("Bitte bis Freitag prüfen:\n- Hallenmiete\n- Schiri-Spesen\n  inkl. Fahrt\n1. Sponsoring\n2. Getränke")
        #expect(body.blocks[0] == .init(role: .paragraph, text: "Bitte bis Freitag prüfen:"))
        #expect(body.blocks[1].role == .list)
        #expect(body.blocks[1].items == [.init(marker: "-", text: "Hallenmiete"), .init(marker: "-", text: "Schiri-Spesen inkl. Fahrt"),
                                         .init(marker: "1.", text: "Sponsoring"), .init(marker: "2.", text: "Getränke")])
        #expect(formatted("*Leeds, UK*\n22. Mai 2027\nTickets holen").blocks.map(\.role) == [.paragraph])
        #expect(formatted("Traktanden:\n1. Budget\n2. Turnier").blocks.map(\.role) == [.paragraph, .list])
    }

    @Test func signOffSignatureAndFooterFold() {
        let source = """
        Hoi Beni

        Die Abrechnung ist drin.

        Liebe Grüsse
        Reto
        --
        Reto Kaufmann | Kassier VBC Bern
        079 123 45 67 | vbc-bern.ch

        Diese E-Mail ist vertraulich und nur für den bezeichneten Empfänger bestimmt.

        Von meinem iPhone gesendet
        """
        let body = formatted(source)
        #expect(body.blocks.map(\.role) == [.greeting, .paragraph, .signOff, .signature, .disclaimer, .deviceFooter])
        #expect(body.text(of: .signOff) == "Liebe Grüsse Reto")
        #expect(body.text(of: .signature) == "--\nReto Kaufmann | Kassier VBC Bern\n079 123 45 67 | vbc-bern.ch")
        #expect(body.visible.map(\.role) == [.greeting, .paragraph, .signOff])
    }

    @Test func signatureWithoutDelimiterNeedsContactDetails() {
        let signed = formatted("Merci, schaue ich an.\n\nGruss\nBeni\n\nBenjamin Amhof\n+41 79 000 00 00")
        #expect(signed.blocks.map(\.role) == [.paragraph, .signOff, .signature])
        let postscript = formatted("Merci, schaue ich an.\n\nGruss\nBeni\n\nPS: Nimm bitte die Bälle mit, ich habe am Samstag keinen Platz im Auto.")
        #expect(postscript.blocks.map(\.role) == [.paragraph, .signOff, .paragraph])
        let team = formatted("Dein Zugang ist bereit.\n\nViele Grüsse\n\nDein RaiseNow Team")
        #expect(team.blocks.map(\.role) == [.paragraph, .signOff])
        #expect(team.text(of: .signOff) == "Viele Grüsse Dein RaiseNow Team")
        let wish = formatted("Merci für alles.\n\nThank you!\nHave a nice day,\nBeni")
        #expect(wish.visible.count == wish.blocks.count)
    }

    @Test func sentencesThatStartLikeASignOffStayText() {
        #expect(formatted("Danke für die Info, ich schaue es mir am Wochenende an.").blocks.map(\.role) == [.paragraph])
        #expect(formatted("Danke!").blocks.map(\.role) == [.paragraph])
        #expect(formatted("Passt so.\nDanke!").blocks.map(\.role) == [.paragraph, .signOff])
        #expect(formatted("Hoi Beni, passt!\nBis morgen").blocks.first?.role == .paragraph)
        #expect(formatted("Super Abend!\nVielen Dank 😊\nLeicht beschwipst ist gut😉").blocks.map(\.role) == [.paragraph])
    }

    @Test func bubbleSourceKeepsTheSignatureChatTextDrops() {
        let body = "Merci Reto.\n\nGruss\nBeni\n-- \nBenjamin Amhof\n\nAm 07.10.2026 um 09:12 schrieb Reto <kasse@vbc.ch>:\n> Hoi"
        let stripped = QuoteStripper.strip(body)
        #expect(stripped.text == "Merci Reto.\n\nGruss\nBeni")
        #expect(stripped.own.contains("Benjamin Amhof"))
        #expect(!stripped.own.contains("schrieb"))
    }
}

@Suite struct SenderSignatureTests {
    let mails = [
        "Hoi Beni\nDie Halle ist reserviert.\n\nLiebe Grüsse\nReto\n\nReto Kaufmann | Kassier VBC Luzern\n079 123 45 67 | vbc-luzern.ch",
        "Kannst du die Rechnung prüfen?\n\nReto Kaufmann | Kassier VBC Luzern\n079 123 45 67 | vbc-luzern.ch",
        "Merci!\nReto",
    ]

    @Test func learnsTheSignatureFromRepetition() {
        let signature = SenderSignature.learn(from: mails, name: "Reto Kaufmann")
        #expect(signature.known.isSuperset(of: ["Reto Kaufmann | Kassier VBC Luzern", "079 123 45 67 | vbc-luzern.ch"]))
        #expect(signature.latest == "Reto Kaufmann | Kassier VBC Luzern\n079 123 45 67 | vbc-luzern.ch")
        #expect(signature.card.title == "Kassier VBC Luzern")
        #expect(signature.card.phones == ["079 123 45 67"])
        #expect(signature.card.links.map { $0.host() } == ["vbc-luzern.ch"])

        // Without "-- " and without a sign-off, the learned lines still fold; the text stays.
        let body = MessageFormatter.format(mails[1], known: signature.known)
        #expect(body.blocks.map(\.role) == [.paragraph, .signature])
        // The sign-off and the name above the signature stay in the text.
        let first = MessageFormatter.format(mails[0], known: signature.known)
        #expect(first.blocks.map(\.role) == [.greeting, .paragraph, .signOff, .signature])
        #expect(first.text(of: .signOff) == "Liebe Grüsse Reto")
        // A new phone number inside the known signature folds with it; one above it stays text.
        let moved = MessageFormatter.format("Neue Nummer ab sofort.\nRuf an: 078 555 12 34\n\nReto Kaufmann | Kassier VBC Luzern\n078 555 12 34 | vbc-luzern.ch",
                                            known: signature.known)
        #expect(moved.blocks.map(\.role) == [.paragraph, .signature])
        #expect(moved.blocks[0].text.contains("Ruf an"))
    }

    @Test func sentencesThatRepeatAreNotSignatures() {
        let signature = SenderSignature.learn(from: ["Hallo\n\nAnbei die Rechnung.\nPeter Muster", "Hoi\n\nAnbei die Rechnung.\nPeter Muster"], name: "Peter Muster")
        #expect(!signature.known.contains("Anbei die Rechnung."))
        #expect(MessageFormatter.format("Anbei die Rechnung.\nPeter Muster", known: signature.known).blocks.map(\.role) == [.paragraph])
    }

    @Test func aNameAloneIsNoLearnedSignature() {
        let signature = SenderSignature.learn(from: ["Merci.\n\nliebe Grüsse\nConny", "Passt.\nConny"], name: "Cornelia Stadelmann")
        #expect(MessageFormatter.format("Ich schicke dir liebe Grüsse\nConny", known: signature.known).visible.count == 1)
    }

    @Test func titleSkipsNamesLabelsAndAddresses() {
        #expect(SignatureCard.read("Thomas Steimann\nVBC Äbike", name: "Tom Steimann").title == "VBC Äbike")
        #expect(SignatureCard.read("Click to Download\nTweet this", name: "Robin").title == nil)
        #expect(SignatureCard.read("x\nwww.handelszeitung.ch\nwww.valuesolutions.ch", name: "Bruno", address: "b@valuesolutions.ch")
            .links.first?.host() == "www.valuesolutions.ch")
        let card = SignatureCard.read("===\nThomas Steimann\nHofmattweg 1 · 6033 Buchrain\nMobile | +41 76 423 00 36", name: "Thomas Steimann")
        #expect(card.title == nil)
        #expect(card.phones == ["+41 76 423 00 36"])
        #expect(SignatureCard.read("Bruno Odermatt, dipl. Wirtschaftsprüfer/Partner", name: "Bruno Odermatt").title == "dipl. Wirtschaftsprüfer/Partner")
        #expect(SignatureCard.read("Beni\nVBC Ebikon - Finanzen", name: "Benjamin Amhof").title == "VBC Ebikon")
    }

    @Test func tablesKeepTheirColumns() {
        let intro = MessageFormatter.format("Stand jetzt:\nPosten        Betrag\nHalle         4'200")
        #expect(intro.blocks.map(\.role) == [.paragraph, .table])
        let body = MessageFormatter.format("Stand Oktober:\n\nPosten        Betrag\nHalle         4'200\nSchiri          850")
        #expect(body.blocks.map(\.role) == [.paragraph, .table])
        #expect(body.blocks[1].text == "Posten        Betrag\nHalle         4'200\nSchiri          850")
    }
}

/// Checks the formatter against every mail in a database copy and prints what it found:
///   RALLYMAIL_AUDIT=/path/to/rallymail.sqlite swift test --filter FormatterAudit
/// RALLYMAIL_AUDIT_DUMP=/path.txt also writes every formatted body with its roles, to read through.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"] != nil))
struct FormatterAudit {
    @Test func everyMailKeepsItsContent() throws {
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let messages = try store.messages(.all, limit: 1_000_000)
        // Signatures are learned per sender from their newest mails, as the app does.
        var signatures: [String: SenderSignature] = [:]
        var cards = ""
        for (address, mails) in Dictionary(grouping: messages, by: { $0.from.address.lowercased() }) {
            let newest = mails.sorted { $0.date > $1.date }.prefix(15)
            let signature = SenderSignature.learn(from: newest.map(\.bubbleSource), name: newest.first?.from.name ?? "", address: address)
            signatures[address] = signature
            if !signature.card.isEmpty {
                cards += "\(newest.first?.from.name ?? address): \(signature.card.title ?? "–") · \(signature.card.phones.joined(separator: ", ")) · \(signature.card.links.compactMap { $0.host() }.joined(separator: ", "))\n"
            }
        }
        var counts: [FormattedBody.Role: Int] = [:]
        var failures = 0
        var dump = ""
        for message in messages {
            let source = message.bubbleSource
            let body = MessageFormatter.format(source, known: signatures[message.from.address.lowercased()]?.known ?? [])
            dump += "=== \(message.from.address) · \(message.subject)\n"
            for block in body.blocks {
                dump += "[\(block.role.rawValue)] " + (block.role == .list ? block.items.map { "\($0.marker) \($0.text)" }.joined(separator: "\n") : block.text) + "\n"
            }
            for role in Set(body.blocks.map(\.role)) { counts[role, default: 0] += 1 }
            if MessageFormatter.content(body) != MessageFormatter.content(source) {
                failures += 1
                if failures <= 5 { print("CONTENT CHANGED: \(message.subject)") }
            }
        }
        if let path = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_DUMP"] {
            try dump.write(toFile: path, atomically: true, encoding: .utf8)
            try cards.write(toFile: path + ".cards.txt", atomically: true, encoding: .utf8)
        }
        print("audited \(messages.count) mails, \(failures) changed")
        for role in FormattedBody.Role.allCases { print("  \(role.rawValue): \(counts[role] ?? 0)") }
        #expect(failures == 0)
    }
}

/// Prints which topics would be suggested to join which, on a database copy:
///   RALLYMAIL_AUDIT=/path/to/rallymail.sqlite swift test --filter SuggestionAudit
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"] != nil))
struct SuggestionAudit {
    @Test func listSuggestions() throws {
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let own = Set(try store.messages(.sent, limit: 100_000).map { $0.from.address.lowercased() })
        let isMe: (EmailAddress) -> Bool = { own.contains($0.address.lowercased()) }
        var query = ConversationQuery(scope: .all)
        query.limit = 100_000
        let matters = Matter.group(try store.conversations(query), isMe: isMe)
        let suggestions = MatterSuggestions(matters, references: try store.referenceTokens(),
                                            answered: try store.threadsWithSentMail(), isMe: isMe)
        let titles = Dictionary(matters.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var count = 0
        for matter in matters where matter.spaceID == nil && !matter.isFolded {
            guard let found = suggestions.suggest(for: matter) else { continue }
            count += 1
            print("SUGGEST\(found.certain ? "-CERTAIN" : "") \(matter.title.prefix(50))  →  \(titles[found.matter]?.prefix(50) ?? "?")  [\(found.reference)]")
        }
        print("topics \(matters.count), suggestions \(count)")
        if let probe = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_PROBE"] {
            for matter in matters where matter.title.localizedCaseInsensitiveContains(probe) {
                print("PROBE \(matter.title) court=\(matter.spaceID != nil) folded=\(matter.isFolded) categories=\(matter.conversations.map { $0.category?.rawValue ?? "-" }) people=\(matter.people(isMe: isMe).map(\.address))")
            }
        }
    }
}

/// Prints which topics would point at which as related, on a database copy:
///   RALLYMAIL_AUDIT=/path/to/rallymail.sqlite swift test --filter RelatedAudit
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"] != nil))
struct RelatedAudit {
    @Test func listRelated() throws {
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let own = Set(try store.messages(.sent, limit: 100_000).map { $0.from.address.lowercased() })
        let isMe: (EmailAddress) -> Bool = { own.contains($0.address.lowercased()) }
        var query = ConversationQuery(scope: .all)
        query.limit = 100_000
        let matters = Matter.group(try store.conversations(query), isMe: isMe)
        let related = RelatedTopics(matters, answered: try store.threadsWithSentMail(), isMe: isMe)
        let titles = Dictionary(matters.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var count = 0
        for matter in matters {
            let found = related.related(to: matter)
            if found.isEmpty { continue }
            count += 1
            print("RELATED \(matter.title.prefix(45))  →  \(found.compactMap { titles[$0]?.prefix(35) }.joined(separator: " | "))")
        }
        print("topics \(matters.count), with related \(count)")
        if let probe = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_PROBE"] {
            for matter in matters where matter.title.localizedCaseInsensitiveContains(probe) {
                print("PROBE \(matter.title) wrote=\(related.wrote.contains(matter.id)) span=\(related.spans[matter.id].map { "\($0)" } ?? "-") words=\(related.themes[matter.id]?.sorted() ?? [])")
            }
        }
    }
}
