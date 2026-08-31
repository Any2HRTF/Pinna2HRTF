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
                    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    panel.title = "About Pinna2HRTF"
                    panel.isReleasedWhenClosed = false
                    let aboutImage = NSImage(contentsOfFile: Defaults.pipelineRoot.appendingPathComponent("icon.png").path) ?? NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 1, height: 1))
                    panel.contentView = NSHostingView(rootView: VStack(spacing: 8) {
                        Image(nsImage: aboutImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 220, height: 130)
                        Text("Pinna2HRTF")
                            .font(.title.bold())
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                        Text("© 2026 Any2HRTF")
                            .foregroundStyle(.secondary)
                        Text("A desktop pipeline for ear-mesh preprocessing, Pinna2HRTF inference, Mesh2HRTF simulation, and SOFA export.")
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    .padding(20)
                    .frame(width: 460, height: 330))
                    appDelegate.aboutPanel = panel
                    panel.center()
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            PipelineCommands()
        }
    }
}

final class Pinna2HRTFAppDelegate: NSObject, NSApplicationDelegate {
    var aboutPanel: NSPanel?

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
