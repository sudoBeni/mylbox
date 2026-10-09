import RallyMailCore
import SwiftUI

/// One conversation from people in Open: who, the one-liner, the subject in fine print.
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var hovered = false

    private var others: [EmailAddress] { conversation.participants.filter { !model.isMe($0) } }
    private var selected: Bool { model.selectedThread == conversation.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Avatar(others.first ?? conversation.lastFrom, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.headlineName(conversation))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if conversation.needsReply {
                        Chip(text: "Reply", color: .orange)
                    }
                    if conversation.unreadCount > 0 {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    if let space = model.space(conversation.spaceID), model.spaceFilter == nil {
                        Chip(text: space.name, symbol: space.symbol)
                    }
                    Spacer(minLength: 0)
                }
                Text(conversation.headline)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(conversation.subject.isEmpty ? "(no subject)" : conversation.subject)
                    if conversation.messageCount > 1 { Text("· \(conversation.messageCount) messages") }
                    if conversation.hasAttachments { Image(systemName: "paperclip") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(DateText.short(conversation.lastDate))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if hovered || selected {
                    HStack(spacing: 4) {
                        RowButton(title: "Done") { model.done(conversation.id) }
                        RowButton(title: "Later") { model.later(conversation.id) }
                    }
                } else {
                    Color.clear.frame(height: 20)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .rowBackground(selected: selected, hovered: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { model.openedThread = conversation.id }
        .contextMenu { ConversationMenu(conversation: conversation) }
    }
}

/// Updates or Newsletters: one folded row, with a one-line preview and the mails inside when opened.
struct FoldedGroup: View {
    @Environment(AppModel.self) private var model
    let category: MailCategory
    let conversations: [Conversation]
    @State private var expanded = false
    @State private var hovered = false

    private var title: String { category == .newsletters ? "Newsletters" : "Updates" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: -8) {
                    ForEach(Array(conversations.prefix(4).enumerated()), id: \.offset) { _, conversation in
                        Avatar(conversation.lastFrom, size: 20)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    }
                }
                .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text("\(conversations.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if hovered || expanded {
                    RowButton(title: "Clear all") { model.clearFolded(category) }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
            if expanded {
                VStack(spacing: 0) {
                    ForEach(conversations) { conversation in
                        FoldedRow(conversation: conversation)
                    }
                }
                .padding(.leading, 46)
                .padding(.trailing, 10)
                .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .background(RoundedRectangle(cornerRadius: 10).fill(hovered && !expanded ? Color.primary.opacity(0.04) : .clear))
        .onHover { hovered = $0 }
    }

    private var preview: String {
        conversations.prefix(4).map { conversation in
            let who = conversation.lastFrom.displayName.split(separator: " ").first.map(String.init) ?? conversation.lastFrom.displayName
            return "\(who): \(conversation.headline)"
        }.joined(separator: " · ")
    }
}

struct FoldedRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(conversation.lastFrom.displayName).font(.system(size: 12, weight: .medium))
                    Text(conversation.headline).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            Spacer()
            Text(DateText.short(conversation.lastDate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if hovered {
                RowButton(title: "Done") { model.done(conversation.id, quiet: true) }
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.openedThread = conversation.id }
        .contextMenu { ConversationMenu(conversation: conversation) }
    }
}

/// A mail the user sent that got no answer yet.
struct WaitingRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass").foregroundStyle(.indigo).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(model.headlineName(conversation)).font(.system(size: 13, weight: .semibold))
                    Text("· \(conversation.headline)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text("sent \(DateText.short(conversation.lastDate)), no answer yet")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            if hovered || model.selectedThread == conversation.id {
                RowButton(title: "Nudge") { model.openedThread = conversation.id }
                RowButton(title: "Stop waiting") { model.dismissWaiting(conversation.id) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(model.selectedThread == conversation.id ? 0.16 : 0.08)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.openedThread = conversation.id }
        .contextMenu { ConversationMenu(conversation: conversation) }
    }
}

/// A conversation under Earlier: compact, one line, with Reopen on hover.
struct EarlierRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var hovered = false

    private var selected: Bool { model.selectedThread == conversation.id }
    private var other: EmailAddress { conversation.participants.first { !model.isMe($0) } ?? conversation.lastFrom }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(other, size: 26)
                .opacity(conversation.isFolded ? 0.6 : 1)
            HStack(spacing: 5) {
                Text(model.headlineName(conversation)).fontWeight(.medium)
                Text("· \(conversation.headline)").foregroundStyle(.secondary)
                if conversation.messageCount > 1 {
                    Text("\(conversation.messageCount) msgs").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if conversation.hasAttachments { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.tertiary) }
                if let until = conversation.snoozedUntil, until > Date() {
                    Chip(text: "later · \(DateText.short(until))", color: .indigo)
                }
                if let space = model.space(conversation.spaceID), model.spaceFilter == nil {
                    Chip(text: space.name)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            Spacer()
            Text(DateText.short(conversation.lastDate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if hovered || selected {
                RowButton(title: "Reopen") { model.reopen(conversation.id) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .rowBackground(selected: selected, hovered: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { model.openedThread = conversation.id }
        .contextMenu { ConversationMenu(conversation: conversation) }
    }
}

/// Everything that is not a button on the row: the rare actions.
struct ConversationMenu: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        Button("Open") { model.openedThread = conversation.id }
        if conversation.openCount > 0 {
            Button("Done") { model.done(conversation.id) }
            Button("Later") { model.later(conversation.id) }
        } else {
            Button("Reopen") { model.reopen(conversation.id) }
        }
        Divider()
        Menu("Space") {
            Button("None") { model.setSpace(conversation.id, space: nil) }
            ForEach(model.config.spaces) { space in
                Button(space.name) { model.setSpace(conversation.id, space: space.id) }
            }
        }
        if conversation.isFolded {
            Button("This is from a person") { model.markFromPerson(conversation.id) }
        } else {
            Button("Fold into Updates") { model.fold(conversation.id, as: .updates) }
            Button("Fold into Newsletters") { model.fold(conversation.id, as: .newsletters) }
        }
        Divider()
        Button("Mark as Spam") { model.markSpam(conversation.id) }
        Button("Delete", role: .destructive) { model.delete(conversation.id) }
    }
}
