import RallyMailCore
import SwiftUI

/// The whole app: one list (Open on top, Earlier below), a conversation drawer on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var editingSpace: Space?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Divider()
                if model.config.accounts.isEmpty {
                    WelcomeView()
                } else {
                    FilterStrip(editingSpace: $editingSpace)
                    if let space = model.space(model.spaceFilter) {
                        SpaceBar(space: space, editingSpace: $editingSpace)
                    }
                    ConversationList()
                        .focusable()
                        .focused($listFocused)
                        .focusEffectDisabled()
                        .onKeyPress(phases: .down) { press in handleKey(press) }
                }
                Divider()
                keysBar
            }
            .frame(minWidth: 460)
            if model.openedThread != nil || model.newDraft != nil {
                Divider()
                Group {
                    if let thread = model.openedThread {
                        ConversationView(threadID: thread)
                            .id(thread)
                    } else if model.newDraft != nil {
                        NewMailView()
                    }
                }
                .frame(width: 520)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.openedThread == nil && model.newDraft == nil)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.bottom, 44)
            }
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }.padding()
            }
        }
        .sheet(item: $editingSpace) { SpaceEditor(space: $0) }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
        .onAppear { listFocused = true }
        .task { await Snapshot.runIfRequested(model) }
    }

    // MARK: Top bar

    private var topBar: some View {
        @Bindable var model = model
        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("RallyMail").font(.system(size: 14, weight: .semibold))
                Text(model.totalOpen > 0 ? "\(model.totalOpen) need you" : "up to date")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all mail", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { listFocused = true }
                    .onKeyPress(.escape) {
                        model.search = ""
                        listFocused = true
                        return .handled
                    }
                if model.search.isEmpty {
                    Text("⌘K").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Button { model.search = ""; listFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 280)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            SyncStatusView()
            Button { model.newMail() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New mail (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var keysBar: some View {
        HStack(spacing: 14) {
            key("J K", "Move"); key("D", "Done"); key("L", "Later"); key("R", "Reply"); key("P", "Space"); key("↩", "Open"); key("⌘K", "Search")
            Spacer()
            if model.config.accounts.count > 0 {
                Text("\(model.config.accounts.count) account\(model.config.accounts.count == 1 ? "" : "s")")
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func key(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isSubset(of: [.shift]) else { return .ignored }
        switch press.key {
        case .downArrow: model.moveSelection(1); return .handled
        case .upArrow: model.moveSelection(-1); return .handled
        case .return:
            if let selected = model.selectedThread { model.openedThread = selected }
            return .handled
        case .escape:
            model.openedThread = nil
            model.newDraft = nil
            return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "d":
            guard let selected = model.selectedThread, let conversation = model.conversation(selected) else { return .ignored }
            if conversation.openCount > 0 { model.done(selected) } else { model.reopen(selected) }
        case "l":
            guard let selected = model.selectedThread else { return .ignored }
            model.later(selected)
        case "r", "p":
            guard let selected = model.selectedThread else { return .ignored }
            model.openedThread = selected
            NotificationCenter.default.post(name: press.characters.lowercased() == "r" ? .focusReply : .openSpacePicker, object: nil)
        default: return .ignored
        }
        return .handled
    }
}

extension Notification.Name {
    static let focusReply = Notification.Name("RallyMail.focusReply")
    static let openSpacePicker = Notification.Name("RallyMail.openSpacePicker")
}

// MARK: - Filter strip and space bar

struct FilterStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var editingSpace: Space?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, "Open", count: model.totalOpen)
                ForEach(model.config.spaces) { space in
                    chip(space.id, space.name, count: model.openCounts[space.id] ?? 0)
                        .contextMenu {
                            Button("Edit Space…") { editingSpace = space }
                            if let folder = space.exportFolder {
                                Button("Show Export in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                            }
                            Divider()
                            Button("Delete Space", role: .destructive) { model.removeSpace(space) }
                        }
                }
                Button { editingSpace = Space(name: "") } label: {
                    Text("+ New space").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chip(_ id: UUID?, _ title: String, count: Int) -> some View {
        let active = model.spaceFilter == id
        return Button {
            model.spaceFilter = id
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(active ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(active ? .white : .primary)
            .background(active ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SpaceBar: View {
    @Environment(AppModel.self) private var model
    let space: Space
    @Binding var editingSpace: Space?

    var body: some View {
        let count = (try? model.store.messageCount(space: space.id)) ?? 0
        HStack(spacing: 8) {
            Image(systemName: space.symbol).foregroundStyle(Color.accentColor)
            Text(space.name).fontWeight(.semibold)
            Text("· \(count) mails")
            if let folder = space.exportFolder, !folder.isEmpty {
                Text("· mirrored as Markdown to")
                Text((folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                    .controlSize(.small)
            } else {
                Text("· not shared with a repo yet")
                Spacer()
                Button("Share with a repo…") { editingSpace = space }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - The list

struct ConversationList: View {
    @Environment(AppModel.self) private var model

    private var earlierGroups: [(label: String, items: [Conversation])] {
        var groups: [(String, [Conversation])] = []
        for conversation in model.earlier {
            let label = TimeGroup.label(for: conversation.lastDate)
            if groups.last?.0 == label { groups[groups.count - 1].1.append(conversation) } else { groups.append((label, [conversation])) }
        }
        return groups.map { (label: $0.0, items: $0.1) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3, pinnedViews: .sectionHeaders) {
                    if !model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResults
                    } else {
                        openSection
                        earlierSections
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, model.search.isEmpty ? 44 : 10)
                .padding(.bottom, 20)
                .id("top")
            }
            // An opaque background: text then renders without vibrancy, the same in every context.
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .trailing) {
                if model.search.isEmpty {
                    JumpRail(labels: ["Open"] + earlierGroups.map(\.label)) { label in
                        withAnimation { proxy.scrollTo(label == "Open" ? "top" : "group-\(label)", anchor: .top) }
                    }
                    .padding(.trailing, 4)
                    .padding(.vertical, 10)
                }
            }
            .onChange(of: model.selectedThread) { _, selected in
                if let selected { proxy.scrollTo("row-\(selected)", anchor: nil) }
            }
        }
    }

    @ViewBuilder private var openSection: some View {
        Section {
            if model.open.isEmpty && model.folded.isEmpty && model.waiting.isEmpty {
                VStack(spacing: 6) {
                    Text("You're up to date.").font(.system(size: 22, weight: .medium, design: .serif))
                    Text(model.spaceFilter == nil
                         ? "New mail from people appears here. Updates and newsletters stay folded below."
                         : "Nothing open in this space. Earlier mail is below.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
            ForEach(model.open) { conversation in
                ConversationRow(conversation: conversation).id("row-\(conversation.id)")
            }
            if let updates = model.folded[.updates], !updates.isEmpty {
                FoldedGroup(category: .updates, conversations: updates).padding(.top, 6)
            }
            if let newsletters = model.folded[.newsletters], !newsletters.isEmpty {
                FoldedGroup(category: .newsletters, conversations: newsletters).padding(.top, 4)
            }
            if !model.waiting.isEmpty {
                sectionLabel("Waiting for", detail: "you asked, no answer yet").padding(.top, 10)
                ForEach(model.waiting) { conversation in
                    WaitingRow(conversation: conversation).id("row-\(conversation.id)")
                }
            }
        } header: {
            header("Needs you", detail: model.open.isEmpty ? nil : "\(model.open.count) open")
        }
    }

    @ViewBuilder private var earlierSections: some View {
        @Bindable var model = model
        Section {
            HStack(spacing: 8) {
                Text("Earlier · nothing is deleted")
                    .font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                Toggle("People only", isOn: $model.peopleOnly).toggleStyle(.button).controlSize(.small)
                Toggle("With attachments", isOn: $model.attachmentsOnly).toggleStyle(.button).controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 2)
        }
        ForEach(earlierGroups, id: \.label) { group in
            Section {
                ForEach(group.items) { conversation in
                    EarlierRow(conversation: conversation)
                        .id("row-\(conversation.id)")
                        .onAppear {
                            if conversation.id == model.earlier.last?.id { model.loadMoreEarlier() }
                        }
                }
            } header: {
                header(group.label, detail: "\(group.items.count)").id("group-\(group.label)")
            }
        }
        if model.earlier.isEmpty {
            Text(model.peopleOnly || model.attachmentsOnly ? "Nothing matches these filters." : "Nothing here yet. Done conversations land here.")
                .font(.callout).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    @ViewBuilder private var searchResults: some View {
        let groups = Dictionary(grouping: model.searchResults) { model.headlineName($0) }
            .sorted { ($0.value.first?.lastDate ?? .distantPast) > ($1.value.first?.lastDate ?? .distantPast) }
        Section {
            if model.searchResults.isEmpty {
                Text("Nothing for “\(model.search)”\(model.space(model.spaceFilter).map { " in \($0.name)" } ?? ""). Try a name, a word from the mail, or a file name.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            ForEach(groups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Avatar(group.value[0].participants.first { !model.isMe($0) } ?? group.value[0].lastFrom, size: 22)
                        Text(group.key).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(group.value.count) conversation\(group.value.count == 1 ? "" : "s")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    ForEach(group.value) { conversation in
                        EarlierRow(conversation: conversation).id("row-\(conversation.id)")
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 8)
            }
        } header: {
            let scope = model.space(model.spaceFilter).map { "only \($0.name)" } ?? "open, done, folded and sent mail"
            header("\(model.searchResults.count) result\(model.searchResults.count == 1 ? "" : "s")", detail: scope)
        }
    }

    private func header(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary) }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
    }
}

/// The date rail on the right: click a month or year to jump there.
struct JumpRail: View {
    let labels: [String]
    let jump: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(labels, id: \.self) { label in
                Button(TimeGroup.short(label)) { jump(label) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: label.count == 4 ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2).padding(.horizontal, 4)
                    .help(label)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 34)
    }
}

// MARK: - Small views

struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).lineLimit(1)
            if let undo = toast.undo {
                Button("Undo") { undo(); model.toast = nil }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.9), in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
        .task {
            try? await Task.sleep(for: .seconds(12))
            dismiss()
        }
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 6) {
            if !model.accountErrors.values.compactMap({ $0 }).isEmpty {
                Button { openSettings() } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(model.accountErrors.values.compactMap { $0 }.joined(separator: "\n"))
            }
            if model.isSyncing {
                ProgressView().controlSize(.mini)
                if let progress = model.syncProgress, progress > 0 { Text("\(progress) new") } else { Text("Checking…") }
            } else if let progress = model.triageProgress {
                Image(systemName: "sparkles")
                Text(progress)
            } else if let last = model.lastSync {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(last.formatted(date: .omitted, time: .shortened))
            }
            Button { Task { await model.syncAll() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isSyncing)
                .help("Check for new mail (⇧⌘N)")
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

struct WelcomeView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            Text("Welcome to RallyMail").font(.largeTitle.weight(.semibold))
            Text("Add your mail accounts to get started.\nGmail, iCloud, Outlook and any IMAP provider work.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Account…") { openSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Development aid: RALLYMAIL_SNAPSHOT=/path.png renders the window to a file and quits.
/// RALLYMAIL_SNAPSHOT_SCENE=conversation opens the first conversation first; =new opens a new mail.
enum Snapshot {
    @MainActor static func runIfRequested(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RALLYMAIL_SNAPSHOT"] else { return }
        if let appearance = environment["RALLYMAIL_SNAPSHOT_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        try? await Task.sleep(for: .seconds(2))
        switch environment["RALLYMAIL_SNAPSHOT_SCENE"] {
        case "conversation":
            model.openedThread = model.open.first?.id
        case "new":
            model.newMail()
        case "space":
            model.spaceFilter = model.config.spaces.first?.id
        case "search":
            model.search = environment["RALLYMAIL_SNAPSHOT_QUERY"] ?? "Rechnung"
        default: break
        }
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApplication.shared.terminate(nil)
    }
}
