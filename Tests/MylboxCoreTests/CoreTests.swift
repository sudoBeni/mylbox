import Foundation
import Testing
@testable import MylboxCore

@Suite struct MIMETests {
    @Test func decodesEncodedWords() {
        #expect(MIME.decodeEncodedWords("=?UTF-8?Q?Gr=C3=BCezi_mitenand?=") == "Grüezi mitenand")
        #expect(MIME.decodeEncodedWords("=?utf-8?B?SmFocmVzYmVpdHJhZw==?= =?utf-8?B?IDIwMjY=?=") == "Jahresbeitrag 2026")
        #expect(MIME.decodeEncodedWords("Re: =?ISO-8859-1?Q?Rechnung_f=FCr?= Oktober") == "Re: Rechnung für Oktober")
    }

    @Test func parsesAddresses() {
        let list = MIME.parseAddressList(#""Amhof, Benjamin" <ben@example.ch>, kasse@vbc.ch, =?UTF-8?Q?J=C3=BCrg?= <j@x.ch>"#)
        #expect(list.count == 3)
        #expect(list[0] == EmailAddress(name: "Amhof, Benjamin", address: "ben@example.ch"))
        #expect(list[1].address == "kasse@vbc.ch")
        #expect(list[2].name == "Jürg")
    }

    @Test func parsesMultipartWithAttachment() {
        let raw = """
        From: Kassier <kasse@vbc.ch>\r
        To: ben@example.ch\r
        Subject: =?UTF-8?Q?Abrechnung_M=C3=A4rz?=\r
        Date: Thu, 9 Oct 2026 14:30:00 +0200\r
        Message-ID: <abc@vbc.ch>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="XYZ"\r
        \r
        preamble\r
        --XYZ\r
        Content-Type: multipart/alternative; boundary=ALT\r
        \r
        --ALT\r
        Content-Type: text/plain; charset=iso-8859-1\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Hallo Ben, anbei die Abrechnung f=FCr M=E4rz.=\r
         Gruss\r
        --ALT\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Hallo Ben</p>\r
        --ALT--\r
        --XYZ\r
        Content-Type: application/pdf; name="abrechnung.pdf"\r
        Content-Disposition: attachment; filename*=UTF-8''Abrechnung%20M%C3%A4rz.pdf\r
        Content-Transfer-Encoding: base64\r
        \r
        SGVsbG8=\r
        --XYZ--\r

        """
        let mail = MIME.parse(Data(raw.utf8))
        #expect(mail.subject == "Abrechnung März")
        #expect(mail.from?.address == "kasse@vbc.ch")
        #expect(mail.text == "Hallo Ben, anbei die Abrechnung für März. Gruss")
        #expect(mail.html == "<p>Hallo Ben</p>")
        #expect(mail.attachments.count == 1)
        #expect(mail.attachments[0].filename == "Abrechnung März.pdf")
        #expect(mail.attachments[0].data == Data("Hello".utf8))
        #expect(mail.messageID == "<abc@vbc.ch>")
        #expect(abs(mail.date.timeIntervalSince1970 - 1_791_549_000) < 1)
    }

    @Test func htmlToText() {
        let text = HTMLText.plainText("<html><style>p{}</style><p>Hallo&nbsp;Welt</p><p>Zeile&#33; &auml;</p></html>")
        #expect(text == "Hallo Welt\nZeile! ä")
    }

    @Test func builtMessageRoundTrips() {
        let outgoing = OutgoingMail(from: EmailAddress(name: "Benjamin Amhof", address: "ben@example.ch"),
                                    to: [EmailAddress(name: "Jürg", address: "j@x.ch")],
                                    subject: "Grüsse aus dem Vorstand", body: "Hallo\n.\nTschüss",
                                    attachments: [OutgoingAttachment(filename: "beleg.txt", mimeType: "text/plain", data: Data("x".utf8))])
        let parsed = MIME.parse(MessageBuilder.build(outgoing))
        #expect(parsed.subject == "Grüsse aus dem Vorstand")
        #expect(parsed.to.first == EmailAddress(name: "Jürg", address: "j@x.ch"))
        #expect(parsed.text == "Hallo\r\n.\r\nTschüss")
        #expect(parsed.attachments.first?.filename == "beleg.txt")
    }

    @Test func dotStuffing() {
        let stuffed = SMTPClient.dotStuffed(Data("a\n.b\r\n..c".utf8))
        #expect(String(decoding: stuffed, as: UTF8.self) == "a\r\n..b\r\n...c\r\n")
    }
}

@Suite struct IMAPTests {
    @Test func parsesFetchWithLiteral() {
        let body = "Subject: Hi\r\n\r\nBody"
        let line = Array("* 3 FETCH (UID 42 FLAGS (\\Seen \\Flagged) INTERNALDATE \"09-Oct-2026 14:30:00 +0200\" BODY[] {\(body.utf8.count)}\r\n\(body))".utf8)
        let message = IMAPClient.parseFetch(line)
        #expect(message?.uid == 42)
        #expect(message?.flags == ["\\Seen", "\\Flagged"])
        #expect(message?.raw == Data(body.utf8))
        #expect(message?.internalDate != nil)
    }

    @Test func parsesList() {
        let values = IMAPParser.parse(Array(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#.utf8))
        #expect(values[2].list.compactMap(\.text) == ["\\HasNoChildren", "\\Sent"])
        #expect(values[4].text == "[Gmail]/Sent Mail")
    }

    @Test func sequenceSets() {
        #expect(IMAPClient.sequenceSet([5, 1, 2, 3, 9, 10]) == "1:3,5,9:10")
        #expect(IMAPClient.expandSet("1:3,7") == [1, 2, 3, 7])
        #expect(IMAPClient.parseCopyUID("OK [COPYUID 38505 3:4 101:102] Done") == [3: 101, 4: 102])
    }

    @Test func modifiedUTF7() {
        #expect(ModifiedUTF7.decode("Entw&APw-rfe") == "Entwürfe")
        #expect(ModifiedUTF7.encode("Entwürfe") == "Entw&APw-rfe")
        #expect(ModifiedUTF7.encode("A&B") == "A&-B")
    }

    @Test func detectsFolders() {
        let map = FolderMap.detect([
            IMAPMailbox(name: "INBOX", attributes: []),
            IMAPMailbox(name: "[Gmail]/All Mail", attributes: ["\\All"]),
            IMAPMailbox(name: "Gesendet", attributes: []),
            IMAPMailbox(name: "[Gmail]/Bin", attributes: ["\\Trash"]),
        ])
        #expect(map.sent == "Gesendet")
        #expect(map.archive == "[Gmail]/All Mail")
        #expect(map.trash == "[Gmail]/Bin")
    }
}

func sampleMessage(subject: String = "Mitgliederbeitrag", from: String = "kasse@vbc.ch") -> MailMessage {
    MailMessage(id: 1, accountID: UUID(), folder: "INBOX", folderRole: .inbox, uid: 1, messageID: "<m1@vbc.ch>",
                inReplyTo: "", references: "", subject: subject, from: EmailAddress(name: "Kassier", address: from),
                to: [EmailAddress(address: "ben@example.ch")], cc: [], replyTo: [],
                date: Date(timeIntervalSince1970: 1_791_549_000), snippet: "", bodyText: "Bitte bis Ende Monat zahlen.",
                bodyHTML: nil, attachments: [], isBulk: false, isRead: false, isFlagged: false, isArchived: false,
                category: nil, categorySource: nil, summary: nil, needsReply: false, spaceIDs: [], rawPath: "")
}

@Suite struct RuleTests {
    @Test func matchesAndCollectsActions() {
        let space = UUID()
        var rule = Rule(name: "Volleyball", conditions: [RuleCondition(field: .from, op: .endsWith, value: "@vbc.ch")],
                        actions: [.addToSpace(space), .setCategory(.primary)])
        #expect(RuleEngine.evaluate([rule], sampleMessage()).spaces == [space])
        #expect(RuleEngine.evaluate([rule], sampleMessage(from: "x@other.ch")).isEmpty)

        rule.conditions.append(RuleCondition(field: .subject, op: .contains, value: "rechnung"))
        #expect(!RuleEngine.matches(rule, sampleMessage()))
        rule.matchAll = false
        #expect(RuleEngine.matches(rule, sampleMessage()))
        rule.enabled = false
        #expect(!RuleEngine.matches(rule, sampleMessage()))
    }

    @Test func heuristics() {
        #expect(Heuristics.category(from: EmailAddress(address: "no-reply@bank.ch"), isBulk: false, subject: "") == .updates)
        #expect(Heuristics.category(from: EmailAddress(address: "shop@brand.com"), isBulk: true, subject: "") == .newsletters)
        #expect(Heuristics.category(from: EmailAddress(address: "info@vbc.ch"), isBulk: false, subject: "") == .primary)
    }
}

@Suite struct ExportTests {
    @Test func exportsMarkdownAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mylbox-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var space = Space(name: "Volleyball Finance")
        space.exportFolder = root.path

        var second = sampleMessage(subject: "AW: Mitgliederbeitrag")
        second.messageID = "<m2@vbc.ch>"
        second.date = second.date.addingTimeInterval(3600)
        let first = try SpaceExporter.export(space: space, messages: [sampleMessage(), second], accounts: [])
        #expect(first.total == 2)

        let index = try String(contentsOf: root.appendingPathComponent("INDEX.md"), encoding: .utf8)
        #expect(index.contains("## Mitgliederbeitrag"))
        #expect(index.contains("2 mails in 1 threads"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("messages").path)
        #expect(files.count == 2)
        #expect(files.contains { $0.hasPrefix("2026-") && $0.contains("_mitgliederbeitrag_") })

        let again = try SpaceExporter.export(space: space, messages: [sampleMessage()], accounts: [])
        #expect(again.written == 0)
        #expect(again.removed == 1)
    }

    @Test func refusesForeignFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mylbox-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "my repo".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        var space = Space(name: "X")
        space.exportFolder = root.path
        #expect(throws: ExportError.self) { try SpaceExporter.export(space: space, messages: [], accounts: []) }
        #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) == "my repo")
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mylbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MailStore(url: url)
        let account = UUID()
        var parsed = ParsedMail()
        parsed.subject = "Hallo"
        parsed.from = EmailAddress(address: "no-reply@shop.ch")
        parsed.text = "Ihre Bestellung"
        let incoming = IncomingMessage(accountID: account, folder: "INBOX", folderRole: .inbox, uid: 7,
                                       flags: ["\\Seen"], parsed: parsed, rawPath: "")
        let id = try #require(try store.insert(incoming))
        #expect(try store.insert(incoming) == nil)
        let space = UUID()
        try store.addToSpace(id, space: space)
        let message = try #require(try store.message(id))
        #expect(message.isRead)
        #expect(message.category == .updates)
        #expect(message.spaceIDs == [space])
        #expect(try store.messages(.space(space)).count == 1)
        #expect(try store.messages(.inbox).isEmpty)
        #expect(try store.messages(.category(.updates), search: "bestellung").count == 1)
    }
}
