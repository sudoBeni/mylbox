import RallyMailCore
import SwiftUI

/// Initials in a colored circle; the color follows the address so one person always looks the same.
struct Avatar: View {
    let address: EmailAddress
    var size: CGFloat = 32
    var isMe = false
    var dashed = false

    init(_ address: EmailAddress, size: CGFloat = 32, isMe: Bool = false, dashed: Bool = false) {
        self.address = address
        self.size = size
        self.isMe = isMe
        self.dashed = dashed
    }

    init(name: String, size: CGFloat = 32) {
        self.init(EmailAddress(name: name, address: name), size: size)
    }

    var body: some View {
        let name = address.displayName
        let initials = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "," })
            .prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(isMe ? Color.secondary : Self.color(for: address.address), in: Circle())
            .overlay {
                if dashed {
                    Circle().strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .padding(-2)
                }
            }
            .help(address.formatted)
    }

    static func color(for key: String) -> Color {
        let hue = Double(key.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 3600 }) / 3600
        return Color(hue: hue, saturation: 0.42, brightness: 0.62)
    }
}

/// A row of overlapping avatars.
struct AvatarStack: View {
    let people: [EmailAddress]
    var size: CGFloat = 24
    var me: (EmailAddress) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(people.prefix(5).enumerated()), id: \.offset) { _, person in
                Avatar(person, size: size, isMe: me(person))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            if people.count > 5 {
                Text("+\(people.count - 5)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, size * 0.4)
            }
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// A small, borderless action that appears on hover.
struct RowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

extension View {
    /// Highlights the keyboard-selected row.
    func rowBackground(selected: Bool, hovered: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.14) : hovered ? Color.primary.opacity(0.05) : Color.clear)
        )
    }
}
