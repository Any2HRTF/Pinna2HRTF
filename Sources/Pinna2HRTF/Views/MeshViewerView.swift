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
                    HStack {
                        Button("New Project", action: store.createProject)
                        Button("Import Project…", action: store.importProject)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                viewer
                Divider()
                logPanel
            }
        }
        .onExitCommand {
            store.cancelMicrophonePlacement()
        }
        .alert("Cannot Place Microphone", isPresented: Binding(get: { store.microphonePlacementError != nil }, set: { if !$0 { store.microphonePlacementError = nil } })) {
            Button("OK") { store.microphonePlacementError = nil }
        } message: {
            Text(store.microphonePlacementError ?? "")
        }
    }

    var viewer: some View {
        ZStack {
            Rectangle()
                .fill(colorScheme == .dark ? Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)) : Color(nsColor: NSColor(calibratedWhite: 0.93, alpha: 1)))
            if let source = store.selectedPressure {
                PressureFieldView(source: source).id(source)
            } else if let image = store.selectedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
            } else if store.selectedMesh == nil {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Select a file to preview")
                        .foregroundStyle(.secondary)
                }
            } else {
                PersistentSceneView(scene: store.selectedScene, darkMode: colorScheme == .dark, placementMode: store.isPlacingMicrophone, cameraPositionChanged: { [scene = store.selectedScene] position in
                    guard store.selectedScene === scene else { return }
                    store.updateCameraPosition(position)
                }, surfaceSelected: store.previewMicrophonePosition)
                    .id(ObjectIdentifier(store.selectedScene))
                    .onAppear {
                        store.updateSceneBackground(darkMode: colorScheme == .dark)
                    }
                    .onChange(of: colorScheme) { newColorScheme in
                        store.updateSceneBackground(darkMode: newColorScheme == .dark)
                    }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if let project = store.selectedProject,
                   let mesh = store.selectedMesh,
                   let side = ArtifactScanner.preparedEarSide(for: mesh, in: project) {
                    Button("Edit \(side.title) Ear…") { store.beginEarEditing(side) }
                        .modifier(ViewerGlassButtonStyle())
                        .controlSize(.regular)
                        .help("Edit the selected prepared ear")
                        .disabled(store.selectedProjectIsRunning)
                }
                if store.selectedMesh != nil && store.selectedImage == nil && store.selectedPressure == nil {
                    Button(action: store.resetSelectedMeshView) {
                        Label("Reset view", systemImage: "arrow.counterclockwise")
                    }
                    .modifier(ViewerGlassButtonStyle())
                    .controlSize(.regular)
                    .help("Restore the default view of this mesh")
                }
            }
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if let side = store.microphonePlacementSide {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Place \(side.title) Microphone", systemImage: "scope")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("Drag to rotate · Click to place")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(microphoneCoordinates)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Use Automatic Position") {
                            store.useAutomaticMicrophonePosition(side)
                        }
                        if store.isCalculatingAutomaticMicrophone {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Searching…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Searching for automatic microphone position")
                        }
                        Spacer()
                        Button("Cancel") {
                            store.cancelMicrophonePlacement()
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Done") {
                            store.completeMicrophonePlacement()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.pendingMicrophonePosition == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding(16)
                .modifier(MicrophonePlacementSurface())
                .padding(16)
            }
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
                    Label("Activity", systemImage: logExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .font(.headline)
                Spacer()
                Text(logSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if logExpanded {
                Button {
                    store.openTechnicalLog()
                } label: {
                    Label("Technical Log", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Open the complete technical output for this project")
                .accessibilityLabel("Open Technical Log")
                .disabled(store.selectedTechnicalLogURL == nil)
                Button("Clear Activity") { store.clearSelectedProjectLog() }
                    .buttonStyle(.borderless)
                    .disabled(store.logText.isEmpty)
                    .help("Clear the activity timeline. Technical logs remain available.")
                }
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
    }

    var logSummary: String {
        if store.environmentProcess != nil { return "Setting up environment" }
        if let project = store.selectedProject, let stage = store.runningStages[project.id] { return "\(stage.title) running" }
        if store.selectedProjectIsRunning { return "Checking outputs" }
        if let project = store.selectedProject, let status = store.liveLogStatusByProject[project.id] { return status }
        if store.logText.isEmpty { return store.selectedTechnicalLogURL == nil ? "No activity yet" : "Technical log available" }
        return "Ready"
    }

    var microphoneCoordinates: String {
        guard let position = store.pendingMicrophonePosition else { return "No position selected" }
        return String(format: "X %.2f · Y %.2f · Z %.2f mm", position.x, position.y, position.z)
    }
}

struct ViewerGlassButtonStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.bordered)
        } else if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct MicrophonePlacementSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct PersistentSceneView: NSViewRepresentable {
    let scene: SCNScene
    let darkMode: Bool
    let placementMode: Bool
    let cameraPositionChanged: (SCNVector3) -> Void
    let surfaceSelected: (SCNVector3) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(placementMode: placementMode, cameraPositionChanged: cameraPositionChanged, surfaceSelected: surfaceSelected)
    }

    func makeNSView(context: Context) -> MeshSceneViewport {
        let viewport = MeshSceneViewport(frame: .zero)
        let view = viewport.sceneView
        view.scene = scene
        view.configureNavigation(camera: scene.rootNode.childNodes.first { $0.camera != nil })
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        view.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectSurface(_:))))
        context.coordinator.observeCamera(in: viewport)
        return viewport
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeshSceneViewport, context: Context) -> CGSize? {
        // Never derive minimum/ideal sizes from the last rendered frame.
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        let height = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ viewport: MeshSceneViewport, context: Context) {
        let view = viewport.sceneView
        context.coordinator.placementMode = placementMode
        context.coordinator.cameraPositionChanged = cameraPositionChanged
        context.coordinator.surfaceSelected = surfaceSelected
        if view.scene !== scene {
            view.scene = scene
            view.configureNavigation(camera: scene.rootNode.childNodes.first { $0.camera != nil })
            context.coordinator.lastPosition = nil
        }
        let background = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        if view.backgroundColor != background { view.backgroundColor = background }
    }

    static func dismantleNSView(_ viewport: MeshSceneViewport, coordinator: Coordinator) {
        coordinator.cameraTimer?.invalidate()
        coordinator.cameraTimer = nil
        viewport.finishResizing()
        viewport.sceneView.scene = nil
    }

    final class Coordinator: NSObject {
        var placementMode: Bool
        var cameraPositionChanged: (SCNVector3) -> Void
        var surfaceSelected: (SCNVector3) -> Void
        var lastPosition: SCNVector3?
        var cameraTimer: Timer?

        init(placementMode: Bool, cameraPositionChanged: @escaping (SCNVector3) -> Void, surfaceSelected: @escaping (SCNVector3) -> Void) {
            self.placementMode = placementMode
            self.cameraPositionChanged = cameraPositionChanged
            self.surfaceSelected = surfaceSelected
        }

        @objc func selectSurface(_ recognizer: NSClickGestureRecognizer) {
            guard placementMode, let view = recognizer.view as? SCNView else { return }
            let hits = view.hitTest(recognizer.location(in: view), options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
            guard let hit = hits.first else { return }
            surfaceSelected(hit.worldCoordinates)
        }

        func observeCamera(in viewport: MeshSceneViewport) {
            cameraTimer?.invalidate()
            // Read and persist camera state on the main thread, outside renderer/layout callbacks.
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self, weak viewport] _ in
                guard let self, let viewport, viewport.window != nil, !viewport.inLiveResize,
                      let position = viewport.sceneView.pointOfView?.presentation.position,
                      position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
                if let last = self.lastPosition, abs(last.x - position.x) < 0.001, abs(last.y - position.y) < 0.001, abs(last.z - position.z) < 0.001 { return }
                self.lastPosition = position
                self.cameraPositionChanged(position)
            }
            cameraTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
