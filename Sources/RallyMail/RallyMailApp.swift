import AppKit
import RallyMailCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (swift run) instead of the .app bundle.
        NSApp.setActivationPolicy(.regular)
        // RallyMail is light only.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct RallyMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("RallyMail", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MailCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct MailCommands: Commands {
    let model: AppModel

    /// The topic the commands act on: the open one, or the one of the picked mail.
    private var topic: String? {
        if case .topic(let key) = model.screen { return key }
        return model.selection?.matterKey
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Mail") { model.newMail() }
                .keyboardShortcut("n")
            Button("Search") { model.focusSearchToken += 1 }
                .keyboardShortcut("k")
        }
        CommandMenu("Go") {
            Button("Play") { model.screen = .play }.keyboardShortcut("1")
            Button("Inbox") { model.screen = .inbox }.keyboardShortcut("2")
            Button("Courts") { model.screen = .courts(nil) }.keyboardShortcut("3")
            Divider()
            Button("Sorting Assistant…") { model.screen = .sorting }
        }
        CommandMenu("Topic") {
            Button("Open Topic") { if let topic { model.open(topic: topic, at: model.selectedMessage) } }
                .keyboardShortcut("o")
            Button("Reply") {
                if let topic { model.open(topic: topic) }
                NotificationCenter.default.post(name: .focusReply, object: nil)
            }
            .keyboardShortcut("r")
            Divider()
            Button("Quiet") { if let topic { model.quiet(topic) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Later") { if let topic { model.later(topic) } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Seen") { if let selection = model.selection { model.markSeen([selection]) } }
                .keyboardShortcut("e")
            Button("Mark as Spam") { if let selection = model.selection { model.markSpam(thread: selection.threadID) } }
            Divider()
            Button("Check for New Mail") { Task { await model.syncAll() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
