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
                Menu {
                    ForEach(store.artifacts.filter(\.exists)) { artifact in
                        Button {
                            store.openArtifact(artifact)
                        } label: {
                            Label(artifact.title, systemImage: artifact.url == store.selectedMesh ? "checkmark" : artifact.systemImage)
                        }
                    }
                } label: {
                    Label(store.artifacts.first(where: { $0.url == store.selectedMesh })?.title ?? "Preview", systemImage: "list.bullet.rectangle")
                }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel(store.artifacts.first(where: { $0.url == store.selectedMesh })?.title ?? "Preview")
                .help("Choose a File to Preview")
                .disabled(store.selectedProject == nil || store.isPlacingMicrophone)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                ForEach(EarSide.allCases) { side in
                    Button {
                        store.beginMicrophonePlacement(side)
                    } label: {
                        Label("Place \(side.title) Mic", systemImage: "scope")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Place \(side.title) Microphone")
                    .disabled(store.selectedProjectIsRunning || store.isPlacingMicrophone || !(store.selectedProjectStatus?.pipelineSides.contains(side) ?? false))
                }
                } label: { Label("Microphone", systemImage: "scope") }
                .accessibilityLabel("Microphone")
                .help("Place a microphone on the left or right ear")
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
        .alert("Project list recovery", isPresented: $store.registryRecoveryPresented) {
            Button("Restore displayed project list") { store.recoverProjectRegistry() }
            Button("Keep original file protected", role: .cancel) {}
        } message: {
            Text(store.registryStore.recoveryMessage ?? store.persistenceMessage ?? "The original project list will be preserved before recovery.")
        }
        .sheet(item: editorPresentation) { editor in
            switch editor {
            case .duplicate(let request):
                ProjectDuplicationView(store: store, request: request)
            case .mesh(let request):
                MeshEditorView(request: request, saved: store.finishMeshEditing)
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
        .onChange(of: store.selectedProjectID) { _ in
            store.persist()
            store.loadSelectedProjectLog()
            store.refreshArtifacts(restoringViewer: true)
        }
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
                    .frame(minWidth: 460, maxWidth: .infinity)
                    .layoutPriority(1)
                if inspectorPresented {
                    ProjectInspectorView(store: store)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 720)
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
                .frame(minWidth: 280, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
            canRunProject: store.canRunNextStage(),
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
