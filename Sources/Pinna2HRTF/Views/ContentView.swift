import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @SceneStorage("logExpanded.v2") private var logExpanded = false
    @SceneStorage("inspectorPresented") private var inspectorPresented = true

    var body: some View {
        workspace
        .disabled(store.meshEditorRequest != nil || store.ppmFittingRequest != nil || store.projectDuplicationRequest != nil)
        .navigationTitle(store.selectedProject?.name ?? "Pinna2HRTF")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !inspectorPresented && store.selectedProjectIsRunning { Button("Show progress") { inspectorPresented = true } }
                Button {
                    withAnimation { logExpanded.toggle() }
                } label: {
                    Label(logExpanded ? "Hide activity" : "Show activity", systemImage: "terminal")
                }
                .help(logExpanded ? "Hide activity" : "Show activity")
                Button {
                    withAnimation { inspectorPresented.toggle() }
                } label: {
                    Label(inspectorPresented ? "Hide workflow" : "Show workflow", systemImage: "sidebar.right")
                }
                .help(inspectorPresented ? "Hide workflow" : "Show workflow")
            }
        }
        .alert("Project list recovery", isPresented: $store.registryRecoveryPresented) {
            Button("Restore displayed project list") { store.recoverProjectRegistry() }
            Button("Keep original file protected", role: .cancel) {}
        } message: {
            Text(store.registryStore.recoveryMessage ?? store.persistenceMessage ?? "The original project list will be preserved before recovery.")
        }
        .onChange(of: store.workflowRevealRequest) { _ in inspectorPresented = true }
        .sheet(item: editorPresentation) { editor in
            switch editor {
            case .duplicate(let request):
                ProjectDuplicationView(store: store, request: request)
            case .mesh(let request):
                MeshEditorView(request: request, saved: store.finishMeshEditing, savedSelection: store.finishEarSelection)
            case .ppm(let request):
                PPMFittingView(request: request) { request, templateBlendPath in
                    store.finishManualPPMFitting(request, templateBlendPath: templateBlendPath)
                }
            }
        }
        .alert("Cannot Edit Mesh", isPresented: Binding(get: { store.meshEditorError != nil }, set: { if !$0 { store.meshEditorError = nil } })) {
            Button("OK") { store.meshEditorError = nil }
        } message: { Text(store.meshEditorError ?? "") }
        .alert("Cannot Open Manual PPM Fitting", isPresented: Binding(get: { store.ppmFittingError != nil }, set: { if !$0 { store.ppmFittingError = nil } })) {
            Button("OK") { store.ppmFittingError = nil }
        } message: { Text(store.ppmFittingError ?? "") }
        .focusedSceneValue(\.pipelineCommands, commandContext)
    }

    private var editorPresentation: Binding<ProjectEditorPresentation?> {
        Binding(get: {
            if let request = store.projectDuplicationRequest { return .duplicate(request) }
            if let request = store.meshEditorRequest { return .mesh(request) }
            if let request = store.ppmFittingRequest { return .ppm(request) }
            return nil
        }, set: { value in
            if value == nil {
                store.projectDuplicationRequest = nil
                store.meshEditorRequest = nil
                store.ppmFittingRequest = nil
            }
        })
    }

    @ViewBuilder var workspace: some View {
        if #available(macOS 14.0, *) {
            navigationWorkspace
        } else {
            HSplitView {
                navigationWorkspace
                    .frame(minWidth: PressureFieldView.minimumViewerWidth + 180, maxWidth: .infinity)
                    .layoutPriority(1)
                if inspectorPresented {
                    ProjectInspectorView(store: store)
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 720)
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
                .frame(minWidth: PressureFieldView.minimumViewerWidth, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder var meshViewer: some View {
        if #available(macOS 14.0, *) {
            NativeMeshWorkspace(store: store, logExpanded: $logExpanded, inspectorPresented: inspectorPresented)
        } else {
            MeshViewerView(store: store, logExpanded: $logExpanded)
        }
    }

    var commandContext: PipelineCommandContext {
        let selectedProject = store.selectedProject
        let selectedProjectIsRunning = selectedProject.map { store.runningProcesses[$0.id] != nil } ?? false
        return PipelineCommandContext(
            canRemoveProject: store.canRemoveSelectedProject,
            canDuplicateProject: selectedProject != nil && !store.selectedProjectIsRunning,
            canRunProject: selectedProject != nil && !store.selectedProjectIsRunning && store.workflowNextAction.enabled,
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
            importProject: { store.importProject() },
            duplicateProject: { store.duplicateSelectedProject() },
            removeProject: { store.removeSelectedProject() },
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

private enum ProjectEditorPresentation: Identifiable {
    case duplicate(ProjectDuplicationRequest)
    case mesh(MeshEditorRequest)
    case ppm(PPMFittingRequest)

    var id: String {
        switch self {
        case .duplicate(let request): return "duplicate-\(request.id)"
        case .mesh(let request): return "mesh-\(request.id)"
        case .ppm(let request): return "ppm-\(request.id)"
        }
    }
}
