import SwiftUI

struct PipelineCommandContext {
    var canRemoveProject: Bool
    var canDuplicateProject: Bool
    var canRunProject: Bool
    var canRunStage: (Stage) -> Bool
    var canStopProject: Bool
    var canResetProject: Bool
    var artifacts: [Artifact]
    var selectedArtifactURL: URL?
    var canPreview: Bool
    var canPlaceMicrophone: (EarSide) -> Bool
    var isLogExpanded: Bool
    var isInspectorPresented: Bool
    var createProject: () -> Void
    var importProject: () -> Void
    var duplicateProject: () -> Void
    var removeProject: () -> Void
    var runNextStage: () -> Void
    var runStage: (Stage) -> Void
    var stopProject: () -> Void
    var resetProject: () -> Void
    var refreshArtifacts: () -> Void
    var openArtifact: (Artifact) -> Void
    var placeMicrophone: (EarSide) -> Void
    var toggleLog: () -> Void
    var toggleInspector: () -> Void
}

struct PipelineCommands: Commands {
    @FocusedValue(\.pipelineCommands) private var commands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New project") {
                commands?.createProject()
            }
            .keyboardShortcut("n", modifiers: [.command])
            Button("Import project…") {
                commands?.importProject()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Button("Duplicate project") {
                commands?.duplicateProject()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(commands?.canDuplicateProject != true)

            Button("Remove project") {
                commands?.removeProject()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(commands?.canRemoveProject != true)
        }
        CommandGroup(after: .toolbar) {
            Menu("Preview") {
                ForEach(commands?.artifacts ?? []) { artifact in
                    Button {
                        commands?.openArtifact(artifact)
                    } label: {
                        Label(artifact.title, systemImage: artifact.url == commands?.selectedArtifactURL ? "checkmark" : artifact.systemImage)
                    }
                }
            }
            .disabled(commands?.canPreview != true || commands?.artifacts.isEmpty != false)

            Button(commands?.isLogExpanded == true ? "Hide activity" : "Show activity") {
                commands?.toggleLog()
            }
        }
        CommandMenu("Pipeline") {
            ForEach(EarSide.allCases) { side in
                Button("Place \(side.title) Microphone") {
                    commands?.placeMicrophone(side)
                }
                .disabled(commands?.canPlaceMicrophone(side) != true)
            }

            Divider()

            Button("Run next step") {
                commands?.runNextStage()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(commands?.canRunProject != true)

            Menu("Run stage") {
                ForEach(Stage.allCases) { stage in
                    Button(stage.title) {
                    commands?.runStage(stage)
                }
                    .disabled(commands?.canRunStage(stage) != true)
                }
            }

            Divider()

            Button("Stop") {
                commands?.stopProject()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(commands?.canStopProject != true)

            Button("Reset outputs") {
                commands?.resetProject()
            }
            .disabled(commands?.canResetProject != true)

            Divider()

            Button("Refresh project files") {
                commands?.refreshArtifacts()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

struct ProjectInspectorCommands: Commands {
    @FocusedValue(\.pipelineCommands) private var commands

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(commands?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                commands?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

extension FocusedValues {
    var pipelineCommands: PipelineCommandContext? {
        get { self[PipelineCommandContextKey.self] }
        set { self[PipelineCommandContextKey.self] = newValue }
    }
}

private struct PipelineCommandContextKey: FocusedValueKey {
    typealias Value = PipelineCommandContext
}
