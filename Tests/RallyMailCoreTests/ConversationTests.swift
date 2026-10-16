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

    @Test func projectsLiveInsideTheirCourt() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Cheersfeed Logo", text: "Neu", id: "<c@x>", date: now)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Homepage", text: "Formular", id: "<h@x>", date: now)
        let slackers = UUID()
        let cheersfeed = UUID()
        // Rules only set a project while the topic is in the project's court.
        try fixture.store.setProjectIfNone(thread: "<c@x>", project: cheersfeed, space: slackers)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, project: cheersfeed)).isEmpty)
        try fixture.store.setSpace(thread: "<c@x>", space: slackers)
        try fixture.store.setSpace(thread: "<h@x>", space: slackers)
        try fixture.store.setProjectIfNone(thread: "<c@x>", project: cheersfeed, space: slackers)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, space: slackers, project: cheersfeed)).map(\.id) == ["<c@x>"])
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, space: slackers)).count == 2)
        // Setting the same court again keeps the project; another court drops it.
        try fixture.store.setSpace(thread: "<c@x>", space: slackers)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, project: cheersfeed)).count == 1)
        try fixture.store.setSpace(thread: "<c@x>", space: UUID())
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all, project: cheersfeed)).isEmpty)
    }

    @Test func mailSummarizedWithoutKeywordIsSortedAgain() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let old = try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Kassenschicht", text: "13-16?", id: "<a@gmx>", date: now)
        let new = try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "Prüfen", id: "<b@vbc>", date: now)
        try fixture.store.setTriage(old, category: .primary, needsReply: true, summary: "Lea fragt nach der Schicht")
        try fixture.store.setTriage(new, category: .primary, needsReply: true, summary: "Reto schickt die Abrechnung",
                                    topic: "Abrechnung")
        #expect(try fixture.store.pendingTriage(limit: 10).isEmpty)
        let reopened = try MailStore(url: fixture.url)
        #expect(try reopened.pendingTriage(limit: 10).map(\.id) == [old])
        let topic = try #require(try reopened.conversations(ConversationQuery(scope: .open)).first { $0.id == "<b@vbc>" })
        #expect(topic.keyword == "Abrechnung")
        #expect(topic.blurb == "Reto schickt die Abrechnung")
    }

    @Test func replyGoesAwayOnceTheUserWroteInTheTopic() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let ask = try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Kassenschicht", text: "13-16?", id: "<a@gmx>", date: now)
        try fixture.store.setTriage(ask, category: .primary, needsReply: true, summary: "Lea fragt nach der Schicht",
                                    topic: "Kassenschicht", ask: "Schicht 13–16 zusagen")
        var query = ConversationQuery(scope: .open)
        query.now = now
        let before = try #require(try fixture.store.conversations(query).first)
        #expect(before.needsReply && before.ask == "Schicht 13–16 zusagen")
        // Answered from the phone: the sent mail arrives with the next sync, nothing was archived.
        try fixture.add(from: fixture.me, to: [fixture.lea], subject: "Re: Kassenschicht", text: "Ja", id: "<b@me>",
                        inReplyTo: "<a@gmx>", date: now.addingTimeInterval(60), sent: true)
        let after = try #require(try fixture.store.conversations(ConversationQuery(scope: .all)).first { $0.id == before.id })
        #expect(!after.needsReply && after.ask == nil)
    }

    @Test func aReplyDoesNotFinishATask() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let papa = EmailAddress(name: "Thomas", address: "thomas@example.ch")
        let invoice = try fixture.add(from: papa, to: [fixture.me], subject: "Rechnung Domain", text: "Ist die für dich?", id: "<r@papa>",
                                      date: now)
        try fixture.store.addTask(thread: "<r@papa>", text: "Domain-Rechnung bezahlen", message: invoice, date: now)
        // The same task again, or from the same mail again: not twice.
        #expect(try fixture.store.addTask(thread: "<r@papa>", text: "domain-rechnung bezahlen", message: 99, date: now) == nil)
        let reply = try fixture.add(from: fixture.me, to: [papa], subject: "Re: Rechnung Domain", text: "Ja, ist für mich", id: "<r2@me>",
                                    inReplyTo: "<r@papa>", references: "<r@papa>", date: now.addingTimeInterval(60), sent: true)
        let me = fixture.me.address
        func topic() throws -> Matter {
            try #require(Matter.group(try fixture.store.conversations(ConversationQuery(scope: .all)), now: now) { $0.address == me }.first)
        }
        // Answered, but the invoice is still to pay: still the user's turn, and Thomas has the reply.
        #expect(try topic().ball == .mine)
        #expect(try topic().ask == "Domain-Rechnung bezahlen")
        #expect(try topic().waitingOn?.address == papa.address)
        let task = try #require(try topic().tasks.first)
        // A sent mail that sounds done only suggests it.
        try fixture.store.suggestDone(task.id, by: reply)
        #expect(try topic().tasks.first?.doneSuggestedBy == reply)
        try fixture.store.rejectDoneSuggestion(task.id)
        #expect(try topic().tasks.first?.doneSuggestedBy == nil)
        try fixture.store.completeTask(task.id)
        #expect(try topic().ball == .theirs)
    }

    @Test func ownTodosStayUntilTickedOff() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Kassenschicht", text: "Kannst du 13-16?", id: "<k@gmx>",
                        date: now.addingTimeInterval(-86400 * 10))
        try fixture.store.setTodo(thread: "<k@gmx>", note: "Lea zurückschreiben", now: now)
        // Updating the note keeps its place in the queue.
        try fixture.store.setTodo(thread: "<k@gmx>", note: "Lea wegen Schicht", now: now.addingTimeInterval(500))
        let todo = try #require(try fixture.store.conversations(ConversationQuery(scope: .todo)).first)
        #expect(todo.tasks.map(\.text) == ["Lea wegen Schicht"])
        #expect(todo.tasks.first?.created == now)
        // A sent mail no longer clears it.
        try fixture.add(from: fixture.me, to: [fixture.lea], subject: "Re: Kassenschicht", text: "Passt", id: "<k3@me>",
                        inReplyTo: "<k@gmx>", references: "<k@gmx>", date: now.addingTimeInterval(120), sent: true)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .todo)).count == 1)
        try fixture.store.clearTodo(thread: "<k@gmx>")
        #expect(try fixture.store.conversations(ConversationQuery(scope: .todo)).isEmpty)
    }

    @Test func taskAndReviewAnswersParse() throws {
        let triage = try TriageService.parse(#"{"summary":"x","topic":"t","sender":"company","category":"updates","ask":"","task":"Rechnung bezahlen."}"#, isBulk: false)
        #expect(triage.task == "Rechnung bezahlen")
        #expect(try TriageService.parse(#"{"summary":"x","topic":"t","category":"newsletters","ask":"","task":"Kaufen"}"#, isBulk: true).task == "")
        #expect(try TriageService.parseReview(#"{"task": "Keine", "done": [2, 7, 2]}"#, openCount: 2) == SentReview(task: "", done: [1]))
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

@Suite struct ChatTests {
    @Test func topicsWithTheSamePeopleFormOneChat() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "a", id: "<1@vbc>", date: base)
        try fixture.add(from: fixture.me, to: [fixture.reto], subject: "Turnier", text: "b", id: "<2@me>", date: base.addingTimeInterval(60), sent: true)
        try fixture.add(from: fixture.reto, to: [fixture.me], cc: [fixture.lea], subject: "GV", text: "c", id: "<3@vbc>",
                        date: base.addingTimeInterval(120))
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Helfer", text: "d", id: "<4@gmx>", date: base.addingTimeInterval(30))
        var query = ConversationQuery(scope: .all)
        query.now = base
        let me = fixture.me
        let chats = Chat.group(try fixture.store.conversations(query)) { $0.address == me.address }
        #expect(chats.map(\.id) == ["chat:kasse@vbc.ch,lea@gmx.ch", "chat:kasse@vbc.ch", "chat:lea@gmx.ch"])
        #expect(chats[1].topics.map(\.subject) == ["Turnier", "Abrechnung"])
        #expect(chats[0].people.first?.address == "kasse@vbc.ch")
        let messages = try fixture.store.messages(threads: chats[1].topics.map(\.id))
        #expect(messages.map(\.messageID) == ["<1@vbc>", "<2@me>"])
    }
}

@Suite struct MatterTests {
    @Test func conversationsFormTopicsWithTheBallWhereItIs() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let asked = try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Rechtsfall A24015827", text: "Vollmacht?", id: "<1@law>", date: base)
        try fixture.store.setTriage(asked, category: .primary, needsReply: true, summary: "Reto braucht die Vollmacht", ask: "Vollmacht schicken")
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "AW: A24015827 Formular", text: "Formular", id: "<2@law>", date: base.addingTimeInterval(60))
        try fixture.add(from: fixture.me, to: [fixture.lea], subject: "Turnier", text: "Kommst du?", id: "<3@me>", date: base.addingTimeInterval(120), sent: true)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Danke", text: "Merci", id: "<4@vbc>", date: base.addingTimeInterval(180))

        let topic = try fixture.store.createMatter(title: "Rechtsfall")
        try fixture.store.setMatter(threads: ["<1@law>", "<2@law>"], matter: topic)
        var query = ConversationQuery(scope: .all)
        query.now = base
        let me = fixture.me.address
        let matters = Matter.group(try fixture.store.conversations(query), now: base) { $0.address == me }
        #expect(matters.count == 3)
        let rechtsfall = try #require(matters.first { $0.id == topic })
        #expect(rechtsfall.title == "Rechtsfall")
        #expect(rechtsfall.threadIDs.sorted() == ["<1@law>", "<2@law>"])
        #expect(rechtsfall.ball == .mine && rechtsfall.ask == "Vollmacht schicken")
        let turnier = try #require(matters.first { $0.id == "<3@me>" })
        #expect(turnier.ball == .theirs && turnier.waitingOn?.address == fixture.lea.address)
        #expect(matters.first { $0.id == "<4@vbc>" }?.ball == .quiet)
        #expect(try fixture.store.threads(ofMatter: topic).sorted() == ["<1@law>", "<2@law>"])
        #expect(try fixture.store.threads(ofMatter: "<4@vbc>") == ["<4@vbc>"])
        #expect(try fixture.store.message(asked)?.matterKey == topic)
    }

    @Test func inboxListsReceivedMailNewestFirst() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "Bitte prüfen", id: "<1@vbc>", date: base)
        try fixture.add(from: fixture.me, to: [fixture.reto], subject: "Re: Abrechnung", text: "Ok", id: "<2@me>", inReplyTo: "<1@vbc>", date: base.addingTimeInterval(60), sent: true)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Helfer", text: "Kassendienst Samstag", id: "<3@gmx>", date: base.addingTimeInterval(120), flags: ["\\Seen"])
        #expect(try fixture.store.feed(FeedQuery()).map(\.messageID) == ["<3@gmx>", "<1@vbc>"])
        var unread = FeedQuery()
        unread.unreadOnly = true
        #expect(try fixture.store.feed(unread).map(\.messageID) == ["<1@vbc>"])
        var search = FeedQuery()
        search.search = "kassendienst"
        #expect(try fixture.store.feed(search).map(\.messageID) == ["<3@gmx>"])
        var from = FeedQuery()
        from.from = fixture.reto.address.lowercased()
        #expect(try fixture.store.feed(from).map(\.messageID) == ["<1@vbc>"])
    }

    @Test func aSharedReferenceSuggestsTheTopic() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Rechtsfall A24015827", text: "a", id: "<1@law>", date: base)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Vollmacht zu A24015827", text: "b", id: "<2@law>", date: base.addingTimeInterval(60))
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Turnier 2025", text: "c", id: "<3@gmx>", date: base.addingTimeInterval(120))
        try fixture.store.setSpace(thread: "<1@law>", space: UUID())
        var query = ConversationQuery(scope: .all)
        query.now = base
        let me = fixture.me.address
        let matters = Matter.group(try fixture.store.conversations(query), now: base) { $0.address == me }
        let suggestions = MatterSuggestions(matters)
        let loose = try #require(matters.first { $0.id == "<2@law>" })
        #expect(suggestions.suggest(for: loose)?.matter == "<1@law>")
        #expect(suggestions.suggest(for: loose)?.reference == "A24015827")
        #expect(suggestions.suggest(for: try #require(matters.first { $0.id == "<3@gmx>" })) == nil)
        #expect(MatterSuggestions.references("Bestellung 88412 vom 10.10.2025") == ["88412"])
    }
}

@Suite struct SortingTests {
    @Test func peopleWhoWriteTogetherFormOneProposedCourt() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let kasse = EmailAddress(name: "Kasse VBC", address: "kasse@vbc.ch")
        let anwalt = EmailAddress(name: "Nora Huber", address: "nora@kanzlei-huber.ch")
        let sekretariat = EmailAddress(name: "Sekretariat", address: "info@kanzlei-huber.ch")
        let once = EmailAddress(name: "Einmal", address: "einmal@gmail.com")
        // Volleyball: Reto and Lea write together, the club's treasurer joins them.
        try fixture.add(from: fixture.reto, to: [fixture.me], cc: [fixture.lea], subject: "Abrechnung", text: "a", id: "<1@v>", date: base)
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Kassendienst", text: "b", id: "<2@v>", date: base.addingTimeInterval(10))
        try fixture.add(from: kasse, to: [fixture.me], cc: [fixture.reto], subject: "Sponsoring", text: "c", id: "<3@v>", date: base.addingTimeInterval(20))
        // The lawyer's office: two addresses of one organisation, a shared case number.
        try fixture.add(from: anwalt, to: [fixture.me], subject: "Rechtsfall A24015827", text: "d", id: "<4@k>", date: base.addingTimeInterval(30))
        try fixture.add(from: sekretariat, to: [fixture.me], subject: "Vollmacht A24015827", text: "e", id: "<5@k>", date: base.addingTimeInterval(40))
        // Someone who wrote once fits no group.
        try fixture.add(from: once, to: [fixture.me], subject: "Hallo", text: "f", id: "<6@g>", date: base.addingTimeInterval(50))
        var query = ConversationQuery(scope: .all)
        query.now = base
        let me = fixture.me.address
        let (courts, rest) = SortingEngine.propose(try fixture.store.conversations(query), courts: []) { $0.address == me }
        #expect(courts.count == 2)
        #expect(rest == 1)
        let volleyball = try #require(courts.first { $0.threadIDs.contains("<1@v>") })
        #expect(Set(volleyball.threadIDs) == ["<1@v>", "<2@v>", "<3@v>"])
        let kanzlei = try #require(courts.first { $0.threadIDs.contains("<4@k>") })
        #expect(Set(kanzlei.threadIDs) == ["<4@k>", "<5@k>"])
        #expect(kanzlei.name == "Kanzlei-huber")
        #expect(kanzlei.topics.map(\.reference) == ["A24015827"])
        #expect(Set(kanzlei.topics[0].threadIDs) == ["<4@k>", "<5@k>"])
    }

    @Test func changesFromTheWishAreAppliedAreaByArea() {
        func court(_ name: String, _ threads: [String]) -> ProposedCourt {
            ProposedCourt(name: name, people: [], domains: [], threadIDs: threads, messageCount: threads.count, subjects: [],
                          keywords: [], topics: [], lastDate: .distantPast)
        }
        let courts = [court("A", ["1"]), court("B", ["2"]), court("C", ["3"]), court("D", ["4"])]
        let result = CourtNaming.apply([.rename("Volleyball"), .merge(into: 0), .drop, .keep], to: courts)
        #expect(result.map(\.name) == ["Volleyball", "C", "D"])
        #expect(result[0].threadIDs == ["1", "2"])
        #expect(result[1].include == false)
    }
}

@Suite struct CourtSuggestionTests {
    @Test func suggestsTheCourtUsedWithTheSamePeople() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let volleyball = UUID(), business = UUID(), graveyard = UUID()
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "a", id: "<1@vbc>", date: base)
        try fixture.add(from: fixture.reto, to: [fixture.me], cc: [fixture.lea], subject: "Offerte", text: "b", id: "<2@vbc>",
                        date: base.addingTimeInterval(60))
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Hallenmiete", text: "c", id: "<3@vbc>", date: base.addingTimeInterval(120))
        try fixture.add(from: fixture.reto, to: [fixture.me], cc: [fixture.lea], subject: "Rechnung", text: "d", id: "<4@vbc>",
                        date: base.addingTimeInterval(180))
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Alt", text: "e", id: "<5@gmx>", date: base.addingTimeInterval(240))
        try fixture.add(from: fixture.lea, to: [fixture.me], subject: "Neu", text: "f", id: "<6@gmx>", date: base.addingTimeInterval(300))
        try fixture.store.setSpace(thread: "<1@vbc>", space: volleyball)
        try fixture.store.setSpace(thread: "<2@vbc>", space: business)
        try fixture.store.setSpace(thread: "<5@gmx>", space: graveyard)
        var query = ConversationQuery(scope: .all)
        query.now = base
        let topics = try fixture.store.conversations(query)
        let me = fixture.me.address
        let suggestions = CourtSuggestions(history: topics, ignoring: [graveyard]) { $0.address == me }
        let topic = { (id: String) in topics.first { $0.id == id }! }
        // Reto alone was in Volleyball; Reto and Lea together in Business, which beats the single shared person.
        #expect(suggestions.suggest(for: topic("<3@vbc>")) == volleyball)
        #expect(suggestions.suggest(for: topic("<4@vbc>")) == business)
        // Lea's only sorted topic is in the Graveyard, which is never suggested.
        #expect(suggestions.suggest(for: topic("<6@gmx>")) == business)
    }
}

@Suite struct InfoSourceTests {
    @Test func oneWayMailIsGroupedBySenderAndCanBeMovedBack() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let github = EmailAddress(name: "GitHub", address: "Notifications@github.com")
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        try fixture.add(from: github, to: [fixture.me], subject: "CI failed", text: "a", id: "<1@gh>", date: base)
        try fixture.add(from: github, to: [fixture.me], subject: "PR merged", text: "b", id: "<2@gh>", date: base.addingTimeInterval(60))
        try fixture.add(from: fixture.reto, to: [fixture.me], subject: "Abrechnung", text: "c", id: "<3@vbc>", date: base)
        try fixture.store.setSenderCategory("notifications@GITHUB.com", .updates)
        let me = fixture.me
        let all = try fixture.store.conversations(ConversationQuery(scope: .all))
        let sources = InfoSource.group(all.filter(\.isFolded)) { $0.address == me.address }
        #expect(sources.map(\.id) == ["notifications@github.com"])
        #expect(sources.first?.items.map(\.subject) == ["PR merged", "CI failed"])
        #expect(sources.first?.unreadCount == 2)

        try fixture.store.setSenderCategory(github.address, .primary)
        #expect(try fixture.store.conversations(ConversationQuery(scope: .all)).filter(\.isFolded).isEmpty)
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

@Suite struct GeneratedLinesTests {
    @Test func cutsHeaderBlocksMailClientsAdd() {
        let outlook = "Passt so.\n\n*Von:* Reto <kasse@vbc.ch>\n*Gesendet:* Dienstag, 7. Oktober 2026 09:12\n*An:* Beni\n*Betreff:* Abrechnung\n\nHoi Beni"
        #expect(QuoteStripper.strip(outlook).text == "Passt so.")
        let wrapped = "Merci!\n\nCRC - Customer Service <service@crc.pt> schrieb am Di., 17.\nSept. 2024, 10:00:\n> Dear Benjamin"
        #expect(QuoteStripper.strip(wrapped).text == "Merci!")
        let dutch = "Thanks!\n\nOp 4 sep 2025 om 10:00 heeft Benjamin Amhof <ben@example.ch>\nhet volgende geschreven:\n\n> Hi"
        #expect(QuoteStripper.strip(dutch).text == "Thanks!")
        let separator = "Ok\n  _____  \nFrom: Lea\nSent: Monday\nhallo"
        #expect(QuoteStripper.strip(separator).text == "Ok")
        #expect(QuoteStripper.strip("Gruss\nBeni\n\nGet Outlook for iOS<https://aka.ms/o0ukef>").text == "Gruss\nBeni")
    }
}

@Suite struct HistoryEditsTests {
    let original = """
    Hoi Beni
    Offene Posten:
    1. Sponsoring Raiffeisen – Rechnung fehlt
    2. Schiri-Spesen Herbstturnier
    3. Hallenmiete Stadt Luzern CHF 4'200
    Merci! Reto
    """

    @Test func showsWhatSomeoneChangedInAnEarlierMessage() throws {
        let reply = """
        Habe direkt in deiner Liste geantwortet.

        Am 07.10.2026 schrieb Reto Kaufmann <kasse@vbc.ch>:
        > Hoi Beni
        > Offene Posten:
        > 1. Sponsoring Raiffeisen – Rechnung fehlt
        Rechnung ist bei mir. – Lea
        > 2. Schiri-Spesen Herbstturnier
        > 3. Hallenmiete Stadt Luzern CHF 4'800 (neuer Tarif)
        > Merci! Reto
        """
        let edits = HistoryEdits.find(texts: [original, "Habe direkt in deiner Liste geantwortet."], fullTexts: [original, reply],
                                      senders: ["reto", "lea"])
        let edit = try #require(edits[1].first)
        #expect(edit.message == 0)
        let pieces = edit.passages.flatMap { $0 }
        #expect(pieces.contains(.added("Rechnung ist bei mir. – Lea")))
        #expect(pieces.contains(.removed("4'200")))
        #expect(pieces.contains(.added("4'800 (neuer Tarif)")))

        // Bens answer quotes Lea's version: nothing new was changed, so nothing is shown again.
        let answer = "Merci Lea.\n\nAm 08.10.2026 schrieb Lea <lea@gmx.ch>:\n" + reply.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        let later = HistoryEdits.find(texts: [original, "Habe direkt in deiner Liste geantwortet.", "Merci Lea."],
                                      fullTexts: [original, reply, answer], senders: ["reto", "lea", "ben"])
        #expect(later[2].isEmpty)
    }

    @Test func rewrappedQuotesAndHeadersAreNotChanges() {
        let reply = """
        Passt, freigegeben.

        Von: Reto Kaufmann <kasse@vbc.ch<mailto:kasse@vbc.ch>>
        Gesendet: Dienstag, 7. Oktober 2026 09:12
        An: ben@example.ch<mailto:ben@example.ch>
        Betreff: Abrechnung

        Hoi Beni Offene Posten: 1. Sponsoring Raiffeisen – Rechnung
        fehlt 2. Schiri-Spesen Herbstturnier 3. Hallenmiete Stadt
        Luzern CHF 4'200 Merci! Reto
        """
        #expect(HistoryEdits.find(texts: [original, "Passt, freigegeben."], fullTexts: [original, reply], senders: ["reto", "ben"])[1].isEmpty)
        #expect(HistoryEdits.find(texts: [original, "Ganz was anderes."], fullTexts: [original, "Ganz was anderes."], senders: ["reto", "ben"])[1].isEmpty)
    }
}

@Suite struct LinkTextTests {
    @Test func collapsesLabelledAndWrappedLinks() {
        let text = "Privacy (https://d366tM04.eu1.hubspotlinks.com/Ctc/ZW+113/\nVX7MS_1xK02) and more"
        let url = URL(string: "https://d366tM04.eu1.hubspotlinks.com/Ctc/ZW+113/VX7MS_1xK02")!
        #expect(LinkText.segments(text) == [.text("Privacy"), .link(url, host: "d366tm04.eu1.hubspotlinks.com"), .text(" and more")])
    }

    @Test func bareLinksKeepSentencePunctuation() {
        let segments = LinkText.segments("See https://www.example.org/a. Or <http://x.ch/b>")
        #expect(segments == [.text("See "), .link(URL(string: "https://www.example.org/a")!, host: "example.org"),
                             .text(". Or "), .link(URL(string: "http://x.ch/b")!, host: "x.ch")])
    }

    @Test func ignoresOtherSchemes() {
        #expect(LinkText.segments("run javascript:alert(1) or file:///etc") == [.text("run javascript:alert(1) or file:///etc")])
    }
}

/// Mail that started fresh or came from the archive still lands in the right conversation, and never twice.
@Suite struct MergingTests {
    fileprivate func archived(_ fixture: Fixture, from: EmailAddress, to: [EmailAddress], subject: String, text: String = "x", id: String,
                  inReplyTo: String = "", uid: UInt32, date: Date, folder: String = "[Gmail]/All Mail",
                  gmailThread: String = "") throws -> Int64? {
        var parsed = ParsedMail()
        parsed.messageID = id
        parsed.inReplyTo = inReplyTo
        parsed.references = inReplyTo
        parsed.subject = subject
        parsed.from = from
        parsed.to = to
        parsed.text = text
        parsed.date = date
        return try fixture.store.insert(IncomingMessage(accountID: fixture.account, folder: folder, folderRole: .inbox, uid: uid,
                                                        flags: [], parsed: parsed, rawPath: "",
                                                        archived: folder != "INBOX", gmailThread: gmailThread))
    }

    @Test func aNewMailWithTheSameSubjectToTheSamePeopleJoins() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_735_600_000)
        let fabian = EmailAddress(name: "Fabian", address: "fabi@bluewin.ch")
        let work = EmailAddress(name: "Benjamin Amhof", address: "benjamin.amhof@schindler.com")
        try fixture.add(from: fixture.me, to: [fabian], subject: "Website", text: "a", id: "<1@me>", date: base, sent: true)
        try fixture.add(from: fixture.me, to: [fabian], subject: "Website", text: "b", id: "<2@me>", date: base.addingTimeInterval(86400), sent: true)
        // Too late (people get two weeks), or other people: a conversation of its own.
        try fixture.add(from: fixture.me, to: [fabian], subject: "Website", text: "c", id: "<3@me>", date: base.addingTimeInterval(20 * 86400), sent: true)
        try fixture.add(from: fixture.me, to: [fixture.lea], subject: "Website", text: "d", id: "<4@me>", date: base.addingTimeInterval(3600), sent: true)
        #expect(try fixture.store.messages(threads: ["<1@me>"]).map(\.messageID) == ["<1@me>", "<2@me>"])
        #expect(try fixture.store.messages(threads: ["<3@me>"]).count == 1)
        #expect(try fixture.store.messages(threads: ["<4@me>"]).count == 1)
        // Sent twice, once only in Bcc and once to the work address: one conversation.
        try fixture.add(from: fixture.me, to: [], subject: "Self-destruction", text: "", id: "<5@me>", date: base, sent: true)
        try fixture.add(from: fixture.me, to: [work], subject: "Self-destruction", text: "", id: "<6@me>", date: base.addingTimeInterval(21), sent: true)
        #expect(try fixture.store.messages(threads: ["<5@me>"]).count == 2)
    }

    @Test func bccOfOwnMailIsKept() throws {
        let raw = Data("From: Ben <ben@example.ch>\r\nTo: Reto <kasse@vbc.ch>\r\nBcc: Jonas <jonas@vbc.ch>\r\nSubject: Hi\r\nMessage-ID: <b@me>\r\n\r\nHallo".utf8)
        let parsed = MIME.parse(raw)
        #expect(parsed.bcc.map(\.address) == ["jonas@vbc.ch"])
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.insert(IncomingMessage(accountID: fixture.account, folder: "Sent", folderRole: .sent, uid: 1, flags: [],
                                                     parsed: parsed, rawPath: ""))
        #expect(try fixture.store.messages(threads: ["<b@me>"]).first?.bcc.map(\.address) == ["jonas@vbc.ch"])
    }

    @Test func picturesTheTextShowsAreNoAttachments() {
        let raw = """
        From: Ben <ben@example.ch>\r\nTo: j@club.nl\r\nSubject: Re: meetrainen\r\nContent-Type: multipart/related; boundary="b"\r\n\r\n\
        --b\r\nContent-Type: text/html\r\n\r\n<p>Groetjes</p><div class="gmail_quote"><img src="cid:ii_logo"></div>\r\n\
        --b\r\nContent-Type: image/png; name="image.png"\r\nContent-Disposition: attachment; filename="image.png"\r\n\
        Content-ID: <ii_logo>\r\nContent-Transfer-Encoding: base64\r\n\r\niVBORw0KGgo=\r\n--b--\r\n
        """
        #expect(MIME.parse(Data(raw.utf8)).attachments.map(\.isInline) == [true])
        // The same picture in the sender's own text is theirs: it stays.
        let own = raw.replacingOccurrences(of: "<p>Groetjes</p><div class=\"gmail_quote\"><img src=\"cid:ii_logo\"></div>",
                                           with: "<p>Groetjes <img src=\"cid:ii_logo\"></p>")
        #expect(MIME.parse(Data(own.utf8)).attachments.map(\.isInline) == [false])
    }

    @Test func dutchAttributionWrappedOntoTheQuoteIsCut() {
        let wrapped = "Groetjes,\nJeanette\n\nOp ma 21 sep 2026 om 18:29 schreef Benjamin Amhof <ben@example.ch\n>:\n\n> Beste Jeanette,"
        #expect(QuoteStripper.strip(wrapped).text == "Groetjes,\nJeanette")
        let split = "Kan dit kloppen?\n\nOp wo 23 sep 2026 om 10:27 schreef Jeanette Streekstra <\nj@club.nl>:\n\n> Beste"
        #expect(QuoteStripper.strip(split).text == "Kan dit kloppen?")
    }

    @Test func ownMailThatNeverWentOutIsADraft() {
        let draft = MIME.parse(Data("From: Ben <ben@example.ch>\r\nTo: info@yallo.ch\r\nSubject: Re: Confirmation\r\n\r\nHi, sorry".utf8))
        let sent = MIME.parse(Data("Received: from BeniYOGA (static-2a02)\r\nFrom: Ben <ben@example.ch>\r\nTo: a@b.ch\r\nSubject: Musig\r\n\r\nHoi".utf8))
        #expect(SyncEngine.isDraft(draft))
        #expect(!SyncEngine.isDraft(sent))
    }

    @Test func aCancelledBookingPointsToTheNewOne() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_753_400_000)
        let marco = EmailAddress(name: "Beachvolleycamps.ch", address: "m.bonaria@beachvolleycamps.ch")
        let academy = EmailAddress(name: "beach-volleyball.de-Academy", address: "camps@beach-volleyball.de")
        let bank = EmailAddress(name: "Bank", address: "info@bank.ch")
        try fixture.add(from: fixture.me, to: [marco], subject: "Anfrage Storno (Buchung #13978)", text: "Ist es möglich zu stornieren?",
                        id: "<s@me>", date: base, sent: true)
        try fixture.add(from: academy, to: [fixture.me], subject: "Beach-Camp Cervia 29.09.-03.10.2025 / Buchungsanfrage", text: "Danke",
                        id: "<c@academy>", date: base.addingTimeInterval(5 * 86400))
        try fixture.add(from: fixture.me, to: [academy], subject: "Re: Beach-Camp Cervia 29.09.-03.10.2025 / Buchungsanfrage", text: "Merci",
                        id: "<c2@me>", inReplyTo: "<c@academy>", references: "<c@academy>", date: base.addingTimeInterval(6 * 86400), sent: true)
        try fixture.add(from: bank, to: [fixture.me], subject: "Login bestätigt", text: "x", id: "<b1@bank>", date: base)
        try fixture.add(from: bank, to: [fixture.me], subject: "Login bestätigt erneut", text: "x", id: "<b2@bank>", date: base.addingTimeInterval(60))
        var query = ConversationQuery(scope: .all)
        query.now = base
        let me = fixture.me.address
        let matters = Matter.group(try fixture.store.conversations(query), now: base) { $0.address == me }
        let related = RelatedTopics(matters, answered: try fixture.store.threadsWithSentMail()) { $0.address == me }
        func topic(_ id: String) throws -> Matter { try #require(matters.first { $0.id == id }) }
        // "beach" and "camp" in "beachvolleycamps": the same theme, a few days apart.
        #expect(related.related(to: try topic("<s@me>")) == ["<c@academy>"])
        // Notifications from one sender the user never wrote to are not a theme.
        #expect(related.related(to: try topic("<b1@bank>")).isEmpty)
    }

    @Test func typosStillCountAsTheSameSubject() {
        #expect(MatterSuggestions.nearlySame("Website:)", "Websiite"))
        #expect(!MatterSuggestions.nearlySame("Website", "Webshop"))
        #expect(!MatterSuggestions.nearlySame("Info", "Infos"))
        #expect(MatterSuggestions.explain("=Fabian") == "Same person (Fabian), similar subject.")
    }

    @Test func gatewayTagsDoNotChangeTheSubject() {
        #expect(Threading.normalizedSubject("[External] Re: Verdecktes Schild: Busse 075920") == "Verdecktes Schild: Busse 075920")
        #expect(Threading.normalizedSubject("AW: [EXT] Re: Hallenmiete") == "Hallenmiete")
        #expect(!Threading.isReplySubject("[External] Neue Anfrage"))
        #expect(Threading.isReplySubject("[External] Re: Anfrage"))
    }

    @Test func archiveFillsInTheRepliesAndSkipsWhatIsKnown() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_722_000_000)
        let nicole = EmailAddress(name: "Nicole Gasser", address: "nicole.gasser@equans.com")
        try fixture.add(from: fixture.me, to: [nicole], subject: "Busse 075920", text: "Bitte prüfen", id: "<1@me>", date: base, sent: true)
        // All Mail holds the sent mail again: skipped.
        #expect(try archived(fixture, from: fixture.me, to: [nicole], subject: "Busse 075920", id: "<1@me>", uid: 1, date: base) == nil)
        // Her reply, archived before RallyMail existed: joins the conversation as done mail.
        let reply = try #require(try archived(fixture, from: nicole, to: [fixture.me], subject: "[External] Re: Busse 075920",
                                              id: "<2@equans>", inReplyTo: "<1@me>", uid: 2, date: base.addingTimeInterval(3600)))
        let thread = try fixture.store.messages(threads: ["<1@me>"])
        #expect(thread.map(\.messageID) == ["<1@me>", "<2@equans>"])
        #expect(thread.last?.isArchived == true)
        #expect(thread.last?.isRead == true)
        // Moved back to the inbox in Gmail: the same row moves, no second copy.
        #expect(try archived(fixture, from: nicole, to: [fixture.me], subject: "[External] Re: Busse 075920", id: "<2@equans>",
                             inReplyTo: "<1@me>", uid: 9, date: base.addingTimeInterval(3600), folder: "INBOX") == nil)
        let moved = try fixture.store.messages(threads: ["<1@me>"])
        #expect(moved.count == 2)
        #expect(moved.last?.id == reply && moved.last?.isArchived == false)
    }

    @Test func gmailConversationJoinsMailWithoutHeaders() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_722_000_000)
        _ = try archived(fixture, from: fixture.reto, to: [fixture.me], subject: "Hallenplan", id: "<a@vbc>", uid: 1, date: base,
                         gmailThread: "1801")
        _ = try archived(fixture, from: fixture.reto, to: [fixture.me], subject: "Neuer Plan", id: "<b@vbc>", uid: 2,
                         date: base.addingTimeInterval(60), gmailThread: "1801")
        #expect(try fixture.store.messages(threads: ["<a@vbc>"]).count == 2)
    }

    @Test func archiveProgressSurvivesEverySync() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.setUIDValidity(5, account: fixture.account, folder: "All")
        try fixture.store.setSeenUID(800, account: fixture.account, folder: "All")
        try fixture.store.setUIDValidity(5, account: fixture.account, folder: "All")
        #expect(try fixture.store.seenUID(account: fixture.account, folder: "All") == 800)
        try fixture.store.setUIDValidity(6, account: fixture.account, folder: "All")
        #expect(try fixture.store.seenUID(account: fixture.account, folder: "All") == 0)
        #expect(SyncEngine.messageID(Data("Message-ID:\r\n <x.1@mail.ch>\r\n\r\n".utf8)) == "<x.1@mail.ch>")
    }

    @Test func referencesInTheTextAndTheSameOrganisationSuggestTheTopic() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let nicole = EmailAddress(name: "Nicole Gasser", address: "nicole.gasser@equans.com")
        let desk = EmailAddress(name: "Parkdienst", address: "parkdienst@equans.com")
        try fixture.add(from: fixture.me, to: [desk], subject: "Verdecktes Schild: Busse", text: "Es geht um die Busse 075920.",
                        id: "<1@me>", date: base, sent: true)
        // A fresh mail, no headers, other subject, but the number in the text.
        try fixture.add(from: nicole, to: [fixture.me], subject: "Ihre Anfrage", text: "Zur Busse 075920: wir prüfen das.",
                        id: "<2@equans>", date: base.addingTimeInterval(86400))
        // Same organisation, similar subject, no number.
        try fixture.add(from: nicole, to: [fixture.me], subject: "Verdecktes Schild Busse Rückmeldung", text: "Wir verzichten.",
                        id: "<3@equans>", date: base.addingTimeInterval(2 * 86400))
        var query = ConversationQuery(scope: .all)
        query.now = base
        let me = fixture.me.address
        let matters = Matter.group(try fixture.store.conversations(query), now: base) { $0.address == me }
        let suggestions = MatterSuggestions(matters, references: try fixture.store.referenceTokens(),
                                            answered: try fixture.store.threadsWithSentMail()) { $0.address == me }
        func topic(_ id: String) throws -> Matter { try #require(matters.first { $0.id == id }) }
        let byNumber = suggestions.suggest(for: try topic("<2@equans>"))
        #expect(byNumber?.matter == "<1@me>" && byNumber?.reference == "075920")
        let byOrganisation = suggestions.suggest(for: try topic("<3@equans>"))
        #expect(byOrganisation?.matter == "<1@me>" && byOrganisation?.reference == "@equans.com")
        // The older topic does not point back at the newer ones.
        #expect(suggestions.suggest(for: try topic("<1@me>")) == nil)
        #expect(MatterSuggestions.explain("@equans.com") == "Both are with equans.com, with a similar subject.")
    }
}
