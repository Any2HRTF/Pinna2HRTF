import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @SceneStorage("logExpanded") private var logExpanded = true
    @SceneStorage("inspectorPresented") private var inspectorPresented = true

    var body: some View {
        workspace
        .navigationTitle(store.selectedProject?.name ?? "Pinna2HRTF")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(store.artifacts.filter(\.exists)) { artifact in
                        Button {
                            store.openArtifact(artifact)
                        } label: {
                            Label(artifact.title, systemImage: artifact.url == store.selectedMesh ? "checkmark" : artifact.systemImage)
                        }
                    }
                } label: {
                    Label("Preview", systemImage: "list.bullet.rectangle")
                }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Preview")
                .help("Choose a File to Preview")
                .disabled(store.selectedProject == nil || store.isPlacingMicrophone)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(EarSide.allCases) { side in
                    Button {
                        store.beginMicrophonePlacement(side)
                    } label: {
                        Label("Place \(side.title) Mic", systemImage: "scope")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Place \(side.title) Microphone")
                    .disabled(store.isPlacingMicrophone || store.selectedProject.map { side == .left ? $0.leftEar.isEmpty : $0.rightEar.isEmpty } ?? true)
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation { logExpanded.toggle() }
                } label: {
                    Label(logExpanded ? "Hide Live Log" : "Show Live Log", systemImage: "terminal")
                }
                .help(logExpanded ? "Hide Live Log" : "Show Live Log")
                Button {
                    withAnimation { inspectorPresented.toggle() }
                } label: {
                    Label(inspectorPresented ? "Hide Project Settings" : "Show Project Settings", systemImage: "sidebar.right")
                }
                .help(inspectorPresented ? "Hide Project Settings" : "Show Project Settings")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .focusedSceneValue(\.pipelineCommands, commandContext)
        .onChange(of: store.selectedProjectID) { _ in
            store.persist()
            store.loadSelectedProjectLog()
            store.refreshArtifacts()
            store.restoreViewer()
        }
    }

    @ViewBuilder var workspace: some View {
        HSplitView {
            navigationWorkspace
                .frame(minWidth: 640, maxWidth: .infinity)
                .layoutPriority(1)
            if inspectorPresented {
                ProjectInspectorView(store: store)
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 720)
            }
        }
    }

    var navigationWorkspace: some View {
        NavigationSplitView {
            ProjectSidebarView(store: store)
                .navigationSplitViewColumnWidth(240)
        } detail: {
            MeshViewerView(store: store, logExpanded: $logExpanded)
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    var commandContext: PipelineCommandContext {
        let selectedProject = store.selectedProject
        let selectedProjectIsRunning = selectedProject.map { store.runningProcesses[$0.id] != nil } ?? false
        return PipelineCommandContext(
            canRemoveProject: selectedProject != nil,
            canDuplicateProject: selectedProject != nil,
            canRunProject: store.canRunNextStage(),
            canRunStage: { stage in store.canRun(stage: stage) },
            canStopProject: selectedProjectIsRunning,
            canResetProject: selectedProject != nil && !selectedProjectIsRunning,
            createProject: { store.createProject() },
            importProject: { store.importProject() },
            duplicateProject: { store.duplicateSelectedProject() },
            removeProject: { store.forgetSelectedProject() },
            runNextStage: { store.runNextStage() },
            runStage: { store.run(stage: $0) },
            stopProject: { store.stopRunningProcess() },
            resetProject: { store.confirmResetSelectedProjectOutputs() },
            refreshArtifacts: { store.refreshArtifacts() }
        )
    }
}
