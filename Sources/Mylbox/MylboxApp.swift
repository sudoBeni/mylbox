import AppKit
import MylboxCore
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
struct MylboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("mylbox", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands { MailCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct MailCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Mail") { model.newMail() }
                .keyboardShortcut("n")
        }
        CommandMenu("Message") {
            Button("Reply") { if let message = model.selectedMessages.first { model.reply(message, all: false) } }
                .keyboardShortcut("r")
            Button("Reply All") { if let message = model.selectedMessages.first { model.reply(message, all: true) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { if let message = model.selectedMessages.first { model.forward(message) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archive") { model.archive(model.selectedMessages) }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Delete") { model.delete(model.selectedMessages) }
                .keyboardShortcut(.delete)
            Button("Flag") { model.toggleFlag(model.selectedMessages) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Mark as Unread") { model.setRead(model.selectedMessages, false) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button("Check for New Mail") { Task { await model.syncAll() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
