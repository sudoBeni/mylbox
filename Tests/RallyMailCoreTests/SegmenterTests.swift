import Foundation
import Testing
@testable import RallyMailCore

/// Real shapes of mail, as the programs of the user's correspondents write them.
@Suite struct SegmenterTests {
    @Test func gmxForwardWithSentFirst() throws {
        let text = """
        Gesendet: Donnerstag, 7. Mai 2026 um 20:22
        \r
        Von: "Alwin de Wit" <a.dewit@fysioholland.nl>
        \r
        An: "Leonie Odermatt" <leonie.odermatt@gmx.ch>
        \r
        Betreff: Fwd: Nieuw stageovereenkomst
        \r

        Beste Leonie,

        Goed nieuws! Tom heeft de overeenkomst doorgestuurd.

        Met vriendelijke groet,
        Alwin
        """
        let body = MailSegmenter.segment(text: text, html: nil, subject: "Fw: Fwd: Nieuw stageovereenkomst")
        #expect(body.text.isEmpty)
        let header = try #require(body.header)
        #expect(header.isForward)
        #expect(header.from?.address == "a.dewit@fysioholland.nl")
        #expect(header.from?.name == "Alwin de Wit")
        #expect(header.subject == "Fwd: Nieuw stageovereenkomst")
        #expect(header.to.map(\.address) == ["leonie.odermatt@gmx.ch"])
        let date = try #require(header.date)
        #expect(Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date) == DateComponents(year: 2026, month: 5, day: 7, hour: 20, minute: 22))
        #expect(body.forwarded == "Beste Leonie,\n\nGoed nieuws! Tom heeft de overeenkomst doorgestuurd.\n\nMet vriendelijke groet,\nAlwin")
    }

    @Test func gmxReplyKeepsOwnTextAndCutsTheHeader() {
        let text = """
        Hallo Sven

        Seit dem Wochenende haben wir wieder rostiges Wasser.

        Gruss
        Joel


        Gesendet: Dienstag, 30. April 2024 um 08:38 Uhr
        Von: "Janssen Sven" <Sven.Janssen@wincasa.ch>
        An: "Joel Egger" <egger.joel@gmx.ch>
        Betreff: AW: DRINGEND

        Liebe Beide
        """
        let body = MailSegmenter.segment(text: text, html: nil, subject: "Aw: AW: DRINGEND")
        #expect(body.text == "Hallo Sven\n\nSeit dem Wochenende haben wir wieder rostiges Wasser.\n\nGruss\nJoel")
        #expect(body.header?.isForward == false)
        #expect(body.header?.from?.address == "Sven.Janssen@wincasa.ch")
        #expect(body.quotedBody == "Liebe Beide")
    }

    @Test func samsungReplyHtmlBeatsItsCollapsedTextPart() {
        let text = "Von meinem Smartphone gesendet.\n-------- Ursprüngliche Nachricht --------Von: \"thomas.amhof\" <thomas.amhof@bluewin.ch> Datum: 23.09.26  21:01  (GMT+01:00) An: Benjamin Amhof <benjamin.amhof@gmail.com> Betreff: Brief aus Frankreich Hallo BeniDa ist wieder ein Brief gekommen. Gruss Papa"
        let html = """
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body dir="auto"><div><br></div>
        <div id="composer_signature"><div style="font-size:85%;color:#575757">Von meinem Smartphone gesendet.</div></div><div><br></div>
        <div align="left" dir="auto"><div>-------- Ursprüngliche Nachricht --------</div><div>Von: "thomas.amhof" &lt;thomas.amhof@bluewin.ch&gt; </div>
        <div>Datum: 23.09.26  21:01  (GMT+01:00) </div><div>An: Benjamin Amhof &lt;benjamin.amhof@gmail.com&gt; </div><div>Betreff: Brief aus Frankreich </div><div><br></div></div>
        <div dir="auto">Hallo Beni</div><div dir="auto"><br></div><div dir="auto">Da ist wieder ein Brief gekommen.&nbsp;</div><div dir="auto">Gruss Papa&nbsp;</div></body></html>
        """
        let body = MailSegmenter.segment(text: text, html: html, subject: "RE: Brief aus Frankreich")
        #expect(body.text.isEmpty)
        #expect(body.signatureLines == ["Von meinem Smartphone gesendet."])
        #expect(body.header?.from?.address == "thomas.amhof@bluewin.ch")
        #expect(body.header?.subject == "Brief aus Frankreich")
        #expect(body.quotedBody == "Hallo Beni\n\nDa ist wieder ein Brief gekommen.\nGruss Papa")
    }

    @Test func outlookDesktopHeaderDivStartsTheQuote() {
        let html = """
        <html><body><div class=WordSection1><p class=MsoNormal>Hi Victor,<o:p></o:p></p><p class=MsoNormal><o:p>&nbsp;</o:p></p>
        <p class=MsoNormal>Passt so.</p><p class=MsoNormal>Gruss Beni</p>
        <div><div style='border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0cm 0cm 0cm'><p class=MsoNormal><b>Van:</b> Benjamin Amhof &lt;benjamin.amhof@gmail.com&gt; <br><b>Verzonden:</b> Thursday, 24 September 2026 11:12<br><b>Aan:</b> victor@hubbzoffices.com<br><b>Onderwerp:</b> AW: Start your free trial week<o:p></o:p></p></div></div>
        <p class=MsoNormal>Hoi Victor, danke.</p></div></body></html>
        """
        let body = MailSegmenter.segment(text: nil, html: html, subject: "RE: Start your free trial week")
        #expect(body.text == "Hi Victor,\n\nPasst so.\n\nGruss Beni")
        #expect(body.header?.from?.address == "benjamin.amhof@gmail.com")
        #expect(body.header?.isForward == false)
        #expect(body.quotedBody == "Hoi Victor, danke.")
    }

    @Test func gmailAttributionNamesTheQuotedAuthor() throws {
        let text = """
        Zahlung wurde soeben ausgelöst.

        Lg Beni

        Zemp Robin <robin.zemp@asvz.ch> schrieb am Mi. 14. Okt. 2026 um 21:11:

        > Ciao Benjamin
        >
        > Bitte bezahlen und bestätigung an mich.
        """
        let body = MailSegmenter.segment(text: text, html: nil, subject: "Re: Rechnung")
        #expect(body.text == "Zahlung wurde soeben ausgelöst.\n\nLg Beni")
        let header = try #require(body.header)
        #expect(header.from == EmailAddress(name: "Zemp Robin", address: "robin.zemp@asvz.ch"))
        #expect(header.date.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
                == DateComponents(year: 2026, month: 10, day: 14, hour: 21, minute: 11))
        #expect(body.quotedBody == "Ciao Benjamin\n\nBitte bezahlen und bestätigung an mich.")

        let english = MailSegmenter.segment(text: "Perfekt danke!\n\nOn 15 Oct 2026, at 09:39, Benjamin Amhof <benjamin.amhof@gmail.com> wrote:\n\n> Guete Morge", html: nil)
        #expect(english.header?.from?.name == "Benjamin Amhof")
        #expect(english.header?.date.map { Calendar.current.component(.day, from: $0) } == 15)
    }

    @Test func appleMailForwardInsideBlockquote() throws {
        let html = """
        <html><body>Liebe Claudia - ist unterwegs.<br><div><br><blockquote type="cite"><div>Begin forwarded message:</div><br>
        <div><span><b>From: </b></span><span>Benjamin Amhof &lt;benjamin.amhof@gmail.com&gt;<br></span></div>
        <div><span><b>Subject: </b></span><span><b>Last but not least</b><br></span></div>
        <div><span><b>Date: </b></span><span>15 October 2026 at 09:39:00 CEST<br></span></div>
        <div><span><b>To: </b></span><span>Claudia &lt;c@x.ch&gt;<br></span></div><br>
        <div>Hoi Claudia, anbei die Unterlagen.</div></blockquote></div></body></html>
        """
        let body = MailSegmenter.segment(text: nil, html: html, subject: "Fwd: Last but not least")
        #expect(body.text == "Liebe Claudia - ist unterwegs.")
        let header = try #require(body.header)
        #expect(header.isForward)
        #expect(header.from?.address == "benjamin.amhof@gmail.com")
        #expect(header.subject == "Last but not least")
        #expect(body.forwarded == "Hoi Claudia, anbei die Unterlagen.")
    }

    @Test func aSentenceWithGeschriebenIsNotAnAttribution() {
        #expect(!MailSegmenter.isGenerated("Der Satz zum Ersatzrevisor müsste doch unter Punkt 5 geschrieben werden, nicht?"))
        #expect(!MailSegmenter.isGenerated("Datum: Donnerstag, 13. März 2025"))
        #expect(MailSegmenter.isGenerated("Am 07.10.2026 um 09:12 schrieb Reto Kaufmann <kasse@vbc.ch>:"))
        #expect(MailSegmenter.isGenerated("Gesendet: Freitag, 26. April 2024 um 11:48 Uhr"))
        // A date and place block in a person's text is no mail header.
        let text = "Hiermit bestätige ich den Termin:\n\nDatum: Donnerstag, 13. März 2025\nUhrzeit: 09.45 Uhr\nOrt: Krongasse 2, 6003 Luzern\n\nWir freuen uns."
        #expect(MailSegmenter.segment(text: text, html: nil).text == text)
    }

    @Test func flowedTextJoinsSoftBreaks() {
        let flowed = "Hallo Reto, das ist ein langer \nSatz der weitergeht.\nNeue Zeile.\n-- \nBeni\n> zitiert \n> weiter\n"
        #expect(MIME.unflow(flowed, deleteSpace: false) == "Hallo Reto, das ist ein langer Satz der weitergeht.\nNeue Zeile.\n-- \nBeni\n> zitiert weiter\n")
        #expect(MIME.unflow("a \nb", deleteSpace: true) == "ab")
    }

    @Test func headerDatesInSeveralLanguages() {
        func ymd(_ text: String) -> DateComponents? {
            HeaderDate.parse(text).map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        }
        #expect(ymd("Donnerstag, 7. Mai 2026 um 20:22") == DateComponents(year: 2026, month: 5, day: 7, hour: 20, minute: 22))
        #expect(ymd("Tuesday, 13 October 2026 at 15:10") == DateComponents(year: 2026, month: 10, day: 13, hour: 15, minute: 10))
        #expect(ymd("Oct 7, 2026, 9:12 PM") == DateComponents(year: 2026, month: 10, day: 7, hour: 21, minute: 12))
        #expect(ymd("23.09.26 21:01 (GMT+01:00)") == DateComponents(year: 2026, month: 9, day: 23, hour: 21, minute: 1))
        #expect(ymd("Di. 11. Nov. 2025 um 20:22") == DateComponents(year: 2025, month: 11, day: 11, hour: 20, minute: 22))
        #expect(ymd("Op ma 7 sep 2026 om 19:42 schreef") == DateComponents(year: 2026, month: 9, day: 7, hour: 19, minute: 42))
        #expect(ymd("le 3 juil. 2025 à 10:00") == DateComponents(year: 2025, month: 7, day: 3, hour: 10, minute: 0))
        #expect(ymd("nothing here") == nil)
    }

    @Test func htmlReaderKeepsStructure() {
        let html = """
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"><style>p{}</style></head><body>
        <div>Grüezi Léa,<br>zweite Zeile</div><p>Absatz mit <b>fett</b> und <a href="https://x.ch/a">Link</a>.</p>
        <ul><li>eins</li><li>zwei</li></ul><ol><li>erstens</li></ol>
        <table><tr><td>Hallenmiete</td><td>4'800</td></tr></table>
        <div id="Signature"><p>Beni<br>079 000 00 00</p></div></body></html>
        """
        let lines = HTMLText.lines(html)
        #expect(lines.map(\.text) == ["Grüezi Léa,", "zweite Zeile", "Absatz mit fett und Link <https://x.ch/a>.", "", "• eins", "• zwei", "",
                                      "1. erstens", "", "Hallenmiete\t4'800", "", "Beni", "079 000 00 00", ""])
        #expect(lines.filter { $0.region == .signature }.map(\.text) == ["Beni", "079 000 00 00", ""])
    }
}

@Suite struct ChatTimelineTests {
    let me = EmailAddress(name: "Benjamin Amhof", address: "ben@example.ch")
    let sina = EmailAddress(name: "Sina Hofstetter", address: "sina@gmx.ch")
    let leonie = EmailAddress(name: "Leonie Odermatt", address: "leonie@gmx.ch")

    func mail(_ id: Int64, from: EmailAddress, to: [EmailAddress], subject: String, text: String, html: String? = nil, date: Date) -> MailMessage {
        MailMessage(id: id, accountID: UUID(), folder: "INBOX", folderRole: .inbox, uid: UInt32(id), messageID: "<\(id)@x>", inReplyTo: "",
                    references: "", subject: subject, from: from, to: to, cc: [], replyTo: [], date: date, snippet: "", bodyText: text,
                    bodyHTML: html, attachments: [], isBulk: false, isRead: true, isFlagged: false, isArchived: false, category: nil,
                    categorySource: nil, summary: nil, needsReply: false, spaceIDs: [], rawPath: "")
    }

    func build(_ messages: [MailMessage]) -> [ChatItem] {
        ChatTimeline.build(messages, isMe: { $0.address == me.address }, shortName: { String($0.name.split(separator: " ").first ?? "") })
    }

    @Test func forwardedMailShowsUnderItsAuthor() throws {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let forward = """
        Schau mal, das kam von Sina.

        ---------- Forwarded message ---------
        Von: Sina Hofstetter <sina@gmx.ch>
        Date: Di. 11. Nov. 2025 um 20:22
        Subject: Texte HP
        To: <ben@example.ch>

        Hoi Beni, anbei die Texte für die Homepage.
        Liebe Grüsse Sina
        """
        let items = build([mail(1, from: me, to: [leonie], subject: "Fwd: Texte HP", text: forward, date: base)])
        #expect(items.count == 2)
        guard case .bubble(let own) = items[0], case .bubble(let forwarded) = items[1] else { Issue.record("expected two bubbles"); return }
        #expect(own.author == me && own.source == "Schau mal, das kam von Sina.")
        #expect(forwarded.author == sina)
        #expect(forwarded.via == me)
        #expect(forwarded.source == "Hoi Beni, anbei die Texte für die Homepage.\nLiebe Grüsse Sina")
        #expect(Calendar.current.component(.year, from: forwarded.date) == 2025)
    }

    @Test func forwardingAMailOfTheChatIsOnlyANote() throws {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let original = "Hoi Beni, anbei die Texte für die Homepage.\nSie sind noch nicht ganz fertig, aber ein Anfang.\nLiebe Grüsse Sina"
        let forward = "WG an dich.\n\nVon: Sina Hofstetter <sina@gmx.ch>\nGesendet: Dienstag, 11. November 2025 20:22\nAn: ben@example.ch\nBetreff: Texte HP\n\n" + original
        let items = build([mail(1, from: sina, to: [me], subject: "Texte HP", text: original, date: base),
                           mail(2, from: me, to: [leonie], subject: "WG: Texte HP", text: forward, date: base.addingTimeInterval(3600))])
        #expect(items.count == 3)
        guard case .note(_, _, let text) = items[2] else { Issue.record("expected a note"); return }
        #expect(text.hasPrefix("You forwarded Sina’s message from"))
        #expect(text.hasSuffix(" to Leonie"))
    }

    @Test func aMailSentTwiceIsOneBubble() throws {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let text = "Sehr geehrter Herr Amhof\n\nAnbei der Entwurf.\n\nFreundliche Grüsse\nAnabel"
        let items = build([mail(1, from: sina, to: [me], subject: "AW: Entwurf", text: text, date: base),
                           mail(2, from: sina, to: [me, leonie], subject: "AW: Entwurf", text: text, date: base.addingTimeInterval(120))])
        #expect(items.count == 1)
        guard case .bubble(let bubble) = items[0] else { return }
        #expect(bubble.sentAgain.map(\.id) == [2])
    }

    @Test func textPastedBelowIsFolded() throws {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let first = "Hallo liebe Interessentinnen,\n\nwir haben mit dem Hotel entschieden, das Camp durchzuführen.\nBitte ergänzt die Buchungen.\n\nViele Grüße\nDein Team"
        let second = "Hallo,\n\nwir haben gute Nachrichten: das Camp findet statt.\n\nViele Grüße\nDein Team\n\n" + first
        let items = build([mail(1, from: sina, to: [me], subject: "Camp", text: first, date: base),
                           mail(2, from: sina, to: [me], subject: "Camp", text: second, date: base.addingTimeInterval(86400 * 3))])
        guard case .bubble(let bubble) = items[1] else { Issue.record("expected a bubble"); return }
        #expect(bubble.source == "Hallo,\n\nwir haben gute Nachrichten: das Camp findet statt.\n\nViele Grüße\nDein Team")
        #expect(bubble.repeated?.of.id == 1)
        #expect(bubble.repeated?.text == first)
    }

    @Test func serviceBoilerplateFoldsAway() {
        let top = "Du hast Nachrichten von selina zum Inserat Runder Esstisch erhalten."
        let bottom = "Diese Nachrichten wurden via tutti.ch verschickt und als Kopie an deine E-Mail-Adresse gesendet."
        let bodies = [top + "\n\nHallo Beni\nKlappt das heute?\n\nJetzt direkt antworten\n\n" + bottom,
                      top + "\n\nSuper, bis dann!\n\nJetzt direkt antworten\n\n" + bottom]
        let signature = SenderSignature.learn(from: bodies, name: "tutti")
        #expect(signature.boilerplate.contains(top) && signature.boilerplate.contains(bottom))
        let formatted = MessageFormatter.format(bodies[0], known: signature.known, template: signature.boilerplate)
        #expect(formatted.visible.map(\.text) == ["Hallo Beni\nKlappt das heute?", "Jetzt direkt antworten"])
        #expect(formatted.text(of: .template).contains(top))
        #expect(MessageFormatter.content(formatted) == MessageFormatter.content(bodies[0]))
    }
}

@Suite struct AccountTests {
    @Test func aliasCandidatesLookLikeTheUser() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rallymail-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MailStore(url: url)
        let account = UUID()
        let me = EmailAddress(name: "Benjamin Amhof", address: "ben@gmail.com")
        let school = EmailAddress(name: "Amhof Benjamin", address: "benjamin.amhof@stud.hslu.ch")
        let lea = EmailAddress(name: "Lea Brunner", address: "lea@gmx.ch")
        for (index, to) in [[school], [school, lea], [lea], [me]].enumerated() {
            var parsed = ParsedMail()
            parsed.messageID = "<\(index)@x>"
            parsed.from = lea
            parsed.to = to
            parsed.subject = "Hi"
            parsed.date = Date(timeIntervalSince1970: 1_791_000_000 + Double(index))
            try store.insert(IncomingMessage(accountID: account, folder: "INBOX", folderRole: .inbox, uid: UInt32(index + 1), flags: [],
                                             parsed: parsed, rawPath: ""))
        }
        #expect(try store.aliasCandidates(account: account, name: me.name, email: me.address) == ["benjamin.amhof@stud.hslu.ch"])
        #expect(Account(provider: .gmail, name: "B", email: "Ben@gmail.com").allAddresses == ["ben@gmail.com"])
    }

    @Test func theAccountOnlyNudgesTheCourt() {
        let slackers = UUID(), vbc = UUID(), school = UUID(), gmail = UUID()
        let tom = EmailAddress(name: "Tom", address: "tom@x.ch"), lea = EmailAddress(name: "Lea", address: "lea@x.ch")
        func topic(_ id: String, _ people: [EmailAddress], court: UUID?, account: UUID) -> Conversation {
            Conversation(id: id, subject: id, firstDate: Date(), lastDate: Date(), messageCount: 1, openCount: 1, unreadCount: 0,
                         needsReply: false, hasAttachments: false, isSpam: false, category: .primary,
                         participants: people, lastMessageID: 1, lastFrom: people[0], lastTo: [], lastFolderRole: .inbox,
                         lastSummary: nil, lastSnippet: "", accountID: account, spaceID: court, snoozedUntil: nil, waitingDismissed: false)
        }
        // Everything from the school account went to Slackers; Tom's topics went to VBC from Gmail.
        var history = (0..<6).map { topic("s\($0)", [lea], court: slackers, account: school) }
        history += (0..<3).map { topic("v\($0)", [tom], court: vbc, account: gmail) }
        let courts = CourtSuggestions(history: history) { _ in false }
        // People win: Tom from the school account still points to VBC.
        #expect(courts.suggest(for: topic("new1", [tom], court: nil, account: school)) == vbc)
        // Without people signals, a strong account pattern suggests alone.
        let stranger = EmailAddress(name: "X", address: "x@y.ch")
        #expect(courts.suggest(for: topic("new2", [stranger], court: nil, account: school)) == slackers)
        // Gmail has no clear pattern (all VBC but only 3 topics): nothing is suggested from the account alone.
        #expect(courts.suggest(for: topic("new3", [stranger], court: nil, account: gmail)) == nil)
    }
}
