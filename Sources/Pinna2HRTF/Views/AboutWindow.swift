import AppKit
import SwiftUI

struct AboutInfo {
    let name: String
    let version: String
    let build: String
    let revision: String
    let mesh2HRTFVersion: String?

    init(bundle: Bundle = .main, externalDirectory: String) {
        name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pinna2HRTF"
        version = bundle.object(forInfoDictionaryKey: "Pinna2HRTFDisplayVersion") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0 beta"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        revision = bundle.object(forInfoDictionaryKey: "Pinna2HRTFGitHead") as? String ?? "unknown"
        let versionFile = URL(fileURLWithPath: externalDirectory).appendingPathComponent("src/Mesh2HRTF/VERSION")
        mesh2HRTFVersion = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var versionLine: String { build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))" }
    var revisionLine: String { "Revision \(revision)" }
    var mesh2HRTFLine: String? { mesh2HRTFVersion.map { "Mesh2HRTF \($0)" } }

    var copyText: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return ([name, versionLine, revisionLine, mesh2HRTFLine,
                 "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"] as [String?])
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct AboutView: View {
    let info: AboutInfo
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .padding(.bottom, 12)
            Text(info.name)
                .font(.title2.weight(.bold))
                .padding(.bottom, 6)
            Text(info.versionLine)
                .padding(.bottom, 4)
            Group {
                Text(info.revisionLine)
                if let line = info.mesh2HRTFLine { Text(line) }
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.copyText, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Version Info", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.large)
            .padding(.top, 14)
        }
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(minWidth: 280)
        .fixedSize()
        .ignoresSafeArea()
    }
}

@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show(externalDirectory: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let info = AboutInfo(externalDirectory: externalDirectory)
        let hosting = NSHostingController(rootView: AboutView(info: info))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.title = "About \(info.name)"
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
