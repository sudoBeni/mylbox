import AppKit
import RallyMailCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (swift run) instead of the .app bundle.
        NSApp.setActivationPolicy(.regular)
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

    private var selected: String? { model.selectedThread ?? model.openedThread }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Mail") { model.newMail() }
                .keyboardShortcut("n")
            Button("Search") { model.focusSearchToken += 1 }
                .keyboardShortcut("k")
        }
        CommandMenu("Conversation") {
            Button("Open") { if let selected { model.openedThread = selected } }
                .keyboardShortcut("o")
            Button("Done") { if let selected { model.done(selected) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Later") { if let selected { model.later(selected) } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Reopen") { if let selected { model.reopen(selected) } }
            Divider()
            Button("Reply") {
                if let selected { model.openedThread = selected }
                NotificationCenter.default.post(name: .focusReply, object: nil)
            }
            .keyboardShortcut("r")
            Button("Put into Space…") {
                if let selected { model.openedThread = selected }
                NotificationCenter.default.post(name: .openSpacePicker, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Mark as Spam") { if let selected { model.markSpam(selected) } }
            Button("Delete") { if let selected { model.delete(selected) } }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Check for New Mail") { Task { await model.syncAll() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
