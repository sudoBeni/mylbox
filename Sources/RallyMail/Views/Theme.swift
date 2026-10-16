import SwiftUI

/// The app's colors. RallyMail is light only: a warm paper ground, white panels, orange for your side of the
/// net and blue for theirs.
enum Palette {
    static let ground = Color(hex: 0xF5F4F1)
    static let panel = Color.white
    static let side = Color(hex: 0xEEECE8)
    static let bar = Color(hex: 0xFBFAF8)
    static let ink = Color(hex: 0x1C1B19)
    static let muted = Color(hex: 0x6B6863)
    static let faint = Color(hex: 0x8A857E)
    static let line = Color(hex: 0xE1DED8)
    static let chip = Color(hex: 0xF1EEE9)
    /// Your side: the ball is with you.
    static let me = Color(hex: 0xF0582F)
    static let meText = Color(hex: 0xB8401A)
    static let meSoft = Color(hex: 0xFDF2ED)
    static let meLine = Color(hex: 0xF0B39D)
    static let hot = Color(hex: 0xD94A22)
    /// Their side: you wait.
    static let them = Color(hex: 0x4F7FBF)
    static let themText = Color(hex: 0x355F95)
    static let themSoft = Color(hex: 0xEEF3FA)
    static let themLine = Color(hex: 0xDCE5F1)
    /// Something done or confirmed.
    static let okText = Color(hex: 0x2C6A4D)
    static let ok = Color(hex: 0x3F8F6A)
    static let okSoft = Color(hex: 0xEDF6F1)
    /// Mail that has no place yet.
    static let loose = Color(hex: 0xE7A58F)
    static let looseSoft = Color(hex: 0xFFFAF7)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Small caps section titles ("YOUR SIDE · 14").
struct SectionTitle: View {
    let text: String
    var color: Color = Palette.muted

    init(_ text: String, color: Color = Palette.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(color)
    }
}

/// A rounded white card with a hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    var fill: Color = Palette.panel
    var stroke: Color = Palette.line
    var radius: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke))
    }
}

/// A capsule filter or action ("All", "New only · 23").
struct Pill: View {
    let title: String
    var on = false
    var color: Color?
    var count: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9) }
                Text(title).lineLimit(1)
                if let count, !count.isEmpty {
                    Text(count).fontWeight(.bold).foregroundStyle(on ? Color(hex: 0xF7B49C) : Palette.meText)
                }
            }
            .font(.system(size: 12, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? Color.white : Palette.ink)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(on ? Palette.ink : Palette.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Palette.ink : Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The deadline badge: red for today and tomorrow, grey after that.
struct DueBadge: View {
    let date: Date

    var body: some View {
        let hot = DueText.isHot(date)
        Text(DueText.label(date))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(hot ? Color.white : Palette.muted)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(hot ? Palette.hot : Palette.chip, in: Capsule())
            .fixedSize()
    }
}

enum DueText {
    /// Overdue, today or tomorrow.
    static func isHot(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        guard let limit = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return false }
        return date < limit
    }

    static func label(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return "overdue"
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
