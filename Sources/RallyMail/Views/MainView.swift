import RallyMailCore
import SwiftUI

/// The whole app: the top bar with Play, Inbox and Courts; below it the place that is open. An open topic has the
/// court in small on its left and what it is about on its right; the Inbox reads the picked mail on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Width of the column on the right; drag its edge to change it.
    @AppStorage("sideWidth") private var sideWidth: Double = 340

    var body: some View {
        VStack(spacing: 0) {
            if !model.config.accounts.isEmpty { TopBar() }
            GeometryReader { geometry in
                Group {
                    if model.config.accounts.isEmpty {
                        WelcomeView()
                    } else if model.newDraft != nil {
                        NewMailView()
                    } else {
                        switch model.screen {
                        case .play: PlayView()
                        case .inbox: withSide(InboxView(), width: geometry.size.width, least: 520)
                        case .courts(let id): CourtsView(courtID: id)
                        case .topic(let key):
                            HStack(spacing: 0) {
                                if geometry.size.width > 1100 {
                                    MiniField().frame(width: 250)
                                    Rectangle().fill(Palette.line).frame(width: 1)
                                }
                                withSide(TopicView(key: key).id(key), width: geometry.size.width - (geometry.size.width > 1100 ? 251 : 0), least: 460)
                            }
                        case .sorting: withSide(SortingView(), width: geometry.size.width, least: 520)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.ground)
        .environment(\.colorScheme, .light)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.bottom, 24)
            }
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }.padding()
            }
        }
        .animation(.snappy(duration: 0.2), value: model.toast?.id)
        .onKeyPress(.escape) {
            if model.newDraft != nil { model.newDraft = nil; return .handled }
            if model.selectedMessage != nil { model.selectedMessage = nil; return .handled }
            return .ignored
        }
        .task { await Snapshot.runIfRequested(model) }
    }

    /// The main content with the right column (reading pane, topic info) when there is room for both.
    @ViewBuilder private func withSide(_ content: some View, width: CGFloat, least: CGFloat) -> some View {
        let side = min(min(max(sideWidth, 260), 620), width - least - 8)
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if side >= 260 {
                ResizeHandle(width: $sideWidth, range: 260...620, reset: 340)
                SidePanel().frame(width: side)
            }
        }
    }
}

extension Notification.Name {
    static let focusReply = Notification.Name("RallyMail.focusReply")
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

/// The edge between list and conversation: drag it to make the conversation wider or narrower.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// The width a double-click goes back to.
    var reset: Double = 520
    @State private var start: Double?
    @State private var hovered = false

    var body: some View {
        Rectangle()
            .fill(hovered || start != nil ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1))
            .frame(width: hovered || start != nil ? 2 : 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if start == nil { start = width }
                        width = min(max((start ?? width) - value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = reset }
            .help("Drag to resize · double-click to reset")
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
            }
            Button { Task { await model.syncAll() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isSyncing)
                .help(model.lastSync.map { "Checked at \($0.formatted(date: .omitted, time: .shortened)) · check again (⇧⌘N)" }
                      ?? "Check for new mail (⇧⌘N)")
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
/// RALLYMAIL_SNAPSHOT_SCENE=inbox, =courts (the first court), =topic (one with several conversations), =topic-focus (opened at an older mail),
/// =new (a new mail), =search (RALLYMAIL_SNAPSHOT_QUERY); without a scene the Play screen.
/// RALLYMAIL_SNAPSHOT_WIDTH=1300 sets the window width first.
enum Snapshot {
    @MainActor static func runIfRequested(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RALLYMAIL_SNAPSHOT"] else { return }
        if let appearance = environment["RALLYMAIL_SNAPSHOT_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if let width = environment["RALLYMAIL_SNAPSHOT_WIDTH"].flatMap(Double.init),
           let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
        }
        try? await Task.sleep(for: .seconds(2))
        switch environment["RALLYMAIL_SNAPSHOT_SCENE"] {
        case "inbox":
            model.screen = .inbox
            model.selectedMessage = model.feed.first?.id
        case "courts", "overview", "court":
            // RALLYMAIL_SNAPSHOT_QUERY picks a court by name.
            let name = environment["RALLYMAIL_SNAPSHOT_QUERY"]?.lowercased()
            model.screen = .courts(model.config.spaces.first { name != nil && $0.name.lowercased().contains(name!) }?.id)
        case "topic", "chat", "conversation":
            let topic = model.matters.first { $0.conversations.count > 1 } ?? model.matters.first { $0.ball == .mine }
            if let topic { model.open(topic: topic.id) }
        case "topic-focus":
            // The topic with the most mail, opened at its second mail.
            if let topic = model.matters.max(by: { $0.messageCount < $1.messageCount }),
               let mail = try? model.store.messages(threads: topic.threadIDs).dropFirst().first {
                model.open(topic: topic.id, at: mail.id)
            }
        case "sorting":
            model.screen = .sorting
            await model.startSorting()
        case "new":
            model.newMail()
        case "search":
            model.search(environment["RALLYMAIL_SNAPSHOT_QUERY"] ?? "Rechnung")
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
