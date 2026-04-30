import SwiftUI

@main
struct Pinna2HRTFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1320, minHeight: 840)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Project") {
                    NotificationCenter.default.post(name: .newProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("Remove Project") {
                    NotificationCenter.default.post(name: .removeProject, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }
            CommandMenu("Project") {
                Button("Run Next Step") {
                    NotificationCenter.default.post(name: .runSelectedProject, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                ForEach(Stage.allCases) { stage in
                    Button("Run \(stage.title)") {
                        NotificationCenter.default.post(name: .runStage, object: stage.rawValue)
                    }
                }
                Divider()
                Button("Stop Selected Project") {
                    NotificationCenter.default.post(name: .stopSelectedProject, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command])
                Button("Reset Generated Outputs") {
                    NotificationCenter.default.post(name: .resetSelectedProject, object: nil)
                }
                Divider()
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshArtifacts, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Set Up Environment") {
                    NotificationCenter.default.post(name: .setupEnvironment, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let newProject = Notification.Name("newProject")
    static let removeProject = Notification.Name("removeProject")
    static let runSelectedProject = Notification.Name("runSelectedProject")
    static let runStage = Notification.Name("runStage")
    static let stopSelectedProject = Notification.Name("stopSelectedProject")
    static let resetSelectedProject = Notification.Name("resetSelectedProject")
    static let refreshArtifacts = Notification.Name("refreshArtifacts")
    static let setupEnvironment = Notification.Name("setupEnvironment")
}
