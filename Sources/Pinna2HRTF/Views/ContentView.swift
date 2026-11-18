import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @SceneStorage("logExpanded.v2") private var logExpanded = false
    @SceneStorage("inspectorPresented") private var inspectorPresented = true
    @State private var selectedFolderID: UUID?
    @State private var folderEditor: FolderEditorRequest?

    var body: some View {
        workspace
        .disabled(store.projectDuplicationRequest != nil)
        .navigationTitle(store.selectedProject?.name ?? "Pinna2HRTF")
        .toolbar(id: "main") {
            ToolbarItem(id: "activity", placement: .primaryAction) {
                Button {
                    withAnimation { logExpanded.toggle() }
                } label: {
                    Label(logExpanded ? "Hide Activity" : "Show Activity", systemImage: "terminal")
                }
                .help(logExpanded ? "Hide Activity" : "Show Activity")
            }
            ToolbarItem(id: "run", placement: .primaryAction) {
                RunToolbarButton(store: store, canRun: commandContext.canRunProject)
            }
            ToolbarItem(id: "inspector", placement: .primaryAction) {
                Button {
                    withAnimation { inspectorPresented.toggle() }
                } label: {
                    Label(inspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .alert("Restore the project list?", isPresented: $store.registryRecoveryPresented) {
            Button("Restore") { store.recoverProjectRegistry() }
            Button("Keep Original", role: .cancel) {}
        } message: {
            Text(store.registryStore.recoveryMessage ?? store.persistenceMessage ?? "The original file is kept.")
        }
        .onChange(of: store.workflowRevealRequest) { _ in inspectorPresented = true }
        .sheet(item: $store.projectDuplicationRequest) { request in
            ProjectDuplicationView(store: store, request: request)
        }
        .onChange(of: store.meshEditorRequest?.id) { _ in
            if let request = store.meshEditorRequest { MeshEditorView.present(request, store: store) }
        }
        .onChange(of: store.ppmFittingRequest?.id) { _ in
            if let request = store.ppmFittingRequest { PPMFittingView.present(request, store: store) }
        }
        .onChange(of: store.editorRevealRequest) { _ in EditorWindowController.revealOpenEditors() }
        .alert("Original Scan Not Found", isPresented: Binding(get: { store.missingOriginalScan != nil }, set: { if !$0 { store.missingOriginalScan = nil } })) {
            Button("Choose Scan…") { store.missingOriginalScan = nil; store.chooseHeadScanAndAlign() }
            Button("Cancel", role: .cancel) { store.missingOriginalScan = nil }
        } message: {
            Text("“\(store.missingOriginalScan ?? "")” was moved or deleted. Choose the full-head scan to align it again.")
        }
        .alert("Cannot Edit Mesh", isPresented: Binding(get: { store.meshEditorError != nil }, set: { if !$0 { store.meshEditorError = nil } })) {
            Button("OK") { store.meshEditorError = nil }
        } message: { Text(store.meshEditorError ?? "") }
        .alert("Cannot Open Manual PPM Fitting", isPresented: Binding(get: { store.ppmFittingError != nil }, set: { if !$0 { store.ppmFittingError = nil } })) {
            Button("OK") { store.ppmFittingError = nil }
        } message: { Text(store.ppmFittingError ?? "") }
        .focusedSceneValue(\.pipelineCommands, commandContext)
    }

    @ViewBuilder var workspace: some View {
        if #available(macOS 14.0, *) {
            navigationWorkspace {
                meshViewer
                    .inspector(isPresented: $inspectorPresented) {
                        ProjectInspectorView(store: store)
                            .inspectorColumnWidth(min: 320, ideal: 340, max: 560)
                    }
            }
        } else {
            HSplitView {
                navigationWorkspace { meshViewer }
                    .frame(minWidth: PressureFieldView.minimumViewerWidth + 180, maxWidth: .infinity)
                    .layoutPriority(1)
                if inspectorPresented {
                    ProjectInspectorView(store: store)
                        .frame(minWidth: 320, idealWidth: 340, maxWidth: 560)
                }
            }
        }
    }

    private func navigationWorkspace<Detail: View>(@ViewBuilder detail: () -> Detail) -> some View {
        NavigationSplitView {
            ProjectSidebarView(store: store, selectedFolderID: $selectedFolderID, folderEditor: $folderEditor)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)
        } detail: {
            detail()
        }
    }

    private var meshViewer: some View {
        MeshViewerView(store: store, logExpanded: $logExpanded)
            .frame(minWidth: PressureFieldView.minimumViewerWidth, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    var commandContext: PipelineCommandContext {
        let selectedProject = store.selectedProject
        let selectedProjectIsRunning = selectedProject.map { store.runningProcesses[$0.id] != nil } ?? false
        return PipelineCommandContext(
            canRemoveProject: store.canRemoveSelectedProject,
            canDuplicateProject: selectedProject != nil && !store.selectedProjectIsRunning,
            canShowProjectInFinder: !(selectedProject?.saveLocation.isEmpty ?? true),
            folderSelected: selectedFolderID != nil,
            canRunProject: selectedProject != nil && !store.selectedProjectIsRunning && store.workflowNextAction.enabled,
            nextActionTitle: store.workflowNextAction.title,
            canRunStage: { stage in store.canRun(stage: stage) },
            canStopProject: selectedProjectIsRunning,
            canResetProject: selectedProject != nil && !store.selectedProjectIsRunning,
            artifacts: store.artifacts.filter(\.exists),
            selectedArtifactURL: store.selectedMesh,
            canPreview: selectedProject != nil && !store.isPlacingMicrophone,
            canPlaceMicrophone: { side in
                !store.selectedProjectIsRunning && !store.isPlacingMicrophone && (store.selectedProjectStatus?.pipelineSides.contains(side) ?? false)
            },
            isLogExpanded: logExpanded,
            isInspectorPresented: inspectorPresented,
            createProject: { store.createProject() },
            createFolder: { folderEditor = FolderEditorRequest() },
            importProject: { store.importProject() },
            duplicateProject: { store.duplicateSelectedProject() },
            removeProject: { store.removeSelectedProject() },
            removeFolder: {
                guard let id = selectedFolderID else { return }
                selectedFolderID = nil
                store.removeFolder(id)
            },
            showProjectInFinder: { store.showSelectedProjectInFinder() },
            runNextStage: { store.performWorkflowAction() },
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

private struct RunToolbarButton: View {
    @ObservedObject var store: AppStore
    let canRun: Bool

    private var running: Bool { store.selectedProjectID.flatMap { store.runningProcesses[$0] } != nil }

    var body: some View {
        Button {
            store.performWorkflowAction()
        } label: {
            let aligning = store.activeWorkflowAlignment != nil
            Label(running ? "Stop" : (aligning ? "Save Alignment" : store.workflowNextAction.title),
                  systemImage: running ? "stop.fill" : (aligning ? "checkmark" : "play.fill"))
        }
        .help(running ? "Stop" : store.workflowNextAction.title)
        .disabled(!running && !canRun)
        .modifier(ProminentToolbarButtonStyle())
    }
}

private struct ProminentToolbarButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
