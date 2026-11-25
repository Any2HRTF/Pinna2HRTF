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
                noProject
            } else {
                HStack {
                    let previews = store.artifacts.filter(\.exists)
                    let previewTitle = previews.first(where: { $0.url == store.selectedMesh })?.title
                        ?? store.selectedMesh?.lastPathComponent
                        ?? (previews.isEmpty ? "No Files" : "Choose File")
                    Menu {
                        ForEach(previews) { artifact in
                            Button {
                                store.openArtifact(artifact)
                            } label: {
                                if artifact.url == store.selectedMesh {
                                    Label(artifact.title, systemImage: "checkmark")
                                } else {
                                    Text(artifact.title)
                                }
                            }
                        }
                    } label: {
                        Text(previewTitle)
                    }
                    .accessibilityLabel("Preview")
                    .accessibilityValue(Text(previewTitle))
                    .disabled(store.isPlacingMicrophone || previews.isEmpty)
                    Spacer()
                }.padding(10)
                Divider()
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
                .fill(Color(nsColor: .viewportBackground(darkMode: colorScheme == .dark)))
            if let source = store.selectedPressure {
                PressureFieldView(source: source).id(source)
            } else if let image = store.selectedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
            } else if store.selectedMesh == nil {
                noPreview
            } else {
                PersistentSceneView(scene: store.selectedScene, darkMode: colorScheme == .dark, tintMesh: true, placementMode: store.isPlacingMicrophone, resetView: store.resetSelectedMeshView, cameraPositionChanged: { [scene = store.selectedScene] position, target, orientation in
                    guard store.selectedScene === scene else { return }
                    store.updateCameraPosition(position, target: target, orientation: orientation)
                }, surfaceSelected: store.previewMicrophonePosition)
                    .id(ObjectIdentifier(store.selectedScene))
                    .opacity(store.viewer.headPreviewMessage == "Updating head preview…" ? 0.3 : 1)
            }
        }
        .overlay {
            if let message = store.viewer.headPreviewMessage {
                Group {
                    if message == "Updating head preview…" { ProgressView(message).controlSize(.small) }
                    else { Text(message).textSelection(.enabled) }
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: 0) {
                if store.selectedMesh != nil && store.selectedImage == nil && store.selectedPressure == nil {
                    ViewerOverlayControls(resetView: store.resetSelectedMeshView)
                }
                microphonePlacementPanel
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private var microphonePlacementPanel: some View {
        if let side = store.microphonePlacementSide {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Place \(side.title) Microphone", systemImage: "scope")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("Click the mesh")
                        .foregroundStyle(.secondary)
                }
                Text(microphoneCoordinates)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Use Automatic Position") {
                        store.useAutomaticMicrophonePosition(side)
                    }.disabled(store.isCalculatingAutomaticMicrophone)
                    if store.isCalculatingAutomaticMicrophone {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding position…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
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

    var logPanel: some View {
        DisclosureGroup(isExpanded: $logExpanded.animation(.snappy)) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(store.logText.isEmpty ? "No activity yet" : store.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                        .id("log-bottom")
                }
                .onChange(of: store.logText) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .frame(height: 170)
        } label: {
            HStack {
                Text("Activity")
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
                    .help("Open Technical Log")
                    .disabled(store.selectedTechnicalLogURL == nil)
                    Button("Clear") { store.clearSelectedProjectLog() }
                        .buttonStyle(.borderless)
                        .disabled(store.logText.isEmpty)
                        .help("Clear Activity")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var noProject: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView {
                Label("No Project Selected", systemImage: "folder")
            } actions: {
                HStack {
                    Button("New Project", action: store.createProject)
                    Button("Import Project…", action: store.importProject)
                }
            }
        } else {
            VStack(spacing: 12) {
                Text("No Project Selected")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("New Project", action: store.createProject)
                    Button("Import Project…", action: store.importProject)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var noPreview: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView("No Preview", systemImage: "cube.transparent")
        } else {
            Text("No Preview")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    var logSummary: String {
        if let project = store.selectedProject, let stage = store.runningStages[project.id] { return "\(stage.title) running" }
        if store.selectedProjectIsRunning { return "Checking outputs" }
        if let project = store.selectedProject, let status = store.liveLogStatusByProject[project.id] { return status }
        if store.logText.isEmpty { return store.selectedTechnicalLogURL == nil ? "No activity yet" : "Technical log available" }
        return "Ready"
    }

    var microphoneCoordinates: String {
        guard let position = store.pendingMicrophonePosition else { return "No position" }
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

struct ViewerOverlayControls: View {
    let resetView: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: resetView) {
                Label("Reset View", systemImage: "arrow.counterclockwise")
            }
            .help("Reset View")
            NavigationHelpButton()
                .help("Navigation")
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
        .modifier(ViewerGlassButtonStyle())
        .modifier(ViewerGlassContainer())
        .padding(16)
    }
}

private struct ViewerGlassContainer: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

struct MicrophonePlacementSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct PersistentSceneView: NSViewRepresentable {
    let scene: SCNScene
    let darkMode: Bool
    var tintMesh = false
    let placementMode: Bool
    let resetView: () -> Void
    let cameraPositionChanged: (SCNVector3, SCNVector3, SCNQuaternion) -> Void
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
        view.resetView = resetView
        view.autoenablesDefaultLighting = false
        applyAppearance(to: view)
        view.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectSurface(_:))))
        context.coordinator.observeCamera(in: viewport)
        return viewport
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeshSceneViewport, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        let height = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ viewport: MeshSceneViewport, context: Context) {
        let view = viewport.sceneView
        context.coordinator.placementMode = placementMode
        context.coordinator.cameraPositionChanged = cameraPositionChanged
        context.coordinator.surfaceSelected = surfaceSelected
        view.resetView = resetView
        if view.scene !== scene {
            view.scene = scene
            view.configureNavigation(camera: scene.rootNode.childNodes.first { $0.camera != nil })
            context.coordinator.lastPosition = nil
        }
        applyAppearance(to: view)
    }

    private func applyAppearance(to view: SCNView) {
        let background = NSColor.viewportBackground(darkMode: darkMode)
        view.backgroundColor = background
        scene.background.contents = background
        if tintMesh {
            let color = darkMode
                ? NSColor(calibratedRed: 0.749, green: 0.702, blue: 0.651, alpha: 1)
                : NSColor(calibratedRed: 0.816, green: 0.773, blue: 0.722, alpha: 1)
            scene.rootNode.enumerateChildNodes { node, _ in
                guard node.categoryBitMask == 1 else { return }
                node.geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }

    static func dismantleNSView(_ viewport: MeshSceneViewport, coordinator: Coordinator) {
        coordinator.cameraTimer?.invalidate()
        coordinator.cameraTimer = nil
        viewport.finishResizing()
        viewport.sceneView.scene = nil
    }

    final class Coordinator: NSObject {
        var placementMode: Bool
        var cameraPositionChanged: (SCNVector3, SCNVector3, SCNQuaternion) -> Void
        var surfaceSelected: (SCNVector3) -> Void
        var lastPosition: SCNVector3?
        var cameraTimer: Timer?

        init(placementMode: Bool, cameraPositionChanged: @escaping (SCNVector3, SCNVector3, SCNQuaternion) -> Void, surfaceSelected: @escaping (SCNVector3) -> Void) {
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
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self, weak viewport] _ in
                guard let self, let viewport, viewport.window != nil, !viewport.inLiveResize,
                      let position = viewport.sceneView.pointOfView?.presentation.position,
                      position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
                if let last = self.lastPosition, abs(last.x - position.x) < 0.001, abs(last.y - position.y) < 0.001, abs(last.z - position.z) < 0.001 { return }
                self.lastPosition = position
                self.cameraPositionChanged(position, viewport.sceneView.defaultCameraController.target, viewport.sceneView.pointOfView?.orientation ?? SCNQuaternion(0,0,0,1))
            }
            cameraTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
