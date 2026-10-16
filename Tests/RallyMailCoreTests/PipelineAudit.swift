import Foundation
import Testing
@testable import RallyMailCore

/// Checks the chat pipeline (quote stripping, bubble text, threading) against every mail in a database copy:
///   RALLYMAIL_AUDIT=/path/to/rallymail.sqlite RALLYMAIL_AUDIT_DUMP=/path.txt swift test --filter PipelineAudit
/// It prints counts and writes every suspicious bubble with its reason to the dump, to read through.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"] != nil))
struct PipelineAudit {
    @Test func bubblesShowOnlyWhatWasNewlyWritten() throws {
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let messages = try store.messages(.all, limit: 1_000_000)
        let threads = Dictionary(grouping: messages, by: \.threadID).mapValues { $0.sorted { $0.date < $1.date } }
        var counts: [String: Int] = [:]
        var dump = ""
        func report(_ kind: String, _ message: MailMessage, _ detail: String) {
            counts[kind, default: 0] += 1
            dump += "=== \(kind) · \(message.id) · \(message.from.address) · \(message.date) · \(message.subject)\n\(detail)\n\n"
        }
        for (_, thread) in threads {
            for (index, message) in thread.enumerated() {
                let chat = message.chatText
                let full = message.fullText
                let chatContent = MessageFormatter.content(chat)
                if chatContent.isEmpty {
                    if !MessageFormatter.content(full).isEmpty {
                        report("EMPTY-BUBBLE", message, "full text starts: " + full.prefix(300).replacingOccurrences(of: "\n", with: "⏎"))
                    } else {
                        counts["empty-mail", default: 0] += 1
                    }
                    continue
                }
                let lines = chat.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if let generated = lines.first(where: { QuoteStripper.isGenerated($0) }) {
                    report("GENERATED-LINE", message, "line: \(generated)\n--- chat:\n\(chat.prefix(600))")
                }
                if let quoted = lines.first(where: { $0.hasPrefix(">") }) {
                    report("QUOTE-MARKER", message, "line: \(quoted)\n--- chat:\n\(chat.prefix(600))")
                }
                // The bubble repeats what someone wrote earlier in the thread: the quote was not cut.
                for earlier in thread[..<index] {
                    let earlierContent = MessageFormatter.content(earlier.chatText)
                    guard earlierContent.count >= 40 else { continue }
                    let probe = String(earlierContent.prefix(80))
                    if chatContent.contains(probe) {
                        report("QUOTE-LEAK", message, "repeats \(earlier.id) (\(earlier.from.address)): \(earlier.chatText.prefix(120).replacingOccurrences(of: "\n", with: "⏎"))\n--- chat:\n\(chat.prefix(900))")
                        break
                    }
                }
                if message.bodyText.isEmpty, message.bodyHTML != nil {
                    report("HTML-ONLY", message, chat.prefix(700).description)
                }
                let stripped = message.segmented
                if stripped.text.isEmpty, !stripped.inlineText.isEmpty {
                    report("INLINE-ONLY", message, "inline: \(stripped.inlineText.prefix(400))")
                }
                // A reply whose quote was not found at all: the sender's program hides it in a way we don't know.
                if (!message.inReplyTo.isEmpty || Threading.isReplySubject(message.subject)), stripped.quoted == nil,
                   !message.bodyText.isEmpty, index > 0 {
                    report("REPLY-WITHOUT-QUOTE", message, "text:\n\(message.bodyText.prefix(500))")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_DUMP"] {
            try dump.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("audited \(messages.count) mails in \(threads.count) conversations")
        for (kind, count) in counts.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(count)") }
    }

    /// RALLYMAIL_AUDIT_PROBE=<message id>: prints how one mail is split, to debug a case from the dump.
    @Test func probeOneMail() throws {
        guard let raw = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_PROBE"] else { return }
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let all = try store.messages(.all, limit: 1_000_000)
        for id in raw.split(separator: ",").compactMap({ Int64($0) }) {
        let message = try #require(all.first { $0.id == id })
        print("PROBE ===== \(id) \(message.from.address) \(message.subject)")
        let stripped = message.segmented
        let full = stripped.source
        print("PROBE text.isEmpty=\(message.bodyText.isEmpty) html=\(message.bodyHTML != nil) full=\(full.count) own=\(stripped.own.count) text=\(stripped.text.count) quoted=\(stripped.quoted?.count ?? -1) display=\(stripped.display.count)")
        print("PROBE chatText:\n\(message.chatText.prefix(500))")
        print("PROBE header: \(stripped.header.map { "forward=\($0.isForward) from=\($0.from?.formatted ?? "-") date=\($0.date.map { "\($0)" } ?? "-") (\($0.dateText.prefix(40))) subject=\($0.subject) to=\($0.to.map(\.address))" } ?? "none")")
        print("PROBE forwarded:\n\(stripped.forwarded?.prefix(400) ?? "nil")")
        print("PROBE own:\n\(stripped.text)\nPROBE quoted starts:\n\(stripped.quoted?.prefix(300) ?? "nil")\nPROBE inline:\n\(stripped.inlineText)")
        for (index, line) in full.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).prefix(Int(ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_LINES"] ?? "0") ?? 0).enumerated() {
            print("PROBE \(index): \(String(line).trimmingCharacters(in: .whitespaces).prefix(90).debugDescription) generated=\(QuoteStripper.isGenerated(String(line).trimmingCharacters(in: .whitespaces)))")
        }
        }
    }

    /// What the chat timeline makes of every conversation: forwards, notes, repeats and duplicates, to read through.
    @Test func listTimelineEvents() throws {
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let messages = try store.messages(.all, limit: 1_000_000)
        let own = Set(messages.filter { $0.folderRole == .sent }.map { $0.from.address.lowercased() })
        let threads = Dictionary(grouping: messages, by: \.threadID)
        var counts: [String: Int] = [:]
        var dump = ""
        for (_, thread) in threads {
            let items = ChatTimeline.build(thread, isMe: { own.contains($0.address.lowercased()) }, shortName: { $0.name.isEmpty ? $0.address : String($0.name.split(separator: " ").first!) })
            for item in items {
                switch item {
                case .note(_, let message, let text):
                    counts["note", default: 0] += 1
                    dump += "=== NOTE · \(message.id) · \(message.subject)\n\(text)\n\n"
                case .bubble(let bubble):
                    if bubble.isForwarded {
                        counts["forwarded", default: 0] += 1
                        dump += "=== FORWARDED · \(bubble.message.id) · \(bubble.message.subject)\nauthor=\(bubble.author.formatted) via=\(bubble.via?.formatted ?? "") date=\(bubble.date)\n\(bubble.source.prefix(300))\n\n"
                    }
                    if let repeated = bubble.repeated {
                        counts["repeated", default: 0] += 1
                        dump += "=== REPEATED · \(bubble.message.id) · \(bubble.message.subject)\nrepeats \(repeated.of.id) by \(repeated.author.address): \(repeated.text.prefix(120).replacingOccurrences(of: "\n", with: "⏎"))\n--- rest:\n\(bubble.source.prefix(300))\n\n"
                    }
                    if !bubble.sentAgain.isEmpty {
                        counts["sent-again", default: 0] += 1
                        dump += "=== SENT-AGAIN · \(bubble.message.id) · \(bubble.message.subject)\nagain: \(bubble.sentAgain.map { "\($0.id) to \($0.to.map(\.address))" })\n\n"
                    }
                    if bubble.isEmpty, bubble.message.attachments.isEmpty {
                        counts["empty-bubble", default: 0] += 1
                        dump += "=== EMPTY · \(bubble.message.id) · \(bubble.message.from.address) · \(bubble.message.subject)\nsource starts: \(bubble.message.fullText.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))\n\n"
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_DUMP"] {
            try dump.write(toFile: path + ".timeline.txt", atomically: true, encoding: .utf8)
        }
        print("timeline: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    /// Every change a reply made to an earlier message, to judge false positives.
    @Test func listHistoryEdits() throws {
        let store = try MailStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT"]!))
        let messages = try store.messages(.all, limit: 1_000_000)
        let threads = Dictionary(grouping: messages, by: \.threadID).mapValues { $0.sorted { $0.date < $1.date } }
        var count = 0, withEdits = 0
        var dump = ""
        for (_, thread) in threads where thread.count > 1 {
            let edits = HistoryEdits.find(in: thread)
            for (index, found) in edits.enumerated() where !found.isEmpty {
                withEdits += 1
                for edit in found {
                    count += 1
                    dump += "=== EDIT · \(thread[index].id) · \(thread[index].from.address) · \(thread[index].subject) changed \(thread[edit.message].id) (\(thread[edit.message].from.address))\n"
                    for passage in edit.passages {
                        dump += "  " + passage.map { piece in
                            switch piece {
                            case .same(let t): t
                            case .removed(let t): "[-" + t + "-]"
                            case .added(let t): "{+" + t + "+}"
                            }
                        }.joined(separator: " ") + "\n"
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["RALLYMAIL_AUDIT_DUMP"] {
            try dump.write(toFile: path + ".edits.txt", atomically: true, encoding: .utf8)
        }
        print("edits: \(count) in \(withEdits) mails")
    }
}
