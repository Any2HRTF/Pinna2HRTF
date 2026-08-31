import SwiftUI
import SceneKit
import AppKit

struct MeshViewerView: View {
    @ObservedObject var store: AppStore
    @Binding var logExpanded: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if store.selectedProject == nil {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No Project Selected")
                        .font(.title2.weight(.semibold))
                    Text("Create or select a project to inspect meshes and logs.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                viewer
                Divider()
                logPanel
            }
        }
    }

    var viewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Artifact Viewer")
                        .font(.title2.weight(.semibold))
                    Text(store.selectedMesh?.path ?? "Select an artifact")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if store.selectedMesh?.lastPathComponent.caseInsensitiveCompare("graded_head.ply") == .orderedSame {
                        Text("Orange marker: microphone position")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Menu {
                    ForEach(store.artifacts.filter(\.exists)) { artifact in
                        Button {
                            store.openArtifact(artifact)
                        } label: {
                            Label(artifact.title, systemImage: artifact.url == store.selectedMesh ? "checkmark" : artifact.systemImage)
                        }
                    }
                } label: {
                    Label("Artifact", systemImage: "list.bullet.rectangle")
                }
                .controlSize(.small)
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 12)
            Divider()
            ZStack {
                Rectangle()
                    .fill(colorScheme == .dark ? Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)) : Color(nsColor: NSColor(calibratedWhite: 0.93, alpha: 1)))
                if let image = store.selectedImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                } else if store.selectedMesh == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Select an artifact")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    PersistentSceneView(scene: store.selectedScene, cameraState: $store.selectedCameraState, darkMode: colorScheme == .dark) { position in
                        store.updateCameraPosition(position)
                    }
                        .onAppear {
                            store.updateSceneBackground(darkMode: colorScheme == .dark)
                        }
                        .onChange(of: colorScheme) { newColorScheme in
                            store.updateSceneBackground(darkMode: newColorScheme == .dark)
                        }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    var logPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.snappy) {
                        logExpanded.toggle()
                    }
                } label: {
                    Label("Live Log", systemImage: logExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .font(.headline)
                Spacer()
                Text(logSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Clear") { store.clearSelectedProjectLog() }
                    .buttonStyle(.borderless)
                    .disabled(store.logText.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if logExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(store.logText.isEmpty ? "Waiting for output..." : store.logText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                            .id("log-bottom")
                    }
                    .onChange(of: store.logText) { _ in
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
                .frame(height: 170)
            }
        }
        .background(.bar)
    }

    var logSummary: String {
        if !store.runningProcesses.isEmpty || store.environmentProcess != nil { return "Running" }
        if store.logText.isEmpty { return "No output yet" }
        return store.logText.split(separator: "\n").last.map(String.init) ?? "Ready"
    }
}

struct PersistentSceneView: NSViewRepresentable {
    let scene: SCNScene
    @Binding var cameraState: ViewerCameraState?
    let darkMode: Bool
    let cameraPositionChanged: (SCNVector3) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState, cameraPositionChanged: cameraPositionChanged)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.scene = scene
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.cameraState = $cameraState
        context.coordinator.cameraPositionChanged = cameraPositionChanged
        if view.scene !== scene {
            view.scene = scene
            context.coordinator.scene = scene
            context.coordinator.lastPosition = nil
        }
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var cameraState: Binding<ViewerCameraState?>
        var cameraPositionChanged: (SCNVector3) -> Void
        weak var scene: SCNScene?
        var lastPosition: SCNVector3?

        init(cameraState: Binding<ViewerCameraState?>, cameraPositionChanged: @escaping (SCNVector3) -> Void) {
            self.cameraState = cameraState
            self.cameraPositionChanged = cameraPositionChanged
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard let position = renderer.pointOfView?.presentation.position else { return }
            if let lastPosition, abs(lastPosition.x - position.x) < 0.001, abs(lastPosition.y - position.y) < 0.001, abs(lastPosition.z - position.z) < 0.001 { return }
            lastPosition = position
            DispatchQueue.main.async { [weak self] in
                self?.cameraPositionChanged(position)
            }
        }
    }
}
