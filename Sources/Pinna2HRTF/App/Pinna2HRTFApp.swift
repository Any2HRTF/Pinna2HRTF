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
            CommandGroup(replacing: .appInfo) {
                Button("About Pinna2HRTF") {
                    let alert = NSAlert()
                    alert.icon = NSApp.applicationIconImage
                    alert.messageText = "Pinna2HRTF"
                    alert.informativeText = "Version 0.1.0\n© 2026 Any2HRTF\n\nA desktop pipeline for ear-mesh preprocessing, Pinna2HRTF inference, Mesh2HRTF simulation, and SOFA export.\n\nProject: Any2HRTF / Pinna2HRTF\nhttps://github.com/Any2HRTF/Pinna2HRTF"
                    alert.addButton(withTitle: "OK")
                    alert.addButton(withTitle: "Open Project Website")
                    if alert.runModal() == .alertSecondButtonReturn, let url = URL(string: "https://github.com/Any2HRTF/Pinna2HRTF") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            PipelineCommands()
        }
    }
}

final class Pinna2HRTFAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuItems()
        disableShowAllTabs()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installMenuItems()
        disableShowAllTabs()
    }

    private func installMenuItems() {
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu else { return }
            let helpMenuItem = mainMenu.items.first(where: { $0.title == "Help" }) ?? NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
            if helpMenuItem.submenu == nil {
                helpMenuItem.submenu = NSMenu(title: "Help")
                mainMenu.addItem(helpMenuItem)
            }
            guard let helpMenu = helpMenuItem.submenu else { return }
            if let helpItem = helpMenu.items.first(where: { $0.title == "Pinna2HRTF Help" }) {
                helpItem.target = self
                helpItem.action = #selector(Self.showHelp(_:))
            } else {
                let helpItem = NSMenuItem(title: "Pinna2HRTF Help", action: #selector(Self.showHelp(_:)), keyEquivalent: "")
                helpItem.target = self
                helpMenu.addItem(helpItem)
            }
        }
    }

    @objc private func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/Any2HRTF/Pinna2HRTF#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    private func disableShowAllTabs() {
        DispatchQueue.main.async {
            guard let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return }
            viewMenu.items.first(where: { $0.title == "Show All Tabs" })?.isEnabled = false
        }
    }
}
