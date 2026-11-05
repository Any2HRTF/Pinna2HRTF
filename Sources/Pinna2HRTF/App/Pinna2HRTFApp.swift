import SwiftUI
import AppKit

@main
struct Pinna2HRTFApp: App {
    @NSApplicationDelegateAdaptor(Pinna2HRTFAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Writing to a subprocess that already exited must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("Pinna2HRTF", id: "main") {
            ContentView(store: store)
                .onAppear { appDelegate.store = store }
                .frame(minWidth: PressureFieldView.minimumViewerWidth + 590, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        }
        .defaultSize(width: 1320, height: 900)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Pinna2HRTF") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "Pinna2HRTFDisplayVersion") as? String
                        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
                    let revision = Bundle.main.object(forInfoDictionaryKey: "Pinna2HRTFGitHead") as? String ?? "unknown"
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    let credits = NSAttributedString(
                        string: "Ear-mesh preprocessing, Mesh2PPM inference, Mesh2HRTF simulation, and SOFA export.\n\nSource revision: \(revision)",
                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                     .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationVersion: version, .credits: credits])
                }
            }
            SidebarCommands()
            ProjectInspectorCommands()
            PipelineCommands()
            CommandGroup(replacing: .help) {
                Button("Pinna2HRTF Help") {
                    openWindow(id: "help")
                }
            }
        }
        Window("Pinna2HRTF Help", id: "help") {
            DocumentationView()
        }
        .defaultSize(width: 960, height: 720)
    }
}

@MainActor
final class Pinna2HRTFAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.hasOutputOperations || store.geometryEditing || store.projectDuplicationRequest != nil {
            let alert = NSAlert(); alert.messageText = "Project files are being updated"
            alert.informativeText = "Wait for the operation to finish before quitting."; alert.addButton(withTitle: "OK"); alert.runModal()
            return .terminateCancel
        }
        if store.meshEditorRequest != nil || store.ppmFittingRequest != nil {
            let alert = NSAlert(); alert.messageText = "Close the editor before quitting"
            alert.informativeText = "Save your changes or cancel editing, then quit."; alert.addButton(withTitle: "OK"); alert.runModal()
            return .terminateCancel
        }
        guard !store.runningProcesses.isEmpty || store.environmentProcess != nil || store.isCalculatingAutomaticMicrophone else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A pipeline task is still running"
        alert.informativeText = "Quitting will stop the task and may leave incomplete outputs. Do you want to quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        store.stopAllRunningProcesses { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Saves pending project-list changes and stops every tracked process tree
        // (pipeline runs, uv sync, helpers, the fitting worker).
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
