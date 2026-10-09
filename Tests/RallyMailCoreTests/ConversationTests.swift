import Foundation
import Testing
@testable import RallyMailCore

@Suite struct ThreadingTests {
    @Test func normalizesSubjects() {
        #expect(Threading.normalizedSubject("Re: AW: Jahresabrechnung") == "Jahresabrechnung")
        #expect(Threading.normalizedSubject("Fwd: Re[2]: Hallo") == "Hallo")
        #expect(Threading.normalizedSubject("  Plain ") == "Plain")
        #expect(Threading.isReplySubject("Re: x"))
        #expect(!Threading.isReplySubject("Rechnung"))
    }

    @Test func referencedIDs() {
        let ids = Threading.referencedIDs(references: "<a@x> <b@x>", inReplyTo: "<b@x>")
        #expect(ids == ["<a@x>", "<b@x>"])
        #expect(Threading.referencedIDs(references: "", inReplyTo: "garbage") == [])
    }
}

/// Builds a store with a few mails so the conversation queries can be checked.
private struct Fixture {
    let store: MailStore
    let url: URL
    let account = UUID()
    let me = EmailAddress(name: "Benjamin", address: "ben@example.ch")
    let reto = EmailAddress(name: "Reto Kaufmann", address: "kasse@vbc.ch")
    let lea = EmailAddress(name: "Lea Brunner", address: "lea@gmx.ch")
    var nextUID: UInt32 = 1

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("rallymail-\(UUID().uuidString).sqlite")
        store = try MailStore(url: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    mutating func add(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], subject: String, text: String,
                      id: String, inReplyTo: String = "", references: String = "", date: Date, sent: Bool = false,
                      flags: Set<String> = []) throws -> Int64 {
        var parsed = ParsedMail()
        parsed.messageID = id
        parsed.inReplyTo = inReplyTo
        parsed.references = references
        parsed.subject = subject
        parsed.from = from
        parsed.to = to
        parsed.cc = cc
        parsed.text = text
        parsed.date = date
        let incoming = IncomingMessage(accountID: account, folder: sent ? "Sent" : "INBOX", folderRole: sent ? .sent : .inbox,
                                       uid: nextUID, flags: flags, parsed: parsed, rawPath: "")
        nextUID += 1
        return try #require(try store.insert(incoming))
    }
}

@Suite struct ConversationStoreTests {
    @Test func threadsRepliesEvenWhenTheyArriveFirst() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        // Sync fetches newest first: the reply is inserted before the original.
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Re: Abrechnung", text: "Erinnerung", id: "<2@vbc>",
                        inReplyTo: "<1@vbc>", references: "<1@vbc>", date: base.addingTimeInterval(7200))
        try fixture.add(from: fixture.me, to: [fixture.reto], subject: "Re: Abrechnung", text: "Merci", id: "<m@me>",
                        inReplyTo: "<1@vbc>", references: "<1@vbc>", date: base.addingTimeInterval(3600), sent: true)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "Anbei", id: "<1@vbc>", date: base)
        // A web mailer that drops the headers but keeps the subject.
        try fixture.add(from: fixture.lea, to: [fixture.reto], cc: [fixture.me], subject: "AW: Abrechnung", text: "Inline",
                        id: "<3@gmx>", date: base.addingTimeInterval(9000))
        // Something unrelated.
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Turnier", text: "Samstag?", id: "<4@gmx>",
                        date: base.addingTimeInterval(100))

        let open = try fixture.store.conversations(ConversationQuery(scope: .open))
        #expect(open.count == 2)
        let thread = try #require(open.first { $0.subject == "Abrechnung" })
        #expect(thread.id == "<1@vbc>")
        #expect(thread.messageCount == 4)
        #expect(thread.participants.map(\.address).sorted() == ["ben@example.ch", "kasse@vbc.ch", "lea@gmx.ch"])
        #expect(thread.lastFrom.address == "lea@gmx.ch")
        #expect(try fixture.store.thread(thread.id).map(\.messageID) == ["<1@vbc>", "<m@me>", "<2@vbc>", "<3@gmx>"])
    }

    @Test func doneLaterAndEarlier() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let id = try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "Anbei", id: "<1@vbc>", date: now)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Turnier", text: "Samstag?", id: "<4@gmx>", date: now.addingTimeInterval(-86400 * 40))
        var query = ConversationQuery(scope: .open)
        query.now = now
        #expect(try fixture.store.conversations(query).count == 2)

        // Later hides until the date, then it is back.
        try fixture.store.snooze(thread: "<1@vbc>", until: now.addingTimeInterval(3600))
        #expect(try fixture.store.conversations(query).map(\.id) == ["<4@gmx>"])
        var earlier = ConversationQuery(scope: .earlier)
        earlier.now = now
        #expect(try fixture.store.conversations(earlier).map(\.id) == ["<1@vbc>"])
        query.now = now.addingTimeInterval(7200)
        #expect(try fixture.store.conversations(query).count == 2)

        // A new message in a snoozed conversation wakes it.
        try fixture.store.snooze(thread: "<1@vbc>", until: now.addingTimeInterval(3600))
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Re: Abrechnung", text: "Nachtrag", id: "<2@vbc>",
                        inReplyTo: "<1@vbc>", references: "<1@vbc>", date: now.addingTimeInterval(60))
        query.now = now
        #expect(try fixture.store.conversations(query).count == 2)

        // Done = archived; the conversation moves to Earlier and keeps its mail.
        try fixture.store.update(id, archived: true)
        try fixture.store.update(try #require(try fixture.store.thread("<1@vbc>").last?.id), archived: true)
        #expect(try fixture.store.conversations(query).map(\.id) == ["<4@gmx>"])
        #expect(try fixture.store.conversations(earlier).map(\.id) == ["<1@vbc>"])
        #expect(try fixture.store.thread("<1@vbc>").count == 2)
        #expect(try fixture.store.openCount(now: now) == 1)
    }

    @Test func waitingForAnAnswer() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.me, to: [fixture.lea], subject: "Schiri-Rechnungen", text: "Kannst du?", id: "<s@me>",
                        date: now.addingTimeInterval(-86400 * 5), sent: true)
        try fixture.add(from: fixture.me, to: [fixture.lea], subject: "Gestern", text: "Hoi", id: "<t@me>",
                        date: now.addingTimeInterval(-3600), sent: true)
        let waiting = try fixture.store.conversations(ConversationQuery(scope: .waiting(olderThan: now.addingTimeInterval(-86400 * 3))))
        #expect(waiting.map(\.id) == ["<s@me>"])
        try fixture.store.dismissWaiting(thread: "<s@me>")
        #expect(try fixture.store.conversations(ConversationQuery(scope: .waiting(olderThan: now.addingTimeInterval(-86400 * 3)))).isEmpty)
        // Once the other side answers, nothing is waiting anymore.
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Re: Gestern", text: "Hoi zurück", id: "<u@gmx>",
                        inReplyTo: "<t@me>", references: "<t@me>", date: now)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .waiting(olderThan: now.addingTimeInterval(60)))).isEmpty)
    }

    @Test func spacesFilterAndSearch() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "Raiffeisen Rechnung anbei", id: "<1@vbc>", date: now)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Turnier", text: "Samstag?", id: "<4@gmx>", date: now)
        let space = UUID()
        try fixture.store.setSpace(thread: "<1@vbc>", space: space)
        try fixture.store.setSpaceIfNone(thread: "<1@vbc>", space: UUID())
        #expect(try fixture.store.spaceOf(thread: "<1@vbc>") == space)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .open, space: space)).map(\.id) == ["<1@vbc>"])
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, search: "raiffeisen")).map(\.id) == ["<1@vbc>"])
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, space: space, search: "samstag")).isEmpty)
        #expect(try fixture.store.messageCount(space: space) == 1)
        #expect(try fixture.store.knownAddresses(matching: "reto").map(\.address) == ["kasse@vbc.ch"])
    }
}

@Suite struct QuoteStripperTests {
    @Test func stripsQuotesAndSignatures() {
        let body = """
        Merci Reto, schaue ich mir diese Woche an.

        Gruss
        Beni
        --
        Benjamin Amhof
        +41 79 000 00 00

        Am 07.10.2026 um 09:12 schrieb Reto Kaufmann <kasse@vbc.ch>:
        > Hoi Beni
        > Anbei die Jahresabrechnung.
        """
        let stripped = QuoteStripper.strip(body)
        #expect(stripped.text == "Merci Reto, schaue ich mir diese Woche an.\n\nGruss\nBeni")
        #expect(stripped.quoted?.hasPrefix("Am 07.10.2026") == true)
    }

    @Test func handlesOutlookHeaderBlocksAndInlineAnswers() {
        let body = """
        See my answers below.

        From: Lea Brunner <lea@gmx.ch>
        Sent: Mittwoch, 8. Oktober 2026 21:30
        To: Reto
        Subject: Abrechnung

        > 1. Sponsoring
        Rechnung ist bei mir.
        > 2. Hallenmiete
        Neu CHF 4'800.
        """
        let stripped = QuoteStripper.strip(body)
        #expect(stripped.text == "See my answers below.")
        #expect(stripped.inlineText == "Rechnung ist bei mir.\nNeu CHF 4'800.")

        let pureInline = QuoteStripper.strip("> Frage?\nAntwort.\n> Zweite Frage?\nZweite Antwort.")
        #expect(pureInline.text.isEmpty)
        #expect(pureInline.display == "Antwort.\nZweite Antwort.")
    }

    @Test func removesQuotedHTML() {
        let html = "<p>New</p><blockquote>old</blockquote><div class=\"gmail_quote\">On x wrote:<br>old</div>"
        #expect(HTMLText.plainText(QuoteStripper.removeQuotedHTML(html)) == "New")
    }
}

@Suite struct ReplyAnalyzerTests {
    let original = """
    Hoi Beni
    Offene Posten:
    1. Sponsoring Raiffeisen – Rechnung fehlt
    2. Schiri-Spesen Herbstturnier
    3. Hallenmiete Stadt Luzern CHF 4'200
    Merci! Reto
    """

    @Test func findsTopTextAndInlineChanges() throws {
        let reply = """
        Habe direkt in deiner Liste geantwortet.

        Am 07.10.2026 schrieb Reto Kaufmann <kasse@vbc.ch>:
        > Hoi Beni
        > Offene Posten:
        > 1. Sponsoring Raiffeisen – Rechnung fehlt
        Rechnung ist bei mir, schicke sie morgen. – Lea
        > 2. Schiri-Spesen Herbstturnier
        > 3. Hallenmiete Stadt Luzern CHF 4'800 (neuer Tarif)
        > Merci! Reto
        """
        let analysis = try #require(ReplyAnalyzer.analyze(reply: reply, previous: original))
        #expect(analysis.top == "Habe direkt in deiner Liste geantwortet.")
        #expect(analysis.hunks.count == 2)
        #expect(analysis.added == 2)
        #expect(analysis.removed == 1)
        #expect(analysis.hunks[0].ops.contains(.insert("Rechnung ist bei mir, schicke sie morgen. – Lea")))
        #expect(analysis.hunks[1].ops.contains(.delete("3. Hallenmiete Stadt Luzern CHF 4'200")))
    }

    @Test func plainReplyHasNoDiff() throws {
        let reply = "Passt, freigegeben.\n\nAm 07.10.2026 schrieb Reto:\n> Hoi Beni\n> Offene Posten:\n> 1. Sponsoring Raiffeisen – Rechnung fehlt"
        let analysis = try #require(ReplyAnalyzer.analyze(reply: reply, previous: original))
        #expect(analysis.top == "Passt, freigegeben.")
        #expect(!analysis.hasInlineChanges)
        #expect(ReplyAnalyzer.analyze(reply: "Ganz was anderes.", previous: original) == nil)
    }

    @Test func lineDiff() {
        let ops = TextDiff.diff(["a", "b", "c"], ["a", "x", "c", "d"])
        #expect(ops == [.equal("a"), .delete("b"), .insert("x"), .equal("c"), .insert("d")])
        #expect(TextDiff.key("> >  Hello ") == "hello")
    }
}
