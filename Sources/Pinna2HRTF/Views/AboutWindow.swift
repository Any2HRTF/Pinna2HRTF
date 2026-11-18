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
        let mesh2HRTF = (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        mesh2HRTFVersion = mesh2HRTF?.isEmpty == false ? mesh2HRTF : nil
    }

    var versionLine: String { build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))" }
    var revisionLine: String { "Revision \(revision)" }
    var mesh2HRTFLine: String? { mesh2HRTFVersion.map { "Mesh2HRTF \($0)" } }

    var copyText: String {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return ([name, versionLine, revisionLine, mesh2HRTFLine, "macOS \(system)"] as [String?])
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

struct AboutView: View {
    let info: AboutInfo

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(info.name)
                .font(.title2.bold())
            VStack(spacing: 4) {
                Text(info.versionLine)
                Group {
                    Text(info.revisionLine)
                    if let line = info.mesh2HRTFLine { Text(line) }
                }
                .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Button("Copy Version Info", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.copyText, forType: .string)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(minWidth: 280)
    }
}

struct AboutScene: Scene {
    static let id = "about"
    let info: AboutInfo

    var body: some Scene {
        Window("About \(info.name)", id: Self.id) {
            AboutView(info: info)
                .modifier(AboutWindowChrome())
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct AboutWindowChrome: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(.thickMaterial, for: .window)
        } else {
            content
        }
    }
}

struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Pinna2HRTF") { openWindow(id: AboutScene.id) }
    }
}
