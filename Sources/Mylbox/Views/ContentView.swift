import MylboxCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            MessageList()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
        } detail: {
            if model.selectedMessages.count == 1, let message = model.selectedMessages.first {
                MessageDetail(message: message)
                    .id(message.id)
            } else if model.selectedMessages.count > 1 {
                MultiSelectionView(messages: model.selectedMessages)
            } else if model.config.accounts.isEmpty {
                WelcomeView()
            } else {
                ContentUnavailableView("No mail selected", systemImage: "envelope.open",
                                       description: Text("Select a mail, or press ⌘N to write one."))
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search mail")
        .sheet(item: $model.compose) { draft in
            ComposeView(draft: draft)
        }
        .sheet(item: $model.ruleDraft) { rule in
            RuleEditor(rule: rule)
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
                    .padding()
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var editingSpace: Space?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                row(.inbox, "Inbox", "tray.fill", count: model.counts[.inbox])
                row(.needsReply, "Needs Reply", "arrowshape.turn.up.left", count: model.counts[.needsReply])
                row(.category(.updates), "Updates", MailCategory.updates.symbol, count: model.counts[.category(.updates)])
                row(.category(.newsletters), "Newsletters", MailCategory.newsletters.symbol,
                    count: model.counts[.category(.newsletters)])
            }
            Section("Mail") {
                row(.flagged, "Flagged", "flag")
                row(.sent, "Sent", "paperplane")
                row(.archive, "Archive", "archivebox")
                row(.category(.spam), "Spam", MailCategory.spam.symbol)
                row(.all, "All Mail", "tray.2")
            }
            Section {
                ForEach(model.config.spaces) { space in
                    Label(space.name, systemImage: space.symbol)
                        .tag(SidebarItem.space(space.id))
                        .contextMenu {
                            Button("Edit Space…") { editingSpace = space }
                            if let folder = space.exportFolder {
                                Button("Show Export in Finder") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                                }
                            }
                            Divider()
                            Button("Delete Space", role: .destructive) { model.removeSpace(space) }
                        }
                }
            } header: {
                HStack {
                    Text("Spaces")
                    Spacer()
                    Button {
                        editingSpace = Space(name: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New space")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncStatusView() }
        .sheet(item: $editingSpace) { space in
            SpaceEditor(space: space)
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ symbol: String, count: Int? = nil) -> some View {
        Label(title, systemImage: symbol)
            .badge(count ?? 0)
            .tag(item)
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var syncErrors: [String] {
        model.accountErrors.map { id, error in "\(model.account(id)?.email ?? "Account"): \(error)" }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(syncErrors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .onTapGesture { openSettings() }
            }
            HStack(spacing: 6) {
                if model.isSyncing {
                    ProgressView().controlSize(.mini)
                    Text("Checking mail…")
                } else if let progress = model.modelDownloadProgress {
                    ProgressView(value: progress).frame(width: 60)
                    Text("Downloading AI model")
                } else if let progress = model.modelStatus ?? model.triageProgress {
                    Image(systemName: "sparkles")
                    Text(progress)
                } else if let last = model.lastSync {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                } else if model.config.accounts.isEmpty {
                    Text("No account yet")
                }
                Spacer()
                Button {
                    Task { await model.syncAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isSyncing)
                .help("Check for new mail (⇧⌘N)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
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

struct WelcomeView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to mylbox").font(.largeTitle.weight(.semibold))
            Text("Add your mail accounts to get started.\nGmail, iCloud, Outlook and any IMAP provider work.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Account…") { openSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    let messages: [MailMessage]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("\(messages.count) mails selected").font(.title2)
            HStack {
                Button("Archive") { model.archive(messages) }
                Button("Mark Read") { model.setRead(messages, true) }
                SpaceMenu(messages: messages)
                    .fixedSize()
            }
        }
    }
}
