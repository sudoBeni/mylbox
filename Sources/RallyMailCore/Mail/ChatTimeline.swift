import Foundation

/// One bubble of a chat: a piece of text with the person who wrote it and when. Mostly one per mail; a forward
/// gives two (the forwarder's note and the forwarded text under its author's name), a mail sent twice gives one.
public struct ChatBubble: Identifiable, Equatable, Sendable {
    /// The mail the text comes from.
    public var message: MailMessage
    /// Who wrote the text: the sender, or the author of a forwarded message.
    public var author: EmailAddress
    /// When it was written: the mail's date, or the forwarded message's.
    public var date: Date
    /// Who passed the text on, for a forwarded message.
    public var via: EmailAddress?
    /// The text to lay out (`MailMessage.bubbleSource` for an ordinary mail).
    public var source: String
    /// A run of the text that repeats an earlier bubble word for word (pasted below, not quoted): shown folded.
    public var repeated: Repeated?
    /// The same mail sent again later (a program's hiccup, or a second send to someone else).
    public var sentAgain: [MailMessage] = []
    /// The mail's attachments are shown with this bubble (the last one made from the mail).
    public var showsAttachments = true
    /// A mail that only carries attachments or a quote: nothing of its own to show, but it was sent.
    public var isEmpty: Bool { MessageFormatter.content(source).isEmpty }

    public struct Repeated: Equatable, Sendable {
        /// The earlier bubble's mail.
        public var of: MailMessage
        public var author: EmailAddress
        public var text: String
    }

    public var id: String { via == nil ? "\(message.id)" : "\(message.id):forwarded" }
    public var isForwarded: Bool { via != nil }
}

/// What the chat shows in order: bubbles and the notes between them.
public enum ChatItem: Identifiable, Equatable, Sendable {
    case bubble(ChatBubble)
    /// "Beni forwarded Sina's mail from 11 Nov to Leonie": the mail is in the chat already, nothing to repeat.
    case note(id: String, message: MailMessage, text: String)

    public var id: String {
        switch self {
        case .bubble(let bubble): bubble.id
        case .note(let id, _, _): id
        }
    }

    public var message: MailMessage {
        switch self {
        case .bubble(let bubble): bubble.message
        case .note(_, let message, _): message
        }
    }
}

/// Turns the mails of a conversation into chat items. Rules only:
/// - a mail sent twice (same author, subject and text within a day) is one bubble, with a note who else got it;
/// - a forwarded mail shows under its author's name with "via" the forwarder; when the forwarded mail is in the
///   chat already, only a note says who forwarded it to whom;
/// - text that repeats an earlier bubble word for word (pasted below instead of quoted) is folded.
public enum ChatTimeline {
    public static func build(_ messages: [MailMessage], isMe: (EmailAddress) -> Bool, shortName: (EmailAddress) -> String) -> [ChatItem] {
        var items: [ChatItem] = []
        var bubbles: [(index: Int, lines: [String], content: String)] = []
        func remember(_ bubble: ChatBubble, at index: Int) {
            let lines = MessageFormatter.lines(bubble.source).map { MessageFormatter.content($0.text) }.filter { !$0.isEmpty }
            bubbles.append((index, lines, lines.joined()))
        }
        func name(_ address: EmailAddress) -> String { isMe(address) ? "You" : shortName(address) }
        func whose(_ address: EmailAddress) -> String { isMe(address) ? "your" : shortName(address) + "’s" }
        /// "to Leonie, Tom", "to you"; the user is left out when others got it too.
        func recipients(_ message: MailMessage) -> String {
            var seen = Set<String>()
            let all = (message.to + message.cc).filter { !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
            let others = all.filter { !isMe($0) }
            if others.isEmpty { return all.isEmpty ? "" : " to you" }
            return " to " + others.map(shortName).joined(separator: ", ")
        }

        for message in messages.sorted(by: { $0.date < $1.date }) {
            let body = message.segmented

            // Sent again: fold into the earlier bubble.
            if let earlier = items.lastIndex(where: { item in
                guard case .bubble(let bubble) = item, !bubble.isForwarded else { return false }
                return bubble.message.from.address.lowercased() == message.from.address.lowercased()
                    && abs(message.date.timeIntervalSince(bubble.message.date)) < 86400
                    && Threading.normalizedSubject(bubble.message.subject).lowercased() == Threading.normalizedSubject(message.subject).lowercased()
                    && MessageFormatter.content(bubble.message.segmented.own) == MessageFormatter.content(body.own)
                    && !MessageFormatter.content(body.own).isEmpty
            }), case .bubble(var bubble) = items[earlier] {
                bubble.sentAgain.append(message)
                items[earlier] = .bubble(bubble)
                continue
            }

            if body.isForward, let header = body.header {
                let own = (body.text.isEmpty && !body.inlineText.isEmpty ? body.inlineText + "\n\n" + body.own : body.own)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hasOwn = !MessageFormatter.content(own).isEmpty
                let author = header.from.map { from in
                    from.address.isEmpty ? (messages.first { $0.from.name == from.name }?.from ?? from) : from
                } ?? message.from
                let ownForward = author.address.lowercased() == message.from.address.lowercased()
                // The forwarded message's date, unless it makes no sense (read wrongly, or after the forward).
                let written = header.date.flatMap { $0 <= message.date ? $0 : nil } ?? message.date
                let to = recipients(message)
                if let forwarded = body.forwarded {
                    let content = MessageFormatter.content(forwarded)
                    if hasOwn {
                        let bubble = ChatBubble(message: message, author: message.from, date: message.date, source: own, showsAttachments: false)
                        items.append(.bubble(bubble))
                        remember(bubble, at: items.count - 1)
                    }
                    if let known = bubbles.first(where: { $0.content.count >= 40 && content.contains(String($0.content.prefix(120))) }),
                       case .bubble(let earlier) = items[known.index] {
                        let when = DateText.short(earlier.date)
                        let text = ownForward || earlier.author.address.lowercased() == message.from.address.lowercased()
                            ? "\(name(message.from)) sent \(isMe(message.from) ? "your" : "their") message from \(when) again\(to)"
                            : "\(name(message.from)) forwarded \(whose(earlier.author)) message from \(when)\(to)"
                        items.append(.note(id: "\(message.id):forward", message: message, text: text))
                        if !message.attachments.isEmpty {
                            items.append(.bubble(ChatBubble(message: message, author: message.from, date: message.date, source: "")))
                        }
                    } else {
                        let bubble = ChatBubble(message: message, author: author, date: written, via: ownForward ? nil : message.from, source: forwarded)
                        items.append(.bubble(bubble))
                        remember(bubble, at: items.count - 1)
                    }
                } else {
                    // Only the header came along: the forward carries attachments, or nothing.
                    let what = message.attachments.isEmpty ? "a message" : (message.attachments.count == 1 ? message.attachments[0].filename : "\(message.attachments.count) files")
                    if hasOwn {
                        let bubble = ChatBubble(message: message, author: message.from, date: message.date, source: own)
                        items.append(.bubble(bubble))
                        remember(bubble, at: items.count - 1)
                    } else {
                        items.append(.note(id: "\(message.id):forward", message: message,
                                           text: "\(name(message.from)) forwarded \(what) from \(name(author))\(to)"))
                        if !message.attachments.isEmpty {
                            items.append(.bubble(ChatBubble(message: message, author: message.from, date: message.date, source: "")))
                        }
                    }
                }
                continue
            }

            var bubble = ChatBubble(message: message, author: message.from, date: message.date, source: message.bubbleSource)
            // Pasted below instead of quoted: the text repeats an earlier bubble.
            if let found = repeatedRun(in: bubble.source, among: bubbles), case .bubble(let earlier) = items[found.index] {
                bubble.source = found.rest
                bubble.repeated = ChatBubble.Repeated(of: earlier.message, author: earlier.author, text: found.text)
            }
            items.append(.bubble(bubble))
            remember(bubble, at: items.count - 1)
        }
        return items
    }

    /// The longest run of lines in `source` that is an earlier bubble (at least three lines or 120 characters),
    /// and the text without it.
    static func repeatedRun(in source: String, among earlier: [(index: Int, lines: [String], content: String)])
        -> (index: Int, text: String, rest: String)? {
        let raw = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let keys = raw.map { MessageFormatter.content($0) }
        let textLines = keys.indices.filter { !keys[$0].isEmpty }
        var best: (index: Int, range: ClosedRange<Int>)?
        for candidate in earlier where candidate.lines.count >= 3 || candidate.content.count >= 120 {
            guard !candidate.lines.isEmpty, candidate.lines.count <= textLines.count else { continue }
            for start in 0...(textLines.count - candidate.lines.count) {
                var matched = true
                for offset in candidate.lines.indices where keys[textLines[start + offset]] != candidate.lines[offset] {
                    matched = false
                    break
                }
                if matched {
                    let range = textLines[start]...textLines[start + candidate.lines.count - 1]
                    if best == nil || range.count > best!.range.count { best = (candidate.index, range) }
                    break
                }
            }
        }
        guard let best else { return nil }
        let text = raw[best.range].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = (raw[..<best.range.lowerBound] + raw[(best.range.upperBound + 1)...]).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Folding away everything leaves nothing to show: keep the text then.
        guard !rest.isEmpty || !text.isEmpty else { return nil }
        return (best.index, text, rest)
    }
}
