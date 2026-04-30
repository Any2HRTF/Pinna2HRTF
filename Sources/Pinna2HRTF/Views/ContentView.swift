import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var logExpanded = true

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
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
            store.createProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .removeProject)) { _ in
            store.forgetSelectedProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .runSelectedProject)) { _ in
            store.runNextStage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .runStage)) { notification in
            guard let rawValue = notification.object as? String, let stage = Stage(rawValue: rawValue) else { return }
            store.run(stage: stage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopSelectedProject)) { _ in
            store.stopRunningProcess()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSelectedProject)) { _ in
            store.resetSelectedProjectOutputs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshArtifacts)) { _ in
            store.refreshArtifacts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .setupEnvironment)) { _ in
            store.setupEnvironment()
        }
        .onChange(of: store.selectedProjectID) { _ in
            store.persist()
            store.resetViewer()
            store.refreshArtifacts()
        }
    }
}
