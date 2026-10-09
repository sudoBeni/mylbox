import Foundation
import RallyMailCore

/// Who gets a mail, and how.
enum RecipientRole: String, CaseIterable, Identifiable {
    case to, cc, bcc

    var id: String { rawValue }

    var next: RecipientRole {
        switch self {
        case .to: .cc
        case .cc: .bcc
        case .bcc: .to
        }
    }

    var label: String { rawValue.uppercased() }
}

struct Recipient: Identifiable, Hashable {
    var address: EmailAddress
    var role: RecipientRole

    var id: String { address.address.lowercased() }
}

/// A mail being written: a reply inside a conversation, or a new conversation.
struct MailDraft: Identifiable {
    let id = UUID()
    var accountID: UUID?
    var recipients: [Recipient] = []
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: String?
    var attachments: [OutgoingAttachment] = []
    /// The conversation this reply belongs to, nil for a new mail.
    var threadID: String?

    var to: [EmailAddress] { recipients.filter { $0.role == .to }.map(\.address) }
    var cc: [EmailAddress] { recipients.filter { $0.role == .cc }.map(\.address) }
    var bcc: [EmailAddress] { recipients.filter { $0.role == .bcc }.map(\.address) }

    mutating func add(_ address: EmailAddress, as role: RecipientRole = .to) {
        guard !address.address.isEmpty, !recipients.contains(where: { $0.id == address.address.lowercased() }) else { return }
        recipients.append(Recipient(address: address, role: role))
    }

    mutating func remove(_ recipient: Recipient) {
        recipients.removeAll { $0.id == recipient.id }
    }

    mutating func cycleRole(_ recipient: Recipient) {
        guard let index = recipients.firstIndex(where: { $0.id == recipient.id }) else { return }
        recipients[index].role = recipients[index].role.next
    }

    /// "To Reto · copy to Lea · hidden copy to Jonas"
    func audienceText(nameOf: (EmailAddress) -> String) -> String {
        var parts: [String] = []
        if !to.isEmpty { parts.append("To " + to.map(nameOf).joined(separator: ", ")) }
        if !cc.isEmpty { parts.append("copy to " + cc.map(nameOf).joined(separator: ", ")) }
        if !bcc.isEmpty { parts.append("hidden copy to " + bcc.map(nameOf).joined(separator: ", ")) }
        return parts.isEmpty ? "Nobody gets this yet" : parts.joined(separator: " · ")
    }
}

/// A short, self-dismissing confirmation with an optional Undo.
struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
}

/// Time buckets for the archive: sticky headers and the jump rail use the same labels.
enum TimeGroup {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) { return "This week" }
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.wide).year())
        }
        return String(year)
    }

    static func short(_ label: String) -> String {
        switch label {
        case "Today": "now"
        case "Yesterday": "yest"
        case "This week": "week"
        default: label.count == 4 ? label : String(label.prefix(3))
        }
    }
}

enum DateText {
    /// "14:30", "Yesterday", "Tue", "9 Oct", "9 Oct 2025"
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
