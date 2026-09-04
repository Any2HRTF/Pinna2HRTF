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
            Button("New Project") {
                commands?.createProject()
            }
            .keyboardShortcut("n", modifiers: [.command])
            Button("Import Project…") {
                commands?.importProject()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Button("Duplicate Project") {
                commands?.duplicateProject()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(commands?.canDuplicateProject != true)

            Button("Remove Project") {
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

            Button(commands?.isLogExpanded == true ? "Hide Live Log" : "Show Live Log") {
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

            Button("Run Next Step") {
                commands?.runNextStage()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(commands?.canRunProject != true)

            Menu("Run Stage") {
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

            Button("Reset Outputs") {
                commands?.resetProject()
            }
            .disabled(commands?.canResetProject != true)

            Divider()

            Button("Refresh Project Files") {
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
