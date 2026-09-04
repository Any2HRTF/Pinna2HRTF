import SwiftUI
import AppKit

@main
struct Pinna2HRTFApp: App {
    @NSApplicationDelegateAdaptor(Pinna2HRTFAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        Window("Pinna2HRTF", id: "main") {
            ContentView(store: store)
                .onAppear { appDelegate.store = store }
                .frame(minWidth: 900, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        }
        .defaultSize(width: 1320, height: 900)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Pinna2HRTF") {
                    let gitHead = Bundle.main.object(forInfoDictionaryKey: "Pinna2HRTFGitHead") as? String ?? "unknown"
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [
                        .credits: NSAttributedString(string: "A desktop pipeline for ear-mesh preprocessing, Mesh2PPM inference, Mesh2HRTF simulation, and SOFA export.\n\nGit HEAD: \(gitHead)\n© 2026 Any2HRTF")
                    ]
                    if let iconURL = Bundle.main.url(forResource: "icon", withExtension: "png"), let icon = NSImage(contentsOf: iconURL) {
                        options[.applicationIcon] = icon
                    }
                    NSApp.orderFrontStandardAboutPanel(options: options)
                }
            }
            SidebarCommands()
            ProjectInspectorCommands()
            PipelineCommands()
            CommandGroup(replacing: .help) {
                Button("Pinna2HRTF Help") {
                    if let url = URL(string: "https://github.com/Any2HRTF/Pinna2HRTF#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

final class Pinna2HRTFAppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.runningProcesses.isEmpty || store.environmentProcess != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A pipeline task is still running"
        alert.informativeText = "Quitting will stop the task and may leave incomplete outputs. Do you want to quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.runningProcesses.values.forEach { $0.terminate() }
        store?.environmentProcess?.terminate()
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
