import SwiftUI
import AppKit

@main
struct Pinna2HRTFApp: App {
    @NSApplicationDelegateAdaptor(Pinna2HRTFAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1320, minHeight: 840)
        }
        .windowStyle(.titleBar)
        .commands {
            PipelineCommands()
        }
    }
}

final class Pinna2HRTFAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        disableShowAllTabs()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        disableShowAllTabs()
    }

    private func disableShowAllTabs() {
        DispatchQueue.main.async {
            guard let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return }
            viewMenu.items.first(where: { $0.title == "Show All Tabs" })?.isEnabled = false
        }
    }
}
