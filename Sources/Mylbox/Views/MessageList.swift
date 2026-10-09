import MylboxCore
import SwiftUI

struct MessageList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.messages.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol,
                                       description: Text(model.search.isEmpty ? emptyText : "No mail matches your search."))
            } else {
                List(selection: $model.selectedIDs) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message)
                            .tag(message.id)
                            .swipeActions(edge: .trailing) {
                                if message.folderRole == .inbox && !message.isArchived {
                                    Button { model.archive([message]) } label: { Label("Archive", systemImage: "archivebox") }
                                        .tint(.indigo)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { model.setRead([message], !message.isRead) } label: {
                                    Label(message.isRead ? "Unread" : "Read",
                                          systemImage: message.isRead ? "envelope.badge" : "envelope.open")
                                }
                                .tint(.blue)
                            }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: Int64.self) { ids in
                    MessageMenu(messages: model.messages.filter { ids.contains($0.id) })
                }
                .onKeyPress(characters: .init(charactersIn: "erfu#")) { press in
                    handleKey(press.characters)
                }
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { model.newMail() } label: { Label("New Mail", systemImage: "square.and.pencil") }
                    .help("New mail (⌘N)")
            }
        }
    }

    private func handleKey(_ characters: String) -> KeyPress.Result {
        let selected = model.selectedMessages
        guard !selected.isEmpty else { return .ignored }
        switch characters {
        case "e": model.archive(selected)
        case "r": model.reply(selected[0], all: false)
        case "f": model.forward(selected[0])
        case "u": model.setRead(selected, false)
        case "#": model.delete(selected)
        default: return .ignored
        }
        return .handled
    }

    private var subtitle: String {
        let unread = model.messages.filter { !$0.isRead }.count
        return unread > 0 ? "\(unread) unread" : "\(model.messages.count) mails"
    }

    private var emptyTitle: String {
        if !model.search.isEmpty { return "No results" }
        return model.selection == .inbox ? "Inbox zero" : "Nothing here"
    }

    private var emptySymbol: String {
        model.selection == .inbox && model.search.isEmpty ? "checkmark.circle" : "tray"
    }

    private var emptyText: String {
        switch model.selection {
        case .inbox: "You are all caught up."
        case .space: "Add mails with the space menu, or create a rule that fills this space automatically."
        default: ""
        }
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(correspondent)
                        .font(.body.weight(message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.isFlagged {
                        Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption)
                    }
                    if !message.attachments.isEmpty {
                        Image(systemName: "paperclip").foregroundStyle(.secondary).font(.caption)
                    }
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.callout.weight(message.isRead ? .regular : .medium))
                    .lineLimit(1)
                Text(message.summary ?? message.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if message.needsReply || !message.spaceIDs.isEmpty {
                    HStack(spacing: 4) {
                        if message.needsReply {
                            Chip(text: "Reply", symbol: "arrowshape.turn.up.left", color: .orange)
                        }
                        ForEach(model.config.spaces.filter { message.spaceIDs.contains($0.id) }) { space in
                            Chip(text: space.name, symbol: space.symbol, color: .accentColor)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var correspondent: String {
        if message.folderRole == .sent {
            return "To: " + (message.to.first?.displayName ?? "")
        }
        return message.from.displayName
    }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(message.date) { return message.date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(message.date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: message.date, to: Date()).day, days < 7 {
            return message.date.formatted(.dateTime.weekday(.wide))
        }
        return message.date.formatted(date: .numeric, time: .omitted)
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Context menu actions shared by the list and the detail view.
struct MessageMenu: View {
    @Environment(AppModel.self) private var model
    let messages: [MailMessage]

    var body: some View {
        if messages.count == 1, let message = messages.first {
            Button("Reply") { model.reply(message, all: false) }
            Button("Reply All") { model.reply(message, all: true) }
            Button("Forward") { model.forward(message) }
            Divider()
        }
        if messages.contains(where: { !$0.isArchived && $0.folderRole == .inbox }) {
            Button("Archive") { model.archive(messages) }
        }
        if messages.contains(where: \.isArchived) {
            Button("Move to Inbox") { model.unarchive(messages) }
        }
        Button(messages.allSatisfy(\.isRead) ? "Mark as Unread" : "Mark as Read") {
            model.setRead(messages, !messages.allSatisfy(\.isRead))
        }
        Button(messages.allSatisfy(\.isFlagged) ? "Unflag" : "Flag") { model.toggleFlag(messages) }
        Button(messages.allSatisfy(\.needsReply) ? "Doesn't Need Reply" : "Needs Reply") {
            model.setNeedsReply(messages, !messages.allSatisfy(\.needsReply))
        }
        if messages.allSatisfy({ $0.category == .spam }) {
            Button("Not Spam") { model.notSpam(messages) }
        } else if messages.contains(where: { $0.folderRole == .inbox }) {
            Button("Mark as Spam") { model.markSpam(messages) }
        }
        Menu("Move to") {
            ForEach(MailCategory.allCases.filter { $0 != .spam }) { category in
                Button(category.displayName) { model.setCategory(messages, category) }
            }
        }
        SpaceMenu(messages: messages)
        if messages.count == 1, let message = messages.first, message.folderRole == .inbox {
            Button("New Rule for \(message.from.address)…") {
                model.ruleDraft = Rule(name: "Mails from \(message.from.displayName)",
                                       conditions: [RuleCondition(field: .from, op: .contains, value: message.from.address)])
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(messages) }
    }
}

struct SpaceMenu: View {
    @Environment(AppModel.self) private var model
    let messages: [MailMessage]

    var body: some View {
        Menu("Spaces") {
            if model.config.spaces.isEmpty {
                Text("No spaces yet")
            }
            ForEach(model.config.spaces) { space in
                Toggle(space.name, isOn: Binding(
                    get: { messages.allSatisfy { $0.spaceIDs.contains(space.id) } },
                    set: { _ in model.toggleSpace(space, for: messages) }))
            }
        }
    }
}
