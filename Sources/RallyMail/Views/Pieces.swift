import RallyMailCore
import SwiftUI

/// A tiny court with the net in the middle: the ball on your side, on theirs, or none.
struct BallGlyph: View {
    let ball: Ball
    var width: CGFloat = 24

    var body: some View {
        let height = width * 0.58
        ZStack {
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: 0xC9C5BE), lineWidth: 1.2)
            Rectangle().fill(Palette.faint).frame(width: 1.1, height: height - 3)
            if ball != .quiet {
                Circle()
                    .fill(ball == .mine ? Palette.me : Palette.them)
                    .frame(width: height * 0.46, height: height * 0.46)
                    .offset(x: (ball == .mine ? -1 : 1) * width * 0.23)
            }
        }
        .frame(width: width, height: height)
        .help(ball == .mine ? "On your side" : ball == .theirs ? "On their side: you wait" : "Quiet")
    }
}

/// Each court has its own color: the same everywhere it shows up. Infos and the Graveyard stay grey.
enum CourtColor {
    @MainActor static func of(_ id: UUID?, _ model: AppModel) -> Color {
        guard let id else { return Palette.faint }
        if id == model.config.infosID || id == model.config.graveyardID { return Color(hex: 0x8A8580) }
        let hue = Double(id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 3600 }) / 3600
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }
}

/// A court's square and its path ("VBC › Finanzen").
struct CourtLabel: View {
    @Environment(AppModel.self) private var model
    let court: UUID?
    var sub: Project? = nil
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(court, model)).frame(width: 7, height: 7)
            Text(model.space(court).map { court in sub.map { "\(court.name) › \($0.name)" } ?? court.name } ?? "No court")
        }
        .font(.system(size: size))
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
    }
}

/// One received mail in the Inbox: who, the subject and how it starts, and on the right where it belongs and how
/// it got there. Mail without a place shows RallyMail's suggestion instead.
struct MailRow: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    @State private var hovered = false

    var body: some View {
        let matter = model.matter(of: message)
        let selected = model.selectedMessage == message.id
        let loose = matter != nil && matter?.spaceID == nil
        HStack(alignment: .top, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(message.isRead ? Color.clear : Palette.me).frame(width: 8, height: 8).padding(.top, 12)
                Avatar(message.from, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.isMe(message.from) ? "You" : message.from.displayName)
                            .font(.system(size: 13, weight: message.isRead ? .medium : .heavy))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(subject).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(DateText.short(message.date)).font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                    }
                    Text(message.snippet).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    if !message.attachments.isEmpty || (message.needsReply && message.folderRole == .inbox) {
                        HStack(spacing: 8) {
                            ForEach(message.attachments.prefix(2), id: \.filename) { file in
                                Text(file.filename).lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                            }
                            if message.needsReply && message.folderRole == .inbox {
                                Text("your turn").fontWeight(.bold).foregroundStyle(Palette.meText)
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.open(topic: message.matterKey, at: message.id) }
            .onTapGesture { model.selectedMessage = message.id }
            if let matter {
                PlacementBlock(message: message, matter: matter)
                    .frame(width: 236)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color(hex: 0xFFE9E0) : loose ? Palette.looseSoft : hovered ? Palette.chip.opacity(0.6) : .clear))
        .overlay {
            if loose { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.loose, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])) }
        }
        .padding(.vertical, loose ? 2 : 0)
        .onHover { hovered = $0 }
        .contextMenu { MailMenu(message: message) }
    }

    private var subject: String {
        let subject = Threading.normalizedSubject(message.subject)
        return subject.isEmpty ? "(no subject)" : subject
    }
}

/// Where a mail belongs, at a glance: tinted in its court's color with the court, sub-court and topic, and how
/// it got there. Without a place: RallyMail's suggestion, taken with one click.
struct PlacementBlock: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    let matter: Matter

    var body: some View {
        if let court = matter.spaceID {
            let color = CourtColor.of(court, model)
            Button { model.open(topic: matter.id, at: message.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        Text(model.space(court)?.name ?? "").fontWeight(.bold)
                        if let sub = model.subCourt(of: matter) { Text("› \(sub.name)") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x4D4A46))
                    .lineLimit(1)
                    Text(matter.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(model.placementNote(message, in: matter)).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.28)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(matter.title)")
        } else {
            let placement = model.placement(for: matter)
            VStack(alignment: .leading, spacing: 4) {
                Text(placement == nil ? "NO PLACE YET" : "NO PLACE · SUGGESTION")
                    .font(.system(size: 10, weight: .heavy)).tracking(0.4).foregroundStyle(Palette.meText)
                if let placement {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(placement.court, model)).frame(width: 8, height: 8)
                        Text(placementTitle(placement)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    Text(placement.why).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    HStack(spacing: 5) {
                        Button { model.accept(placement, for: matter.id) } label: {
                            Text("Take").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SmallButtonStyle(filled: true))
                        CourtMenu(matter: matter, title: "Other…")
                    }
                } else {
                    CourtMenu(matter: matter, title: "Choose court…")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0xE08A6C), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        }
    }

    private func placementTitle(_ placement: AppModel.Placement) -> String {
        if let topic = placement.topic, let target = model.matter(topic) { return "\(model.path(of: target) ?? "") › \(target.title)" }
        let court = model.space(placement.court)?.name ?? ""
        return placement.sub.map { "\(court) › \($0.name)" } ?? court
    }
}

/// Every court and its sub-courts, to put a topic somewhere by hand.
struct CourtMenu: View {
    @Environment(AppModel.self) private var model
    let matter: Matter
    var title = "Court…"

    var body: some View {
        Menu {
            ForEach(model.config.spaces) { court in
                let subs = model.subCourts(of: court.id)
                if subs.isEmpty {
                    Button(court.name) { model.setCourt(matter.id, court.id) }
                } else {
                    Menu(court.name) {
                        Button("\(court.name) (no sub-court)") { model.setCourt(matter.id, court.id) }
                        Divider()
                        ForEach(subs) { sub in
                            Button(sub.name) {
                                model.setCourt(matter.id, court.id)
                                model.setSubCourt(matter.id, sub.id)
                            }
                        }
                    }
                }
            }
            if matter.spaceID != nil {
                Divider()
                Button("No Court") { model.setCourt(matter.id, nil) }
            }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(SmallButtonStyle(filled: false))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The small buttons inside cards: dark when it is the expected action, outlined otherwise.
struct SmallButtonStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? Color.white : Palette.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filled ? Palette.ink : Palette.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filled ? Color.clear : Palette.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// The rare actions on a mail.
struct MailMenu: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage

    var body: some View {
        Button("Open Topic") { model.open(topic: message.matterKey, at: message.id) }
        Button(message.isRead ? "Mark as New" : "Seen") { model.setRead([message], !message.isRead) }
        Button("Forward…") { model.forward(message) }
        Divider()
        Button("Mark as Spam") { model.markSpam(thread: message.threadID) }
        Button("Delete Conversation", role: .destructive) { model.delete(thread: message.threadID) }
    }
}

/// A topic as one line: where the ball is, its name, new mail and when it last moved.
struct TopicLine: View {
    @Environment(AppModel.self) private var model
    let matter: Matter
    var showCourt = false
    var detail: String? = nil
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            BallGlyph(ball: matter.ball, width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(matter.title)
                    .font(.system(size: 12.5, weight: matter.unreadCount > 0 ? .bold : matter.ball == .quiet ? .regular : .semibold))
                    .foregroundStyle(matter.ball == .quiet && matter.unreadCount == 0 ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11.5))
                        .foregroundStyle(matter.ball == .mine ? Palette.meText : matter.ball == .theirs ? Palette.themText : Palette.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if showCourt, matter.spaceID != nil {
                RoundedRectangle(cornerRadius: 2).fill(CourtColor.of(matter.spaceID, model)).frame(width: 7, height: 7)
                    .help(model.path(of: matter) ?? "")
            }
            if matter.unreadCount > 0 {
                Circle().fill(Palette.me).frame(width: 7, height: 7)
            }
            Text(DateText.short(matter.lastDate)).font(.system(size: 11)).foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovered ? Palette.chip.opacity(0.6) : .clear)
        .onHover { hovered = $0 }
        .onTapGesture { model.open(topic: matter.id) }
        .help(matter.ask ?? matter.title)
    }
}

/// What a topic's line says under its name: what is asked, who you wait for, or when it last moved.
@MainActor
func topicDetail(_ matter: Matter, _ model: AppModel) -> String? {
    switch matter.ball {
    case .mine:
        // A mail the user sent sounds like the task is done: ask, quietly.
        return matter.tasks.contains { $0.doneSuggestedBy != nil } ? matter.ask.map { "\($0) · done?" } : matter.ask
    case .theirs: return matter.waitingOn.map { "waiting for \(model.shortName($0))" }
    case .quiet:
        let last = matter.conversations.first?.lastFrom
        return last.map { "last \(model.shortName($0))" }
    }
}

/// "11 days", "3 weeks": how long someone has had the user's mail.
enum Waiting {
    static func since(_ date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86400)
        switch days {
        case ..<1: return "today"
        case 1: return "1 day"
        case 2..<14: return "\(days) days"
        case 14..<60: return "\(days / 7) weeks"
        default: return "\(days / 30) months"
        }
    }

    static func isLong(_ date: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(date) > 7 * 86400 }

    /// Older than two months: a question or a wait that is most likely settled by now.
    static func isStale(_ date: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(date) > 60 * 86400 }
}
