import SwiftUI
import AppKit

@main
struct Pinna2HRTFApp: App {
    @NSApplicationDelegateAdaptor(Pinna2HRTFAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("Pinna2HRTF", id: "main") {
            ContentView(store: store)
                .onAppear { appDelegate.store = store }
                .frame(maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        }
        .defaultSize(width: 1320, height: 900)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Pinna2HRTF") { AboutWindow.show(externalDirectory: store.environment.externalDir) }
            }
            SidebarCommands()
            ProjectInspectorCommands()
            PipelineCommands()
            CommandGroup(replacing: .help) {
                Button("Online Documentation") {
                    NSWorkspace.shared.open(URL(string: "https://any2hrtf.github.io/Pinna2HRTF/docs/")!)
                }
            }
        }
        Settings {
            AppSettingsView(store: store)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class Pinna2HRTFAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.hasOutputOperations || store.geometryEditing || store.projectDuplicationRequest != nil {
            let alert = NSAlert(); alert.messageText = "Project files are being updated."
            alert.informativeText = "Quit after the operation finishes."; alert.addButton(withTitle: "OK"); alert.runModal()
            return .terminateCancel
        }
        if EditorWindowController.isSavingAny {
            let alert = NSAlert(); alert.messageText = "Project files are being updated."
            alert.informativeText = "Quit after the operation finishes."; alert.addButton(withTitle: "OK"); alert.runModal()
            return .terminateCancel
        }
        if EditorWindowController.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Review unsaved changes before quitting?"
            alert.informativeText = "If you don’t review them, your changes will be lost."
            alert.addButton(withTitle: "Review Changes…")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                EditorWindowController.reviewAll { closed in
                    if closed { DispatchQueue.main.async { NSApp.terminate(nil) } }
                }
                return .terminateCancel
            case .alertThirdButtonReturn:
                break
            default:
                return .terminateCancel
            }
        }
        EditorWindowController.discardAll()
        guard !store.runningProcesses.isEmpty || store.isCalculatingAutomaticMicrophone else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while a task is running?"
        alert.informativeText = "The task stops and its outputs may be incomplete."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        store.stopAllRunningProcesses { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let store { store.prepareForTermination() } else { ProcessLauncher.shared.terminateAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
