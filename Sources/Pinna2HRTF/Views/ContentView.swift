import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @SceneStorage("logExpanded.v2") private var logExpanded = false
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
        if #available(macOS 14.0, *) {
            navigationWorkspace
        } else {
            HSplitView {
                navigationWorkspace
                    .frame(minWidth: 460, maxWidth: .infinity)
                    .layoutPriority(1)
                if inspectorPresented {
                    ProjectInspectorView(store: store)
                        .frame(minWidth: 260, idealWidth: 360, maxWidth: 720)
                }
            }
        }
    }

    var navigationWorkspace: some View {
        NavigationSplitView {
            ProjectSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)
        } detail: {
            meshViewer
                .frame(minWidth: 280, maxWidth: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder var meshViewer: some View {
        if #available(macOS 14.0, *) {
            MeshViewerView(store: store, logExpanded: $logExpanded)
                .inspector(isPresented: $inspectorPresented) {
                    ProjectInspectorView(store: store)
                        .inspectorColumnWidth(min: 260, ideal: 360, max: 720)
                }
        } else {
            MeshViewerView(store: store, logExpanded: $logExpanded)
        }
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
            artifacts: store.artifacts.filter(\.exists),
            selectedArtifactURL: store.selectedMesh,
            canPreview: selectedProject != nil && !store.isPlacingMicrophone,
            canPlaceMicrophone: { side in
                !store.isPlacingMicrophone && (selectedProject.map { side == .left ? !$0.leftEar.isEmpty : !$0.rightEar.isEmpty } ?? false)
            },
            isLogExpanded: logExpanded,
            isInspectorPresented: inspectorPresented,
            createProject: { store.createProject() },
            importProject: { store.importProject() },
            duplicateProject: { store.duplicateSelectedProject() },
            removeProject: { store.forgetSelectedProject() },
            runNextStage: { store.runNextStage() },
            runStage: { store.run(stage: $0) },
            stopProject: { store.stopRunningProcess() },
            resetProject: { store.confirmResetSelectedProjectOutputs() },
            refreshArtifacts: { store.refreshArtifacts() },
            openArtifact: { store.openArtifact($0) },
            placeMicrophone: { store.beginMicrophonePlacement($0) },
            toggleLog: { withAnimation { logExpanded.toggle() } },
            toggleInspector: { withAnimation { inspectorPresented.toggle() } }
        )
    }
}
