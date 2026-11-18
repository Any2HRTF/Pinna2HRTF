import AppKit
import SwiftUI

struct PipelineCommandContext {
    var canRemoveProject: Bool
    var canDuplicateProject: Bool
    var canShowProjectInFinder: Bool
    var folderSelected: Bool
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
    var createFolder: () -> Void
    var importProject: () -> Void
    var duplicateProject: () -> Void
    var removeProject: () -> Void
    var removeFolder: () -> Void
    var showProjectInFinder: () -> Void
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
            Button("New Folder…") {
                commands?.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(commands == nil)
            Button("Import Project…") {
                commands?.importProject()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Duplicate Project…") {
                commands?.duplicateProject()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(commands?.canDuplicateProject != true)

            Button("Show in Finder") {
                commands?.showProjectInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(commands?.canShowProjectInFinder != true)

            Divider()

            Button("Remove Project") {
                if !forwardDeleteToTextField() { commands?.removeProject() }
            }
            .keyboardShortcut(commands?.folderSelected == true ? nil : KeyboardShortcut(.delete, modifiers: [.command]))
            .disabled(commands?.folderSelected != false || commands?.canRemoveProject != true)

            Button("Remove Folder") {
                if !forwardDeleteToTextField() { commands?.removeFolder() }
            }
            .keyboardShortcut(commands?.folderSelected == true ? KeyboardShortcut(.delete, modifiers: [.command]) : nil)
            .disabled(commands?.folderSelected != true)
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

            Button(commands?.isLogExpanded == true ? "Hide Activity" : "Show Activity") {
                commands?.toggleLog()
            }
            .disabled(commands == nil)
        }
        CommandMenu("Workflow") {
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
                    Button(stage.menuTitle) {
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

            Button("Reset Outputs…") {
                commands?.resetProject()
            }
            .disabled(commands?.canResetProject != true)

            Divider()

            Button("Refresh Project Files") {
                commands?.refreshArtifacts()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(commands == nil)
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
            .disabled(commands == nil)
        }
    }
}

private extension Stage {
    var menuTitle: String {
        switch self {
        case .scanPreparation: "Ear Preparation"
        case .inference: "Mesh2PPM"
        case .preprocessing: "Simulation Setup"
        case .numcalc: "Calculation"
        case .postprocessing: "SOFA Export"
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

@MainActor
private func forwardDeleteToTextField() -> Bool {
    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable else { return false }
    editor.deleteToBeginningOfLine(nil)
    return true
}
