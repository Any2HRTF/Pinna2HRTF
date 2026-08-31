import SwiftUI

struct PipelineCommandContext {
    var canRemoveProject: Bool
    var canDuplicateProject: Bool
    var canRunProject: Bool
    var canStopProject: Bool
    var canResetProject: Bool
    var createProject: () -> Void
    var importProject: () -> Void
    var duplicateProject: () -> Void
    var removeProject: () -> Void
    var runNextStage: () -> Void
    var runStage: (Stage) -> Void
    var stopProject: () -> Void
    var resetProject: () -> Void
    var refreshArtifacts: () -> Void
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
        CommandMenu("Pipeline") {
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
                    .disabled(commands?.canRunProject != true)
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

            Button("Refresh Artifacts") {
                commands?.refreshArtifacts()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
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
