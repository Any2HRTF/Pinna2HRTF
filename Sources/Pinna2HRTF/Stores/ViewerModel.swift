import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import AppKit

/// The 3D/image viewer: loaded scene, per-project camera memory and microphone placement.
@MainActor
final class ViewerModel: ObservableObject {
    @Published var selectedPressure: URL?
    @Published var selectedMesh: URL?
    @Published var selectedImage: NSImage?
    @Published var selectedScene = SCNScene()
    // Camera persistence is internal state; publishing each redraw invalidates the viewer layout.
    var selectedCameraState: ViewerCameraState?
    @Published var microphonePlacementSide: EarSide?
    @Published var pendingMicrophonePosition: ManualMicrophonePosition?
    @Published var microphonePlacementError: String?
    @Published private var automaticMicrophoneProcesses: [String: Process] = [:]

    private(set) var meshLoadID = UUID()
    private var selectedCameraCenter = SCNVector3Zero
    private var selectedCameraScale: Double = 1
    private var viewerStateByProject: [UUID: ProjectViewerState]
    private var microphonePlacementSession = UUID()
    private var microphonePlacementMeshURL: URL?
    private var automaticMicrophonePositionsByMesh: [String: ManualMicrophonePosition] = [:]
    private var viewerSaveWork: DispatchWorkItem?
    private let viewerSaveQueue = DispatchQueue(label: "Pinna2HRTF.ViewerStateSave", qos: .utility)
    private nonisolated static let microphoneMarkerName = "pinna2hrtf-microphone-marker"

    weak var store: AppStore?

    init() {
        viewerStateByProject = Self.loadViewerStates()
    }

    var isPlacingMicrophone: Bool { microphonePlacementSide != nil }
    var isCalculatingAutomaticMicrophone: Bool { !automaticMicrophoneProcesses.isEmpty }
    var automaticMicrophoneProcessList: [Process] { Array(automaticMicrophoneProcesses.values) }

    private var selectedProjectID: UUID? { store?.selectedProjectID }
    private var selectedProject: ProjectRecord? { store?.selectedProject }
    private func log(_ text: String, for projectID: UUID? = nil) { store?.appendLog(text, for: projectID) }

    // MARK: Viewer

    func forget(_ projectID: UUID) {
        viewerStateByProject[projectID] = nil
    }

    func restoreViewer(artifacts: [Artifact]) {
        clearMicrophonePlacementSession()
        guard let project = selectedProject, let path = viewerStateByProject[project.id]?.selectedArtifactPath,
              let artifact = artifacts.first(where: { $0.url.path == path && $0.exists }) else {
            resetViewer()
            return
        }
        openArtifact(artifact)
    }

    func resetViewer() {
        meshLoadID = UUID()
        selectedPressure = nil
        selectedMesh = nil
        selectedImage = nil
        selectedScene = SCNScene()
        selectedCameraState = nil
        selectedCameraCenter = SCNVector3Zero
        selectedCameraScale = 1
    }

    func openArtifact(_ artifact: Artifact) {
        if artifact.isPressure {
            clearMicrophonePlacementSession()
            resetViewer()
            selectedPressure = artifact.url
            selectedMesh = artifact.url
            rememberSelectedArtifact(artifact.url)
        } else if artifact.isMesh {
            openMesh(artifact.url)
        } else if artifact.isImage {
            openImage(artifact.url)
        } else {
            log("Could not open \(artifact.url.lastPathComponent).")
        }
    }

    func resetSelectedMeshView() {
        guard let projectID = selectedProjectID, let mesh = selectedMesh, selectedImage == nil else { return }
        viewerStateByProject[projectID]?.cameraByArtifact.removeValue(forKey: mesh.path)
        saveViewerStates()
        openMesh(mesh, resetCamera: true)
    }

    func openMesh(_ url: URL, resetCamera: Bool = false) {
        selectedPressure = nil
        guard FileManager.default.fileExists(atPath: url.path), ["stl", "ply"].contains(url.pathExtension.lowercased()) else {
            log("Could not open \(url.lastPathComponent).")
            return
        }
        let darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let projectID = selectedProjectID
        let savedCamera = resetCamera ? nil : projectID.flatMap { viewerStateByProject[$0]?.cameraByArtifact[url.path] }
        let microphonePreview = selectedProject.map { MicrophonePreview(project: $0, microphonePlacementMeshURL: microphonePlacementMeshURL, pendingMicrophonePosition: pendingMicrophonePosition, automaticMicrophonePositionsByMesh: automaticMicrophonePositionsByMesh) }
        let loadID = UUID()
        meshLoadID = loadID
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = Self.loadScene(url: url, darkMode: darkMode, savedCamera: savedCamera, microphonePreview: microphonePreview)
            await self?.finishLoadingMesh(loaded, url: url, loadID: loadID, projectID: projectID, savedCamera: savedCamera, resetCamera: resetCamera)
        }
    }

    private struct LoadedScene: @unchecked Sendable {
        let scene: SCNScene
        let center: SCNVector3
        let maximumDimension: CGFloat
        let cameraPosition: SCNVector3
    }

    private func finishLoadingMesh(_ loaded: LoadedScene?, url: URL, loadID: UUID, projectID: UUID?,
                                   savedCamera: ViewerCameraState?, resetCamera: Bool) {
        guard let loaded else {
            log("Could not load \(url.lastPathComponent): no mesh objects found.")
            return
        }
        guard meshLoadID == loadID, selectedProjectID == projectID else { return }
        selectedMesh = url
        selectedImage = nil
        selectedScene = loaded.scene
        selectedCameraCenter = loaded.center
        selectedCameraScale = max(Double(loaded.maximumDimension), 1)
        let scale = selectedCameraScale
        let center = loaded.center
        let cameraPosition = loaded.cameraPosition
        selectedCameraState = savedCamera ?? ViewerCameraState(x: (Double(cameraPosition.x) - Double(center.x)) / scale, y: (Double(cameraPosition.y) - Double(center.y)) / scale, z: (Double(cameraPosition.z) - Double(center.z)) / scale)
        if resetCamera, let projectID {
            viewerStateByProject[projectID, default: ProjectViewerState(selectedArtifactPath: url.path)].cameraByArtifact[url.path] = selectedCameraState
        }
        rememberSelectedArtifact(url)
    }

    /// Builds the scene off the main thread.
    private nonisolated static func loadScene(url: URL, darkMode: Bool, savedCamera: ViewerCameraState?,
                                              microphonePreview: MicrophonePreview?) -> LoadedScene? {
        let microphone = microphonePreview?.microphonePosition(for: url)
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        let scene = SCNScene()
        for index in 0..<asset.count {
            let object = asset.object(at: index)
            let node = SCNNode(mdlObject: object)
            node.categoryBitMask = 1
            node.geometry?.firstMaterial?.diffuse.contents = meshColor(darkMode: darkMode)
            node.geometry?.firstMaterial?.roughness.contents = 0.72
            scene.rootNode.addChildNode(node)
        }
        let bounds = scene.rootNode.boundingBox
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        let maximumDimension = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        scene.background.contents = backgroundColor(darkMode: darkMode)
        if let microphone {
            let markerNode = microphoneMarkerNode()
            markerNode.position = microphone
            scene.rootNode.addChildNode(markerNode)
        }
        let distance = max(maximumDimension * 1.7, 1)
        let targetNode = SCNNode()
        targetNode.name = "cameraTarget"
        targetNode.position = savedCamera?.target.flatMap { $0.count == 3 ? SCNVector3($0[0], $0[1], $0[2]) : nil } ?? center
        scene.rootNode.addChildNode(targetNode)
        let camera = SCNCamera()
        camera.zFar = 10_000
        camera.fieldOfView = 38
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let frontDirection: CGFloat = url.path.lowercased().contains("left") ? 1 : -1
        let defaultPosition = SCNVector3(center.x, center.y + frontDirection * distance, center.z + maximumDimension * 0.12)
        let cameraPosition: SCNVector3
        if let savedCamera {
            let scale = Double(maximumDimension)
            cameraPosition = SCNVector3(CGFloat(Double(center.x) + savedCamera.x * scale), CGFloat(Double(center.y) + savedCamera.y * scale), CGFloat(Double(center.z) + savedCamera.z * scale))
        } else {
            cameraPosition = defaultPosition
        }
        cameraNode.position = cameraPosition
        let cameraConstraint = SCNLookAtConstraint(target: targetNode)
        cameraConstraint.isGimbalLockEnabled = true
        cameraConstraint.worldUp = SCNVector3(0, 0, 1)
        cameraNode.constraints = [cameraConstraint]
        if let q = savedCamera?.orientation, q.count == 4 {
            cameraNode.constraints = nil
            cameraNode.orientation = SCNQuaternion(q[0], q[1], q[2], q[3])
        }
        scene.rootNode.addChildNode(cameraNode)
        EvenMeshLighting.install(in: scene)
        return LoadedScene(scene: scene, center: center, maximumDimension: maximumDimension, cameraPosition: cameraPosition)
    }

    func openImage(_ url: URL) {
        meshLoadID = UUID()
        selectedPressure = nil
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else {
            log("Could not open \(url.lastPathComponent).")
            return
        }
        selectedMesh = url
        selectedImage = image
        selectedScene = SCNScene()
        selectedCameraState = nil
        rememberSelectedArtifact(url)
    }

    func updateCameraPosition(_ position: SCNVector3, target: SCNVector3, orientation: SCNQuaternion) {
        guard let projectID = selectedProjectID, let selectedMesh, selectedMesh.isFileURL, ["stl", "ply"].contains(selectedMesh.pathExtension.lowercased()), selectedCameraScale > 0 else { return }
        let state = ViewerCameraState(target: [Double(target.x), Double(target.y), Double(target.z)], orientation: [Double(orientation.x), Double(orientation.y), Double(orientation.z), Double(orientation.w)], x: (Double(position.x) - Double(selectedCameraCenter.x)) / selectedCameraScale, y: (Double(position.y) - Double(selectedCameraCenter.y)) / selectedCameraScale, z: (Double(position.z) - Double(selectedCameraCenter.z)) / selectedCameraScale)
        guard state != selectedCameraState else { return }
        selectedCameraState = state
        viewerStateByProject[projectID, default: ProjectViewerState(selectedArtifactPath: selectedMesh.path)].cameraByArtifact[selectedMesh.path] = state
        saveViewerStates()
    }

    func updateSceneBackground(darkMode: Bool) {
        selectedScene.background.contents = Self.backgroundColor(darkMode: darkMode)
        selectedScene.rootNode.enumerateChildNodes { node, _ in
            guard node.categoryBitMask == 1 else { return }
            node.geometry?.firstMaterial?.diffuse.contents = Self.meshColor(darkMode: darkMode)
        }
    }

    private nonisolated static func backgroundColor(darkMode: Bool) -> NSColor {
        darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    private nonisolated static func meshColor(darkMode: Bool) -> NSColor {
        darkMode ? NSColor(calibratedRed: 0.749, green: 0.702, blue: 0.651, alpha: 1) : NSColor(calibratedRed: 0.816, green: 0.773, blue: 0.722, alpha: 1)
    }

    private func rememberSelectedArtifact(_ url: URL) {
        guard let projectID = selectedProjectID else { return }
        viewerStateByProject[projectID, default: ProjectViewerState(selectedArtifactPath: nil)].selectedArtifactPath = url.path
        saveViewerStates()
    }

    private func saveViewerStates() {
        viewerSaveWork?.cancel()
        let states = viewerStateByProject
        let destination = Defaults.appDataURL.appendingPathComponent("viewer-state.json")
        let work = DispatchWorkItem {
            self.viewerSaveQueue.async {
                guard let data = try? JSONEncoder.pretty.encode(states) else { return }
                try? data.write(to: destination, options: .atomic)
            }
        }
        viewerSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static func loadViewerStates() -> [UUID: ProjectViewerState] {
        let url = Defaults.appDataURL.appendingPathComponent("viewer-state.json")
        guard let data = try? Data(contentsOf: url), let states = try? JSONDecoder().decode([UUID: ProjectViewerState].self, from: data) else { return [:] }
        return states
    }

    // MARK: Microphone placement

    func beginMicrophonePlacement(_ side: EarSide) {
        guard let store, let project = selectedProject, !store.selectedProjectIsRunning else { return }
        microphonePlacementSession = UUID()
        let sourcePath = side == .left ? project.pipelineLeftEar : project.pipelineRightEar
        guard !sourcePath.isEmpty else {
            microphonePlacementError = "Select a \(side.rawValue) ear mesh before placing its microphone."
            return
        }
        guard let meshURL = ArtifactScanner.preprocessingMesh(for: project, side: side), let identity = ArtifactScanner.meshIdentity(meshURL) else {
            let inferenceRequired = project.settings.inference.usePredictionsForPreprocessing && !project.pipelineLeftEar.isEmpty && !project.pipelineRightEar.isEmpty
            microphonePlacementError = inferenceRequired ? "Run Mesh2PPM Inference before placing the \(side.rawValue) microphone." : "The \(side.rawValue) preprocessing mesh could not be opened."
            return
        }
        microphonePlacementSide = side
        microphonePlacementMeshURL = meshURL
        pendingMicrophonePosition = ArtifactScanner.validManualMicrophonePosition(for: project, side: side)
        if let pendingMicrophonePosition, pendingMicrophonePosition.meshIdentity != identity {
            self.pendingMicrophonePosition = nil
        }
        if selectedMesh?.standardizedFileURL.path != meshURL.standardizedFileURL.path {
            openMesh(meshURL)
        }
    }

    func previewMicrophonePosition(_ position: SCNVector3) {
        guard let meshURL = microphonePlacementMeshURL, let identity = ArtifactScanner.meshIdentity(meshURL), selectedMesh?.standardizedFileURL.path == meshURL.standardizedFileURL.path else { return }
        let placement = ManualMicrophonePosition(x: Double(position.x), y: Double(position.y), z: Double(position.z), meshPath: meshURL.standardizedFileURL.path, meshIdentity: identity)
        pendingMicrophonePosition = placement
        updateMicrophoneMarker(position)
    }

    func completeMicrophonePlacement() {
        guard let side = microphonePlacementSide, let placement = pendingMicrophonePosition, let meshURL = microphonePlacementMeshURL, placement.meshPath == meshURL.standardizedFileURL.path, placement.meshIdentity == ArtifactScanner.meshIdentity(meshURL) else {
            microphonePlacementError = "Click the mesh or find an automatic position first."
            return
        }
        guard let store, let project = selectedProject, !store.selectedProjectIsRunning,
              ArtifactScanner.preprocessingMesh(for: project, side: side)?.standardizedFileURL == meshURL.standardizedFileURL else { return }
        clearMicrophonePlacementSession()
        store.updateSelectedProject { project in
            if side == .left {
                project.settings.preprocessing.sourcePositionInputLeft = placement
            } else {
                project.settings.preprocessing.sourcePositionInputRight = placement
            }
        }
        log("\(side.title) microphone saved.")
    }

    func cancelMicrophonePlacement() {
        guard microphonePlacementSide != nil else { return }
        let meshURL = microphonePlacementMeshURL
        clearMicrophonePlacementSession()
        if let meshURL, selectedMesh?.standardizedFileURL.path == meshURL.standardizedFileURL.path {
            openMesh(meshURL)
        }
    }

    func useAutomaticMicrophonePosition(_ side: EarSide) {
        guard let store, let project = selectedProject else { return }
        let meshURL = ArtifactScanner.preprocessingMesh(for: project, side: side)
        guard !store.selectedProjectIsRunning, !isCalculatingAutomaticMicrophone else { return }
        let session = microphonePlacementSession
        let keepingPlacement = microphonePlacementSide == side
        if keepingPlacement {
            pendingMicrophonePosition = nil
            updateMicrophoneMarker(nil)
        } else {
            store.updateSelectedProject { project in
                if side == .left {
                    project.settings.preprocessing.sourcePositionInputLeft = nil
                } else {
                    project.settings.preprocessing.sourcePositionInputRight = nil
                }
            }
            clearMicrophonePlacementSession()
        }
        if !keepingPlacement, let meshURL, selectedMesh?.standardizedFileURL.path == meshURL.standardizedFileURL.path {
            openMesh(meshURL)
        }
        guard let meshURL else {
            log("\(side.title) microphone mesh unavailable.")
            return
        }
        log(keepingPlacement ? "Finding \(side.rawValue) microphone position. Select Done to save." : "Finding \(side.rawValue) microphone position.")
        calculateAutomaticMicrophonePosition(for: meshURL, side: side, environment: store.environment) { [weak self] position in
            guard let self, self.selectedProjectID == project.id, self.microphonePlacementSession == session,
                  !keepingPlacement || self.microphonePlacementSide == side else { return }
            if let position {
                self.automaticMicrophonePositionsByMesh[position.meshIdentity] = position
                if keepingPlacement {
                    self.pendingMicrophonePosition = position
                    self.microphonePlacementMeshURL = meshURL
                    self.updateMicrophoneMarker(SCNVector3(Float(position.x), Float(position.y), Float(position.z)))
                } else if self.selectedMesh?.standardizedFileURL.path == meshURL.standardizedFileURL.path {
                    self.openMesh(meshURL)
                }
                if keepingPlacement { self.log("Position found. Select Done to save.", for: project.id) }
                self.log("\(side.title) microphone: [\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z))] mm.")
            } else {
                self.log("\(side.title) microphone calculation failed.")
            }
        }
    }

    private func calculateAutomaticMicrophonePosition(for meshURL: URL, side: EarSide, environment: EnvironmentConfig,
                                                      completion: @escaping @MainActor (ManualMicrophonePosition?) -> Void) {
        guard let identity = ArtifactScanner.meshIdentity(meshURL) else {
            completion(nil)
            return
        }
        let landmarkURL = Defaults.appDataURL.appendingPathComponent("Cache/automatic-landmark-\(UUID().uuidString).json")
        try? FileManager.default.createDirectory(at: landmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process: Process
        do {
            process = try ProcessLauncher.shared.makeProcess(.python(["-m", "HRTFCalculation.Preprocessing.src.ear_canal_closer", "--ear_path", meshURL.path, "--landmark_path", landmarkURL.path, "--side", side.rawValue, "--estimate-only"]), environment: environment)
        } catch {
            completion(nil)
            return
        }
        automaticMicrophoneProcesses[landmarkURL.path] = process
        Task { @MainActor [weak self] in
            let succeeded = (try? await ProcessLauncher.shared.runHelperAsync(process, timeout: 600))?.status == 0
            let result: ManualMicrophonePosition?
            if succeeded, let data = try? Data(contentsOf: landmarkURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = object["position"] as? [NSNumber], values.count == 3 {
                result = ManualMicrophonePosition(x: values[0].doubleValue, y: values[1].doubleValue, z: values[2].doubleValue, meshPath: meshURL.standardizedFileURL.path, meshIdentity: identity)
            } else {
                result = nil
            }
            try? FileManager.default.removeItem(at: landmarkURL)
            self?.automaticMicrophoneProcesses[landmarkURL.path] = nil
            completion(result)
        }
    }

    func clearMicrophonePlacementSession() {
        microphonePlacementSession = UUID()
        microphonePlacementSide = nil
        pendingMicrophonePosition = nil
        microphonePlacementMeshURL = nil
    }

    func updateMicrophoneMarker(_ position: SCNVector3?) {
        selectedScene.rootNode.childNode(withName: Self.microphoneMarkerName, recursively: true)?.removeFromParentNode()
        guard let position else { return }
        let markerNode = Self.microphoneMarkerNode()
        markerNode.position = position
        selectedScene.rootNode.addChildNode(markerNode)
    }

    private nonisolated static func microphoneMarkerNode() -> SCNNode {
        let marker = SCNSphere(radius: 0.8)
        marker.segmentCount = 32
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.957, green: 0.478, blue: 0.086, alpha: 1)
        material.metalness.contents = 0.82
        material.roughness.contents = 0.14
        material.specular.contents = NSColor.white
        marker.firstMaterial = material
        let markerNode = SCNNode(geometry: marker)
        markerNode.name = microphoneMarkerName
        markerNode.categoryBitMask = 2
        return markerNode
    }
}
