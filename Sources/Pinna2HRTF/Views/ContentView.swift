import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore()
    @SceneStorage("logExpanded") private var logExpanded = true

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } content: {
            MeshViewerView(store: store, logExpanded: $logExpanded)
                .frame(minWidth: 620)
        } detail: {
            ProjectInspectorView(store: store)
                .navigationSplitViewColumnWidth(min: 360, ideal: 420, max: 480)
        }
        .focusedSceneValue(\.pipelineCommands, commandContext)
        .onChange(of: store.selectedProjectID) { _ in
            store.persist()
            store.resetViewer()
            store.refreshArtifacts()
        }
    }

    var commandContext: PipelineCommandContext {
        let selectedProject = store.selectedProject
        let selectedProjectIsRunning = selectedProject.map { store.runningProcesses[$0.id] != nil } ?? false
        return PipelineCommandContext(
            canRemoveProject: selectedProject != nil,
            canRunProject: selectedProject != nil && !selectedProjectIsRunning,
            canStopProject: selectedProjectIsRunning,
            canResetProject: selectedProject != nil && !selectedProjectIsRunning,
            canSetupEnvironment: store.environmentProcess == nil,
            createProject: { store.createProject() },
            removeProject: { store.forgetSelectedProject() },
            runNextStage: { store.runNextStage() },
            runStage: { store.run(stage: $0) },
            stopProject: { store.stopRunningProcess() },
            resetProject: { store.resetSelectedProjectOutputs() },
            refreshArtifacts: { store.refreshArtifacts() },
            setupEnvironment: { store.setupEnvironment() }
        )
    }
}
