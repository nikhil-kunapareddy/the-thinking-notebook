import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` behave like a normal app too.
        NSApp.setActivationPolicy(.regular)
        AppAppearance.apply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ThinkingNotebookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var store: NoteStore

    init() {
        Prefs.register()
        _store = State(initialValue: NoteStore())
    }

    var body: some Scene {
        Window("The Thinking Notebook", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { store.createNote() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
