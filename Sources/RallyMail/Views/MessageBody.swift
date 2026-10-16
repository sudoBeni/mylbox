import RallyMailCore
import SwiftUI

/// A message body laid out like a chat (see `MessageFormatter`): paragraphs, lists with bullets, tables in
/// monospace, greeting and sign-off quiet, signature and legal notice behind chips that open in place. The
/// device footer is shown by the bubble's meta line.
struct MessageBodyView: View {
    let formatted: FormattedBody
    /// The same sender's signature in their previous message here; lines that differ are marked.
    var previousSignature = ""
    @State private var opened: Set<FormattedBody.Role> = []

    private var folded: [FormattedBody.Role] {
        [.template, .signature, .disclaimer].filter { role in formatted.blocks.contains { $0.role == role } }
    }

    private func label(_ role: FormattedBody.Role, changed: Bool) -> String {
        switch role {
        case .signature: changed ? "Signature changed" : "Signature"
        case .template: "Boilerplate"
        default: "Notice"
        }
    }

    /// Signature lines that were not in the previous one ("079 …" became "078 …").
    private var changedLines: Set<String> {
        guard !previousSignature.isEmpty else { return [] }
        let before = Set(previousSignature.split(separator: "\n").map { MessageFormatter.content(String($0)) })
        return Set(formatted.text(of: .signature).split(separator: "\n").map(String.init)
            .filter { !MessageFormatter.content($0).isEmpty && !before.contains(MessageFormatter.content($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(formatted.visible.enumerated()), id: \.offset) { _, block in
                view(of: block)
            }
            if !folded.isEmpty {
                HStack(spacing: 6) {
                    ForEach(folded, id: \.self) { role in chip(role) }
                }
                ForEach(folded.filter(opened.contains), id: \.self) { role in
                    Text(role == .signature ? signatureText : BodyText.attributed(formatted.text(of: role)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var signatureText: AttributedString {
        let changed = changedLines
        var result = AttributedString()
        for (index, line) in formatted.text(of: .signature).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            var part = BodyText.attributed(String(line))
            if changed.contains(String(line)) { part.backgroundColor = .orange.opacity(0.18) }
            result += part
        }
        return result
    }

    @ViewBuilder
    private func view(of block: FormattedBody.Block) -> some View {
        switch block.role {
        case .list:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.bullet(item.marker))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(BodyText.attributed(item.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(size: 13))
        case .table:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
            }
        case .signOff:
            Text(BodyText.attributed(block.text))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        default:
            Text(BodyText.attributed(block.text))
                .font(.system(size: 13))
                .foregroundStyle(block.role == .greeting ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ role: FormattedBody.Role) -> some View {
        let isOpen = opened.contains(role)
        let changed = role == .signature && !changedLines.isEmpty
        return Button {
            if isOpen { opened.remove(role) } else { opened.insert(role) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: role == .signature ? "person.text.rectangle" : role == .template ? "doc.on.doc" : "text.justify.left")
                Text(label(role, changed: changed))
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(changed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(changed ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide" : changed ? "Differs from their previous signature in this conversation"
              : role == .template ? "Text this sender puts in every mail" : formatted.text(of: role))
    }

    /// "-", "*", "+", "–" read as a bullet; numbers stay as written.
    static func bullet(_ marker: String) -> String {
        marker.first?.isNumber == true ? marker : "•"
    }
}

/// Body text with links shown short (`MessageBubble.linked`), phone numbers that call and addresses that open
/// in Maps. The text itself stays as written.
enum BodyText {
    static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
                                                | NSTextCheckingResult.CheckingType.address.rawValue)
    /// "CH93 0076 2011 …": an IBAN, not a phone number.
    static let ibanStart = try! NSRegularExpression(pattern: #"[A-Z]{2}\d{2}\s?$"#)

    static func attributed(_ text: String) -> AttributedString {
        var result = MessageBubble.linked(text)
        let plain = String(result.characters)
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: result), result[range].runs.allSatisfy({ $0.link == nil }) else { continue }
            let found = ns.substring(with: match.range)
            var url: URL?
            if match.resultType == .phoneNumber {
                let before = ns.substring(with: NSRange(location: max(0, match.range.location - 5), length: min(5, match.range.location)))
                let digits = found.filter(\.isNumber)
                if digits.count >= 9, found.first == "+" || found.first == "0",
                   ibanStart.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil {
                    url = URL(string: "tel:" + found.filter { $0.isNumber || $0 == "+" })
                }
            } else if match.resultType == .address, let query = found.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                url = URL(string: "maps://?q=" + query)
            }
            guard let url else { continue }
            result[range].link = url
            result[range].foregroundColor = .accentColor
        }
        return result
    }
}

/// Signatures learned per sender, from their newest mails. Relearned when a newer mail from them shows up.
@MainActor
final class SignatureBook {
    static let shared = SignatureBook()
    private var cache: [String: (newest: Date, signature: SenderSignature)] = [:]

    func signature(for message: MailMessage, store: MailStore) -> SenderSignature {
        signature(for: message.from, newest: message.date, store: store)
    }

    func signature(for author: EmailAddress, newest: Date, store: MailStore) -> SenderSignature {
        let address = author.address.lowercased()
        guard !address.isEmpty else { return .empty }
        if let entry = cache[address], entry.newest >= newest { return entry.signature }
        let mails = (try? store.messages(from: address, limit: 15)) ?? []
        let signature = SenderSignature.learn(from: mails.map(\.bubbleSource), name: author.name, address: address)
        cache[address] = (max(mails.first?.date ?? newest, newest), signature)
        return signature
    }
}

/// Next to the sender's name: their role or organisation from the signature, with phone and web. A click shows
/// the whole signature as written.
struct SenderBadge: View {
    let signature: SenderSignature
    @State private var showing = false

    var body: some View {
        let card = signature.card
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                if let title = card.title {
                    Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 170, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                }
                if !card.phones.isEmpty { Image(systemName: "phone") }
                if !card.links.isEmpty { Image(systemName: "globe") }
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("From their signature")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(BodyText.attributed(signature.latest))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let phone = card.phones.first, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                        Link(destination: url) { Label(phone, systemImage: "phone") }
                    }
                    if let link = card.links.first {
                        Link(destination: link) { Label(link.host() ?? link.absoluteString, systemImage: "globe") }
                    }
                }
                .font(.system(size: 11))
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// Who got a message, in the free space beside its bubble and centred on it, so it reads as the mail's
/// addressees rather than a sender: "to:", "cc:", "bcc:" (dashed, only known for the user's own mail) with faces
/// and names. Without room for names, only the faces; hovering one shows name and address.
struct RecipientColumn: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    /// People per group before "+3".
    var limit = 4

    private var groups: [(label: String, people: [EmailAddress])] {
        [("to", message.to), ("cc", message.cc), ("bcc", message.bcc)].filter { !$0.people.isEmpty }
    }

    var body: some View {
        if !groups.isEmpty {
            ViewThatFits(in: .horizontal) {
                card(names: true)
                card(names: false)
            }
        }
    }

    private func card(names: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            ForEach(groups, id: \.label) { group in
                GridRow(alignment: .top) {
                    Text(group.label + ":")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(group.people.prefix(limit).enumerated()), id: \.offset) { _, person in
                            HStack(spacing: 5) {
                                Avatar(person, size: 15, isMe: model.isMe(person), dashed: group.label == "bcc")
                                if names {
                                    Text(model.isMe(person) ? "you" : person.displayName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .help("\(group.label.capitalized): \(model.isMe(person) ? "you" : person.formatted)")
                        }
                        if group.people.count > limit {
                            Text("+\(group.people.count - limit) more")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .help(group.people.dropFirst(limit).map(\.formatted).joined(separator: "\n"))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: names ? 190 : nil, alignment: .leading)
        .fixedSize(horizontal: !names, vertical: false)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)))
    }
}


/// The mark of the account a mail came in on: the account's symbol in its colour. Only a label, nothing is
/// grouped by it; shown once there is more than one account.
struct AccountBadge: View {
    @Environment(AppModel.self) private var model
    let accountID: UUID
    var size: CGFloat = 14

    var body: some View {
        if model.config.accounts.count > 1, let account = model.account(accountID) {
            Image(systemName: account.badgeSymbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color(hue: account.badgeHue, saturation: 0.55, brightness: 0.7), in: Circle())
                .help("Arrived in \(account.email)")
        }
    }
}
