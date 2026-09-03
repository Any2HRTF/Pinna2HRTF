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
                    Text("Select a file to preview")
                        .foregroundStyle(.secondary)
                }
            } else {
                PersistentSceneView(scene: store.selectedScene, cameraState: $store.selectedCameraState, darkMode: colorScheme == .dark, placementMode: store.isPlacingMicrophone, cameraPositionChanged: store.updateCameraPosition, surfaceSelected: store.previewMicrophonePosition)
                    .onAppear {
                        store.updateSceneBackground(darkMode: colorScheme == .dark)
                    }
                    .onChange(of: colorScheme) { newColorScheme in
                        store.updateSceneBackground(darkMode: newColorScheme == .dark)
                    }
            }
        }
        .frame(maxHeight: .infinity)
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
    }

    var logSummary: String {
        if !store.runningProcesses.isEmpty || store.environmentProcess != nil { return "Running" }
        if store.logText.isEmpty { return "No output yet" }
        return store.logText.split(separator: "\n").last.map(String.init) ?? "Ready"
    }

    var microphoneCoordinates: String {
        guard let position = store.pendingMicrophonePosition else { return "No position selected" }
        return String(format: "X %.2f · Y %.2f · Z %.2f mm", position.x, position.y, position.z)
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
    @Binding var cameraState: ViewerCameraState?
    let darkMode: Bool
    let placementMode: Bool
    let cameraPositionChanged: (SCNVector3) -> Void
    let surfaceSelected: (SCNVector3) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState, placementMode: placementMode, cameraPositionChanged: cameraPositionChanged, surfaceSelected: surfaceSelected)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        view.delegate = context.coordinator
        view.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectSurface(_:))))
        context.coordinator.scene = scene
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.cameraState = $cameraState
        context.coordinator.placementMode = placementMode
        context.coordinator.cameraPositionChanged = cameraPositionChanged
        context.coordinator.surfaceSelected = surfaceSelected
        view.allowsCameraControl = true
        if view.scene !== scene {
            view.scene = scene
            context.coordinator.scene = scene
            context.coordinator.lastPosition = nil
        }
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var cameraState: Binding<ViewerCameraState?>
        var placementMode: Bool
        var cameraPositionChanged: (SCNVector3) -> Void
        var surfaceSelected: (SCNVector3) -> Void
        weak var scene: SCNScene?
        var lastPosition: SCNVector3?

        init(cameraState: Binding<ViewerCameraState?>, placementMode: Bool, cameraPositionChanged: @escaping (SCNVector3) -> Void, surfaceSelected: @escaping (SCNVector3) -> Void) {
            self.cameraState = cameraState
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
