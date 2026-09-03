import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import AppKit
import UserNotifications

final class AppStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var projects: [ProjectRecord]
    @Published var selectedProjectID: UUID?
    @Published var environment: EnvironmentConfig
    @Published var logText = ""
    @Published var selectedMesh: URL?
    @Published var selectedImage: NSImage?
    @Published var selectedScene = SCNScene()
    @Published var selectedCameraState: ViewerCameraState?
    @Published var microphonePlacementSide: EarSide?
    @Published var pendingMicrophonePosition: ManualMicrophonePosition?
    @Published var microphonePlacementError: String?
    @Published var artifacts: [Artifact] = []
    @Published var stageStates: [Stage: StageState] = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, .ready) })
    @Published var runningProcesses: [UUID: Process] = [:]
    @Published var runningStages: [UUID: Stage] = [:]
    @Published var environmentProcess: Process?
    @Published var failedStagesByProject: [UUID: Set<Stage>] = [:]
    private var logTextByProject: [UUID: String] = [:]
    private var viewerStateByProject: [UUID: ProjectViewerState] = [:]
    private var selectedCameraCenter = SCNVector3Zero
    private var selectedCameraScale: Double = 1
    private var microphonePlacementMeshURL: URL?
    private var automaticMicrophonePositionsByMesh: [String: ManualMicrophonePosition] = [:]
    @Published private var automaticMicrophoneProcesses: [String: Process] = [:]
    private let microphoneMarkerName = "pinna2hrtf-microphone-marker"

    let rootURL: URL
    let packageURL: URL
    let registryStore: ProjectRegistryStore

    override init() {
        rootURL = Defaults.runtimeRoot
        packageURL = Defaults.pipelineRoot
        registryStore = ProjectRegistryStore(rootURL: rootURL, packageURL: packageURL)
        if Defaults.isPackagedApp {
            for obsolete in [Defaults.runtimeProjectURL, Defaults.appDataURL.appendingPathComponent("Cache/uv", isDirectory: true)] {
                try? FileManager.default.removeItem(at: obsolete)
            }
        }
        var registry = AppStore.migrated(registryStore.load(), rootURL: rootURL, packageURL: packageURL)
        if Defaults.isPackagedApp {
            registry.environment = Defaults.environment(root: rootURL)
        }
        projects = registry.projects
        selectedProjectID = registry.selectedProjectID ?? registry.projects.first?.id
        environment = registry.environment
        viewerStateByProject = Self.loadViewerStates()
        super.init()
        configureNotifications()
        registryStore.save(ProjectRegistry(projects: projects, selectedProjectID: selectedProjectID, environment: environment))
        refreshArtifacts()
        restoreViewer()
    }

    var selectedProject: ProjectRecord? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedProjectIndex: Int? {
        projects.firstIndex { $0.id == selectedProjectID }
    }

    var selectedProjectIsRunning: Bool {
        guard let selectedProject else { return false }
        return runningProcesses[selectedProject.id] != nil
    }

    var selectedProjectHasGeneratedOutputs: Bool {
        guard let selectedProject else { return false }
        guard (!selectedProject.leftEar.isEmpty || !selectedProject.rightEar.isEmpty) && !selectedProject.saveLocation.isEmpty else { return false }
        return (selectedProject.settings.inference.usePredictionsForPreprocessing && ArtifactScanner.stageIsComplete(.inference, project: selectedProject)) || ArtifactScanner.stageIsComplete(.preprocessing, project: selectedProject) || ArtifactScanner.stageIsComplete(.numcalc, project: selectedProject) || ArtifactScanner.stageIsComplete(.postprocessing, project: selectedProject)
    }

    var inferenceResourceURL: URL {
        packageURL.appendingPathComponent("HRTFCalculation/Inference/resources")
    }

    var modelOptions: [String] {
        let available = Set(resourceOptions(extensions: ["yaml", "yml"]).map(Self.modelName))
        return ["1 Views", "3 Views", "9 Views", "25 Views"].filter { available.contains($0) }
    }

    var registry: ProjectRegistry {
        ProjectRegistry(projects: projects, selectedProjectID: selectedProjectID, environment: environment)
    }

    func persist() {
        registryStore.save(registry)
    }

    func createProject() {
        let project = Defaults.newProject(packageRoot: packageURL, index: projects.count + 1)
        projects.append(project)
        selectedProjectID = project.id
        failedStagesByProject[project.id] = []
        persist()
        refreshArtifacts()
    }

    func duplicateSelectedProject() {
        guard let selectedProject else { return }
        var duplicate = selectedProject
        duplicate.id = UUID()
        duplicate.name = "\(selectedProject.name) Copy"
        if !selectedProject.saveLocation.isEmpty {
            let originalURL = URL(fileURLWithPath: selectedProject.saveLocation)
            let baseName = originalURL.lastPathComponent.isEmpty ? "Project" : originalURL.lastPathComponent
            var duplicateURL = originalURL.deletingLastPathComponent().appendingPathComponent("\(baseName) Copy", isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: duplicateURL.path) {
                duplicateURL = originalURL.deletingLastPathComponent().appendingPathComponent("\(baseName) Copy \(suffix)", isDirectory: true)
                suffix += 1
            }
            duplicate.saveLocation = duplicateURL.path
            if FileManager.default.fileExists(atPath: originalURL.path) {
                do {
                    try FileManager.default.copyItem(at: originalURL, to: duplicateURL)
                    let originalPath = originalURL.standardizedFileURL.path
                    let duplicatePath = duplicateURL.standardizedFileURL.path
                    let relocated: (String) -> String = { path in
                        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                        guard normalized == originalPath || normalized.hasPrefix(originalPath + "/") else { return path }
                        return duplicatePath + String(normalized.dropFirst(originalPath.count))
                    }
                    duplicate.leftEar = relocated(duplicate.leftEar)
                    duplicate.rightEar = relocated(duplicate.rightEar)
                    let settingsURL = duplicateURL.appendingPathComponent("Project Settings.yaml")
                    if let settings = try? String(contentsOf: settingsURL, encoding: .utf8) {
                        try? settings.replacingOccurrences(of: originalPath, with: duplicatePath).write(to: settingsURL, atomically: true, encoding: .utf8)
                    }
                } catch {
                    appendLog("Could not duplicate project folder: \(error.localizedDescription)")
                    return
                }
            }
        }
        duplicate.settings.preprocessing.sourcePositionInputLeft = nil
        duplicate.settings.preprocessing.sourcePositionInputRight = nil
        projects.append(duplicate)
        selectedProjectID = duplicate.id
        failedStagesByProject[duplicate.id] = []
        persist()
        refreshArtifacts()
    }

    func importProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose an existing Pinna2HRTF project folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importProject(from: folder)
    }

    func importProject(from folder: URL) {
        var project = Defaults.newProject(packageRoot: packageURL, index: projects.count + 1)
        project.name = folder.lastPathComponent
        project.leftEar = importedMesh(in: folder, side: "Left")
        project.rightEar = importedMesh(in: folder, side: "Right")
        project.saveLocation = folder.path
        project.inputHandling = .reference
        let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let legacyIntermediates = entries?.first(where: { $0.lastPathComponent == "intermediates" })
        let currentIntermediates = entries?.first(where: { $0.lastPathComponent == "Intermediates" })
        if let legacyIntermediates, currentIntermediates == nil {
            let migrationPath = folder.appendingPathComponent(".pinna2hrtf-intermediates-migration")
            try? FileManager.default.moveItem(at: legacyIntermediates, to: migrationPath)
            try? FileManager.default.moveItem(at: migrationPath, to: folder.appendingPathComponent("Intermediates"))
        }
        for configName in ["Project Settings.yaml", ".pinna2hrtf_native_run.yaml", "pipeline.yaml"] {
            let configURL = folder.appendingPathComponent(configName)
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { continue }
            var section = ""
            for line in config.components(separatedBy: .newlines) {
                if !line.hasPrefix(" "), line.hasSuffix(":") {
                    section = String(line.dropLast())
                }
                let setting = line.trimmingCharacters(in: .whitespaces)
                if section == "inference" && (setting == "enabled: false" || setting == "use_predictions_for_preprocessing: false") {
                    project.settings.inference.usePredictionsForPreprocessing = false
                }
            }
        }
        projects.append(project)
        selectedProjectID = project.id
        failedStagesByProject[project.id] = []
        persist()
        refreshArtifacts()
        let completed = Stage.allCases.filter { ArtifactScanner.stageIsComplete($0, project: project) }.map(\.title)
        let completedText = completed.isEmpty ? "none detected" : completed.joined(separator: ", ")
        appendLog("Imported. Completed: \(completedText).")
    }

    func importedMesh(in folder: URL, side: String) -> String {
        let sideFolder = folder.appendingPathComponent("Input/\(side)")
        let intermediateFolder = folder.appendingPathComponent("Intermediates/\(side)")
        let intermediateInferenceFolder = folder.appendingPathComponent("Intermediates/Prediction STL \(side)")
        let intermediateRegistrationFolder = folder.appendingPathComponent("Intermediates/ICP STL \(side)")
        let targetFolder = folder.appendingPathComponent("Target STL \(side)")
        let inferenceFolder = folder.appendingPathComponent("Prediction STL \(side)")
        let registrationFolder = folder.appendingPathComponent("ICP STL \(side)")
        for candidate in [sideFolder, intermediateFolder, intermediateInferenceFolder, intermediateRegistrationFolder, targetFolder, registrationFolder, inferenceFolder] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil) else { continue }
            if let exact = files.first(where: { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(side) == .orderedSame && ["stl", "ply"].contains($0.pathExtension.lowercased()) }) {
                return exact.path
            }
            if let mesh = files.first(where: { ["stl", "ply"].contains($0.pathExtension.lowercased()) }) {
                return mesh.path
            }
        }
        for name in [side, side.lowercased(), side.uppercased()] {
            for suffix in ["stl", "ply"] {
                let candidate = folder.appendingPathComponent("\(name).\(suffix)")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            }
        }
        return ""
    }

    func forgetSelectedProject() {
        guard let selectedProjectID else { return }
        runningProcesses[selectedProjectID]?.terminate()
        runningProcesses[selectedProjectID] = nil
        runningStages[selectedProjectID] = nil
        failedStagesByProject[selectedProjectID] = nil
        logTextByProject[selectedProjectID] = nil
        projects.removeAll { $0.id == selectedProjectID }
        self.selectedProjectID = projects.first?.id
        persist()
        refreshArtifacts()
    }

    func updateSelectedProject(refresh: Bool = true, _ update: (inout ProjectRecord) -> Void) {
        guard let index = selectedProjectIndex else { return }
        update(&projects[index])
        persist()
        if refresh {
            refreshArtifacts()
        }
    }

    func setBezierPPM(_ enabled: Bool) {
        updateSelectedProject { $0.settings.inference.usePredictionsForPreprocessing = enabled }
    }

    func updateEnvironment(_ update: (inout EnvironmentConfig) -> Void) {
        update(&environment)
        persist()
    }

    func resourceOptions(extensions allowedExtensions: Set<String>) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: inferenceResourceURL, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.path)
    }

    func selectedModelName(for project: ProjectRecord?) -> String {
        Self.modelName(project?.settings.inference.modelConfig ?? "")
    }

    func setSelectedModelName(_ name: String) {
        let config = inferenceResourceURL.appendingPathComponent("Local \(name).yaml").path
        let checkpoint = inferenceResourceURL.appendingPathComponent("Local \(name).pth").path
        updateSelectedProject(refresh: false) {
            $0.settings.inference.modelConfig = config
            $0.settings.inference.modelCheckpoint = checkpoint
        }
    }

    static func modelName(_ path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return stem.hasPrefix("Local ") ? String(stem.dropFirst("Local ".count)) : stem
    }

    func refreshArtifacts() {
        guard let selectedProject else {
            artifacts = []
            stageStates = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, .ready) })
            return
        }
        artifacts = ArtifactScanner.artifacts(for: selectedProject)
        stageStates = ArtifactScanner.stageStates(for: selectedProject, runningStage: runningStages[selectedProject.id], failedStages: failedStagesByProject[selectedProject.id] ?? [])
    }

    func restoreViewer() {
        clearMicrophonePlacementSession()
        guard let project = selectedProject, let path = viewerStateByProject[project.id]?.selectedArtifactPath, let artifact = artifacts.first(where: { $0.url.path == path && $0.exists }) else {
            resetViewer()
            return
        }
        openArtifact(artifact)
    }

    func resetViewer() {
        selectedMesh = nil
        selectedImage = nil
        selectedScene = SCNScene()
        selectedCameraState = nil
        selectedCameraCenter = SCNVector3Zero
        selectedCameraScale = 1
    }

    func openArtifact(_ artifact: Artifact) {
        if artifact.isMesh {
            openMesh(artifact.url)
        } else if artifact.isImage {
            openImage(artifact.url)
        } else {
            appendLog("Could not open \(artifact.url.lastPathComponent).")
        }
    }

    func openMesh(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), ["stl", "ply"].contains(url.pathExtension.lowercased()) else {
            appendLog("Could not open \(url.lastPathComponent).")
            return
        }
        let asset = MDLAsset(url: url)
        let scene = SCNScene()
        let darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for index in 0..<asset.count {
            let object = asset.object(at: index)
            let node = SCNNode(mdlObject: object)
            node.categoryBitMask = 1
            node.geometry?.firstMaterial?.diffuse.contents = darkMode ? NSColor(calibratedRed: 0.749, green: 0.702, blue: 0.651, alpha: 1) : NSColor(calibratedRed: 0.816, green: 0.773, blue: 0.722, alpha: 1)
            node.geometry?.firstMaterial?.roughness.contents = 0.72
            scene.rootNode.addChildNode(node)
        }
        let bounds = scene.rootNode.boundingBox
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        let maximumDimension = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        scene.background.contents = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        if let microphone = microphonePosition(for: url) {
            let markerNode = microphoneMarkerNode()
            markerNode.position = microphone
            scene.rootNode.addChildNode(markerNode)
        }
        let distance = max(maximumDimension * 1.7, 1)
        let targetNode = SCNNode()
        targetNode.position = center
        scene.rootNode.addChildNode(targetNode)
        let camera = SCNCamera()
        camera.zFar = 10_000
        camera.fieldOfView = 38
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let frontDirection: CGFloat = url.path.lowercased().contains("left") ? 1 : -1
        let defaultPosition = SCNVector3(center.x, center.y + frontDirection * distance, center.z + maximumDimension * 0.12)
        let savedCamera = selectedProjectID.flatMap { viewerStateByProject[$0]?.cameraByArtifact[url.path] }
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
        scene.rootNode.addChildNode(cameraNode)
        let light = SCNLight()
        light.type = .directional
        light.intensity = 900
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(-Float(maximumDimension) * 0.65, Float(maximumDimension) * 0.75, -Float(maximumDimension) * 0.9)
        cameraNode.addChildNode(lightNode)
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 140
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)
        selectedMesh = url
        selectedImage = nil
        selectedScene = scene
        selectedCameraCenter = center
        selectedCameraScale = Double(maximumDimension)
        let scale = selectedCameraScale
        selectedCameraState = savedCamera ?? ViewerCameraState(x: (Double(cameraPosition.x) - Double(center.x)) / scale, y: (Double(cameraPosition.y) - Double(center.y)) / scale, z: (Double(cameraPosition.z) - Double(center.z)) / scale)
        rememberSelectedArtifact(url)
    }

    func microphonePosition(for meshURL: URL) -> SCNVector3? {
        if let microphonePlacementMeshURL, microphonePlacementMeshURL.standardizedFileURL.path == meshURL.standardizedFileURL.path, let pendingMicrophonePosition {
            return SCNVector3(CGFloat(pendingMicrophonePosition.x), CGFloat(pendingMicrophonePosition.y), CGFloat(pendingMicrophonePosition.z))
        }
        if let project = selectedProject {
            if let side = meshSide(for: meshURL, project: project), let position = ArtifactScanner.validManualMicrophonePosition(for: project, side: side) {
                return SCNVector3(CGFloat(position.x), CGFloat(position.y), CGFloat(position.z))
            }
        }
        if let identity = ArtifactScanner.meshIdentity(meshURL) {
            for position in automaticMicrophonePositionsByMesh.values where position.meshPath == meshURL.standardizedFileURL.path && position.meshIdentity == identity {
                return SCNVector3(Float(position.x), Float(position.y), Float(position.z))
            }
        }
        guard meshURL.lastPathComponent.caseInsensitiveCompare("graded_head.ply") == .orderedSame, let project = selectedProject else { return nil }
        let side: String
        if meshURL.path.lowercased().contains("/left/") {
            side = "Left"
        } else if meshURL.path.lowercased().contains("/right/") {
            side = "Right"
        } else {
            return nil
        }
        let parametersURL = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Projects/\(side)/parameters.json")
        guard let data = try? Data(contentsOf: parametersURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = object["sourceCenter"] as? [NSNumber], values.count == 3 else { return nil }
        return SCNVector3(Float(values[0].doubleValue * 1000), Float(values[1].doubleValue * 1000), Float(values[2].doubleValue * 1000))
    }

    func meshSide(for meshURL: URL, project: ProjectRecord) -> EarSide? {
        let path = meshURL.standardizedFileURL.path
        if !project.leftEar.isEmpty && path == URL(fileURLWithPath: project.leftEar).standardizedFileURL.path { return .left }
        if !project.rightEar.isEmpty && path == URL(fileURLWithPath: project.rightEar).standardizedFileURL.path { return .right }
        let output = URL(fileURLWithPath: project.saveLocation).standardizedFileURL
        let leftPrefixes = [
            output.appendingPathComponent("Intermediates/Left").path,
            output.appendingPathComponent(project.settings.inference.predictionLeftFolder).path,
            output.appendingPathComponent("Projects/Left").path
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let rightPrefixes = [
            output.appendingPathComponent("Intermediates/Right").path,
            output.appendingPathComponent(project.settings.inference.predictionRightFolder).path,
            output.appendingPathComponent("Projects/Right").path
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if leftPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .left }
        if rightPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .right }
        return nil
    }

    var selectedMeshHasMicrophoneMarker: Bool {
        selectedMesh.flatMap(microphonePosition) != nil
    }

    var isPlacingMicrophone: Bool {
        microphonePlacementSide != nil
    }

    var isCalculatingAutomaticMicrophone: Bool {
        !automaticMicrophoneProcesses.isEmpty
    }

    func hasManualMicrophonePosition(_ side: EarSide) -> Bool {
        guard let project = selectedProject else { return false }
        return ArtifactScanner.manualMicrophonePosition(for: project, side: side) != nil
    }

    func beginMicrophonePlacement(_ side: EarSide) {
        guard let project = selectedProject else { return }
        let sourcePath = side == .left ? project.leftEar : project.rightEar
        guard !sourcePath.isEmpty else {
            microphonePlacementError = "Select a \(side.rawValue) ear mesh before placing its microphone."
            return
        }
        guard let meshURL = ArtifactScanner.preprocessingMesh(for: project, side: side), let identity = ArtifactScanner.meshIdentity(meshURL) else {
            let inferenceRequired = project.settings.inference.usePredictionsForPreprocessing && !project.leftEar.isEmpty && !project.rightEar.isEmpty
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
            microphonePlacementError = "Click the mesh surface to choose a valid microphone position."
            return
        }
        updateSelectedProject(refresh: false) { project in
            if side == .left {
                project.settings.preprocessing.sourcePositionInputLeft = placement
            } else {
                project.settings.preprocessing.sourcePositionInputRight = placement
            }
        }
        clearMicrophonePlacementSession()
        appendLog("\(side.title) mic saved.")
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
        guard let project = selectedProject else { return }
        let meshURL = ArtifactScanner.preprocessingMesh(for: project, side: side)
        let keepingPlacement = microphonePlacementSide == side
        if keepingPlacement {
            pendingMicrophonePosition = nil
            updateMicrophoneMarker(nil)
        } else {
            updateSelectedProject(refresh: false) { project in
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
            appendLog("\(side.title) mic mesh unavailable.")
            return
        }
        appendLog(keepingPlacement ? "Calculating \(side.rawValue) mic. Press Done to save." : "Calculating \(side.rawValue) mic.")
        calculateAutomaticMicrophonePosition(for: meshURL, side: side) { [weak self] position in
            guard let self else { return }
            if let position {
                self.automaticMicrophonePositionsByMesh[position.meshIdentity] = position
                if keepingPlacement {
                    self.pendingMicrophonePosition = position
                    self.microphonePlacementMeshURL = meshURL
                    self.updateMicrophoneMarker(SCNVector3(Float(position.x), Float(position.y), Float(position.z)))
                } else if self.selectedMesh?.standardizedFileURL.path == meshURL.standardizedFileURL.path {
                    self.openMesh(meshURL)
                }
                self.appendLog("\(side.title) mic: [\(String(format: "%.3f", position.x)), \(String(format: "%.3f", position.y)), \(String(format: "%.3f", position.z))] mm.")
            } else {
                self.appendLog("\(side.title) mic calculation failed.")
            }
        }
    }

    func calculateAutomaticMicrophonePosition(for meshURL: URL, side: EarSide, completion: @escaping (ManualMicrophonePosition?) -> Void) {
        guard let identity = ArtifactScanner.meshIdentity(meshURL) else {
            completion(nil)
            return
        }
        let landmarkURL = Defaults.appDataURL.appendingPathComponent("Cache/automatic-landmark-\(UUID().uuidString).json")
        try? FileManager.default.createDirectory(at: landmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        if Defaults.isPackagedApp {
            process.executableURL = runtimePythonURL
            process.arguments = ["-m", "HRTFCalculation.Preprocessing.src.ear_canal_closer", "--ear_path", meshURL.path, "--landmark_path", landmarkURL.path, "--side", side.rawValue, "--estimate-only"]
        } else {
            let bundledUV = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
            process.executableURL = bundledUV ? URL(fileURLWithPath: environment.uvExecutable) : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = bundledUV ? ["run", "--no-sync", "python", "-m", "HRTFCalculation.Preprocessing.src.ear_canal_closer", "--ear_path", meshURL.path, "--landmark_path", landmarkURL.path, "--side", side.rawValue, "--estimate-only"] : ["uv", "run", "--no-sync", "python", "-m", "HRTFCalculation.Preprocessing.src.ear_canal_closer", "--ear_path", meshURL.path, "--landmark_path", landmarkURL.path, "--side", side.rawValue, "--estimate-only"]
        }
        process.currentDirectoryURL = executionPackageURL
        process.environment = processEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        automaticMicrophoneProcesses[landmarkURL.path] = process
        process.terminationHandler = { [weak self] process in
            let result: ManualMicrophonePosition?
            if process.terminationStatus == 0, let data = try? Data(contentsOf: landmarkURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = object["position"] as? [NSNumber], values.count == 3 {
                result = ManualMicrophonePosition(x: values[0].doubleValue, y: values[1].doubleValue, z: values[2].doubleValue, meshPath: meshURL.standardizedFileURL.path, meshIdentity: identity)
            } else {
                result = nil
            }
            try? FileManager.default.removeItem(at: landmarkURL)
            Task { @MainActor in
                self?.automaticMicrophoneProcesses[landmarkURL.path] = nil
                completion(result)
            }
        }
        do {
            try process.run()
        } catch {
            automaticMicrophoneProcesses[landmarkURL.path] = nil
            try? FileManager.default.removeItem(at: landmarkURL)
            completion(nil)
        }
    }

    func clearMicrophonePlacementSession() {
        microphonePlacementSide = nil
        pendingMicrophonePosition = nil
        microphonePlacementMeshURL = nil
    }

    func updateMicrophoneMarker(_ position: SCNVector3?) {
        selectedScene.rootNode.childNode(withName: microphoneMarkerName, recursively: true)?.removeFromParentNode()
        guard let position else { return }
        let markerNode = microphoneMarkerNode()
        markerNode.position = position
        selectedScene.rootNode.addChildNode(markerNode)
    }

    private func microphoneMarkerNode() -> SCNNode {
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

    func updateSceneBackground(darkMode: Bool) {
        selectedScene.background.contents = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        selectedScene.rootNode.enumerateChildNodes { node, _ in
            guard node.categoryBitMask == 1 else { return }
            node.geometry?.firstMaterial?.diffuse.contents = darkMode ? NSColor(calibratedRed: 0.749, green: 0.702, blue: 0.651, alpha: 1) : NSColor(calibratedRed: 0.816, green: 0.773, blue: 0.722, alpha: 1)
        }
    }

    func openImage(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else {
            appendLog("Could not open \(url.lastPathComponent).")
            return
        }
        selectedMesh = url
        selectedImage = image
        selectedScene = SCNScene()
        selectedCameraState = nil
        rememberSelectedArtifact(url)
    }

    func updateCameraPosition(_ position: SCNVector3) {
        guard let projectID = selectedProjectID, let selectedMesh, selectedMesh.isFileURL, ["stl", "ply"].contains(selectedMesh.pathExtension.lowercased()), selectedCameraScale > 0 else { return }
        let state = ViewerCameraState(x: (Double(position.x) - Double(selectedCameraCenter.x)) / selectedCameraScale, y: (Double(position.y) - Double(selectedCameraCenter.y)) / selectedCameraScale, z: (Double(position.z) - Double(selectedCameraCenter.z)) / selectedCameraScale)
        guard state != selectedCameraState else { return }
        selectedCameraState = state
        viewerStateByProject[projectID, default: ProjectViewerState(selectedArtifactPath: selectedMesh.path)].cameraByArtifact[selectedMesh.path] = state
        saveViewerStates()
    }

    private func rememberSelectedArtifact(_ url: URL) {
        guard let projectID = selectedProjectID else { return }
        viewerStateByProject[projectID, default: ProjectViewerState(selectedArtifactPath: nil)].selectedArtifactPath = url.path
        saveViewerStates()
    }

    private func saveViewerStates() {
        guard let data = try? JSONEncoder.pretty.encode(viewerStateByProject) else { return }
        try? data.write(to: Defaults.appDataURL.appendingPathComponent("viewer-state.json"), options: .atomic)
    }

    private static func loadViewerStates() -> [UUID: ProjectViewerState] {
        let url = Defaults.appDataURL.appendingPathComponent("viewer-state.json")
        guard let data = try? Data(contentsOf: url), let states = try? JSONDecoder().decode([UUID: ProjectViewerState].self, from: data) else { return [:] }
        return states
    }

    func runNextStage() {
        guard let project = selectedProject else {
            appendLog("Create or select a project before running.")
            return
        }
        let stage = Stage.allCases.first { !ArtifactScanner.stageIsComplete($0, project: project) } ?? .postprocessing
        run(stage: stage)
    }

    func stageBlocked(_ stage: Stage) -> Bool {
        guard let project = selectedProject else { return false }
        return stage == .preprocessing && project.settings.inference.usePredictionsForPreprocessing && !ArtifactScanner.stageIsComplete(.inference, project: project)
    }

    func canRun(stage: Stage) -> Bool {
        guard let project = selectedProject else { return false }
        if let active = runningStages[project.id], runningProcesses[project.id] != nil {
            return active == stage
        }
        guard environmentProcess == nil else { return false }
        return stageCanRun(stage, project: project)
    }

    func canRunNextStage() -> Bool {
        guard let project = selectedProject, runningProcesses[project.id] == nil else { return false }
        guard let next = Stage.allCases.first(where: { !ArtifactScanner.stageIsComplete($0, project: project) }) else { return false }
        return canRun(stage: next)
    }

    func stageCanRun(_ stage: Stage, project: ProjectRecord) -> Bool {
        guard (!project.leftEar.isEmpty || !project.rightEar.isEmpty), !project.saveLocation.isEmpty else { return false }
        guard (project.leftEar.isEmpty || FileManager.default.fileExists(atPath: project.leftEar)), (project.rightEar.isEmpty || FileManager.default.fileExists(atPath: project.rightEar)) else { return false }
        switch stage {
        case .inference:
            return project.settings.inference.usePredictionsForPreprocessing && !project.leftEar.isEmpty && !project.rightEar.isEmpty && FileManager.default.fileExists(atPath: project.settings.inference.modelConfig) && FileManager.default.fileExists(atPath: project.settings.inference.modelCheckpoint)
        case .preprocessing:
            guard !stageBlocked(stage), FileManager.default.fileExists(atPath: environment.meshGradingExecutable), FileManager.default.fileExists(atPath: environment.externalDir + "/src/Mesh2HRTF/mesh2hrtf"), !isPlacingMicrophone else { return false }
            return true
        case .numcalc:
            return ArtifactScanner.stageIsComplete(.preprocessing, project: project) && FileManager.default.fileExists(atPath: environment.numcalcExecutable)
        case .postprocessing:
            return ArtifactScanner.stageIsComplete(.numcalc, project: project)
        }
    }

    func run(stage: Stage) {
        guard let project = selectedProject else {
            appendLog("Create or select a project before running.")
            return
        }
        guard runningProcesses[project.id] == nil else {
            appendLog("A task is already running.")
            return
        }
        guard !stageBlocked(stage) else {
            appendLog("Run Mesh2PPM Inference first.")
            return
        }
        if stage == .preprocessing, isPlacingMicrophone {
            appendLog("Finish microphone placement first.")
            return
        }
        guard (!project.leftEar.isEmpty || !project.rightEar.isEmpty), !project.saveLocation.isEmpty else {
            appendLog("Select an ear mesh and save location first.")
            return
        }
        do {
            try prepareRuntimeProject()
            let configURL = try PipelineConfigWriter.prepare(project: project, environment: environment)
            startProcess(stage: stage, project: project, configURL: configURL)
        } catch {
            failedStagesByProject[project.id, default: []].insert(stage)
            refreshArtifacts()
            appendLog("Could not prepare project: \(error.localizedDescription)")
        }
    }

    func startProcess(stage: Stage, project: ProjectRecord, configURL: URL) {
        let process = Process()
        if Defaults.isPackagedApp {
            process.executableURL = runtimePythonURL
            process.arguments = ["-m", "HRTFCalculation", stage.rawValue, "--config", configURL.path]
        } else {
            let bundledUV = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
            process.executableURL = bundledUV ? URL(fileURLWithPath: environment.uvExecutable) : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = bundledUV ? ["run", "--no-sync", "Pinna2HRTF", stage.rawValue, "--config", configURL.path] : ["uv", "run", "--no-sync", "Pinna2HRTF", stage.rawValue, "--config", configURL.path]
        }
        process.currentDirectoryURL = executionPackageURL
        process.environment = processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        runningProcesses[project.id] = process
        runningStages[project.id] = stage
        failedStagesByProject[project.id, default: []].remove(stage)
        refreshArtifacts()
        appendLog("\(stage.title) started.")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let store = self else { return }
            Task { @MainActor in store.appendLog(text.trimmingCharacters(in: .newlines), for: project.id) }
        }
        process.terminationHandler = { [weak self] process in
            guard let store = self else { return }
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus != 0 {
                    store.failedStagesByProject[project.id, default: []].insert(stage)
                }
                if process.terminationStatus == 0 {
                    store.notifyStageCompletion(stage, project: project)
                } else {
                    store.notifyStageFailure(stage, project: project, status: process.terminationStatus)
                }
                store.appendLog(process.terminationStatus == 0 ? "\(stage.title) finished." : "\(stage.title) failed (status \(process.terminationStatus)).", for: project.id)
                store.runningProcesses[project.id] = nil
                store.runningStages[project.id] = nil
                if stage == .inference, process.terminationStatus == 0 {
                    store.clearStaleMicrophonePositions(for: project.id)
                }
                store.refreshArtifacts()
            }
        }
        do {
            try process.run()
        } catch {
            failedStagesByProject[project.id, default: []].insert(stage)
            runningProcesses[project.id] = nil
            runningStages[project.id] = nil
            refreshArtifacts()
            appendLog("Could not start \(stage.title): \(error.localizedDescription)", for: project.id)
        }
    }

    func clearStaleMicrophonePositions(for projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var changed = false
        for side in EarSide.allCases {
            guard ArtifactScanner.manualMicrophonePosition(for: projects[index], side: side) != nil, ArtifactScanner.validManualMicrophonePosition(for: projects[index], side: side) == nil else { continue }
            if side == .left {
                projects[index].settings.preprocessing.sourcePositionInputLeft = nil
            } else {
                projects[index].settings.preprocessing.sourcePositionInputRight = nil
            }
            changed = true
        }
        if changed {
            persist()
            appendLog("Previous mic positions cleared.", for: projectID)
        }
    }

    func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            Task { @MainActor in
                if error != nil {
                    self.appendLog("Primary desktop notifications unavailable; stage completions will use the macOS fallback.")
                } else if !granted {
                    self.appendLog("Desktop notifications are disabled in macOS settings.")
                }
            }
        }
    }

    func notifyStageCompletion(_ stage: Stage, project: ProjectRecord) {
        sendNotification(title: "\(stage.title) complete", body: "\(project.name): \(stage.title) finished successfully.")
    }

    func notifyStageFailure(_ stage: Stage, project: ProjectRecord, status: Int32) {
        sendNotification(title: "\(stage.title) failed", body: "\(project.name): \(stage.title) exited with status \(status).")
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let identifier = "Pinna2HRTF-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.appendLog("Primary completion notification failed; using the macOS fallback.")
                    self?.sendFallbackNotification(title: title, body: body)
                }
            }
        }
    }

    func sendFallbackNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(appleScriptString(body)) with title \(appleScriptString(title))"]
        try? process.run()
    }

    func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func setupEnvironment() {
        guard environmentProcess == nil else {
            appendLog("Environment setup is already running.")
            return
        }
        do {
            try prepareRuntimeProject()
        } catch {
            appendLog("Could not prepare runtime folder: \(error.localizedDescription)")
            return
        }
        if !Defaults.isPackagedApp {
            copyPathToolsIntoEnvironment()
        }
        let logProjectID = selectedProjectID
        let process = Process()
        let bundledUV = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
        guard bundledUV || Defaults.which("uv") != nil else {
            appendLog("UV is missing. Install uv for development or use the self-contained release app.")
            return
        }
        process.executableURL = bundledUV ? URL(fileURLWithPath: environment.uvExecutable) : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = bundledUV ? ["sync"] : ["uv", "sync"]
        process.currentDirectoryURL = executionPackageURL
        process.environment = processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        environmentProcess = process
        appendLog("Environment setup started.")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let store = self else { return }
            Task { @MainActor in store.appendLog(text.trimmingCharacters(in: .newlines), for: logProjectID) }
        }
        process.terminationHandler = { [weak self] process in
            guard let store = self else { return }
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                store.appendLog(process.terminationStatus == 0 ? "Environment setup finished." : "Environment setup failed (status \(process.terminationStatus)).", for: logProjectID)
                store.environmentProcess = nil
                store.refreshArtifacts()
            }
        }
        do {
            try process.run()
        } catch {
            environmentProcess = nil
            appendLog("Could not start environment setup: \(error.localizedDescription)")
        }
    }

    func processEnvironment() -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["PINNA2HRTF_ROOT"] = rootURL.path
        values["MPLCONFIGDIR"] = Defaults.appDataURL.appendingPathComponent("Cache/matplotlib").path
        values["PYTHONPYCACHEPREFIX"] = Defaults.appDataURL.appendingPathComponent("Cache/python").path
        values["PYTHONNOUSERSITE"] = "1"
        values["BLENDER_USER_CONFIG"] = Defaults.appDataURL.appendingPathComponent("Blender/config").path
        values["BLENDER_USER_SCRIPTS"] = Defaults.appDataURL.appendingPathComponent("Blender/scripts").path
        values["BLENDER_USER_DATAFILES"] = Defaults.appDataURL.appendingPathComponent("Blender/datafiles").path
        if !Defaults.isPackagedApp {
            values["UV_CACHE_DIR"] = Defaults.appDataURL.appendingPathComponent("Cache/uv").path
        }
        values["PYTHONPATH"] = executionPackageURL.path
        values["PATH"] = URL(fileURLWithPath: environment.externalDir).appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (values["PATH"] ?? "")
        return values
    }

    var executionPackageURL: URL {
        packageURL
    }

    var runtimePythonURL: URL {
        packageURL.appendingPathComponent(".venv/bin/python")
    }

    func prepareRuntimeProject() throws {
        guard Defaults.isPackagedApp else { return }
        for directory in ["Cache/matplotlib", "Cache/python", "Blender/config", "Blender/scripts", "Blender/datafiles"] {
            try FileManager.default.createDirectory(at: Defaults.appDataURL.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
        if !runtimeProjectIsReady {
            throw NSError(domain: "Pinna2HRTF", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled Python runtime is missing or incomplete."])
        }
    }

    var runtimeProjectIsReady: Bool {
        FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("HRTFCalculation/RunConfig.py").path) &&
        FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("HRTFCalculation/__main__.py").path) &&
        FileManager.default.isExecutableFile(atPath: runtimePythonURL.path)
    }

    func copyPathToolsIntoEnvironment() {
        let bin = URL(fileURLWithPath: environment.externalDir).appendingPathComponent("bin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        } catch {
            appendLog("Could not prepare dependency folder \(bin.path): \(error.localizedDescription)")
            return
        }
        let tools = [
            ("uv", \EnvironmentConfig.uvExecutable),
            ("NumCalc", \EnvironmentConfig.numcalcExecutable),
            ("hrtf_mesh_grading", \EnvironmentConfig.meshGradingExecutable)
        ]
        for tool in tools {
            let current = environment[keyPath: tool.1]
            if FileManager.default.isExecutableFile(atPath: current) {
                continue
            }
            guard let source = Defaults.which(tool.0) else {
                appendLog("\(tool.0) is missing from the app bundle and PATH.")
                continue
            }
            let target = bin.appendingPathComponent(tool.0)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                updateEnvironment {
                    switch tool.0 {
                    case "uv": $0.uvExecutable = target.path
                    case "NumCalc": $0.numcalcExecutable = target.path
                    default: $0.meshGradingExecutable = target.path
                    }
                }
            } catch {
                appendLog("Could not copy \(tool.0) into the app dependencies: \(error.localizedDescription)")
            }
        }
    }

    func stopRunningProcess() {
        guard let project = selectedProject else { return }
        runningProcesses[project.id]?.terminate()
        appendLog("Stopping task.")
    }

    func resetSelectedProjectOutputs() {
        guard let project = selectedProject else { return }
        guard runningProcesses[project.id] == nil else {
            appendLog("Stop the running pipeline before resetting outputs.")
            return
        }
        let output = URL(fileURLWithPath: project.saveLocation)
        let names = [
            project.settings.inference.targetLeftFolder,
            project.settings.inference.targetRightFolder,
            project.settings.inference.predictionLeftFolder,
            project.settings.inference.predictionRightFolder,
            "Prediction Parameters Left",
            "Prediction Parameters Right",
            "intermediates",
            "Target STL Left",
            "Target STL Right",
            "ICP STL Left",
            "ICP STL Right",
            "Prediction STL Left",
            "Prediction STL Right",
            "Projects",
            "HRTF",
            "Results Inference.csv",
            ".pinna2hrtf_native_run.yaml"
        ]
        for name in names {
            let url = output.appendingPathComponent(name)
            if (!project.leftEar.isEmpty && path(url, contains: URL(fileURLWithPath: project.leftEar))) || (!project.rightEar.isEmpty && path(url, contains: URL(fileURLWithPath: project.rightEar))) {
                appendLog("Kept \(url.lastPathComponent): configured input mesh.")
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        failedStagesByProject[project.id] = []
        selectedMesh = nil
        selectedImage = nil
        selectedScene = SCNScene()
        refreshArtifacts()
        appendLog("Generated outputs reset.")
    }

    func loadSelectedProjectLog() {
        logText = selectedProjectID.flatMap { logTextByProject[$0] } ?? ""
    }

    func clearSelectedProjectLog() {
        guard let selectedProjectID else { return }
        logTextByProject[selectedProjectID] = ""
        logText = ""
    }

    func appendLog(_ text: String, for projectID: UUID? = nil) {
        let compactText = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { line in
            guard !line.isEmpty else { return false }
            let lower = line.lowercased()
            if lower.hasPrefix("info: total files") && lower.contains("failed 0") { return false }
            if lower.contains("error") || lower.contains("warning") || lower.contains("failed") || lower.contains("exception") || lower.contains("traceback") { return true }
            let redundantPrefixes = ["using config:", "left input mesh:", "right input mesh:", "running inference in ", "running preprocessing into ", "running local numcalc with ", "local numcalc project root:", "running postprocessing into ", "started left, step ", "started right, step "]
            return !redundantPrefixes.contains(where: { lower.hasPrefix($0) }) && !line.hasPrefix("/") && !(line.contains("Mem:") && line.contains("Time:")) && !line.hasPrefix("Fra:") && !lower.hasPrefix("blender ") && lower != "blender quit" && !lower.hasPrefix("read blend:") && !lower.hasPrefix("saved: '")
        }.joined(separator: "\n")
        guard !compactText.isEmpty else { return }
        guard let projectID = projectID ?? selectedProjectID else { return }
        let current = logTextByProject[projectID] ?? ""
        let updated = current.isEmpty ? compactText : "\(current)\n\(compactText)"
        logTextByProject[projectID] = updated
        if projectID == selectedProjectID {
            logText = updated
        }
    }

    static func migrated(_ registry: ProjectRegistry, rootURL: URL, packageURL: URL) -> ProjectRegistry {
        var next = registry
        let defaultEnvironment = Defaults.environment(root: rootURL)
        let replacements: [(String, String)] = [
            (packageURL.appendingPathComponent("External").path, rootURL.appendingPathComponent("External").path),
            (packageURL.appendingPathComponent("Paper").path, rootURL.appendingPathComponent("Paper").path),
            (packageURL.appendingPathComponent("Sources/HRTFCalculation").path, packageURL.appendingPathComponent("HRTFCalculation").path)
        ]
        next.environment.uvExecutable = migratedPath(next.environment.uvExecutable, replacements: replacements)
        next.environment.numcalcExecutable = migratedPath(next.environment.numcalcExecutable, replacements: replacements)
        next.environment.meshGradingExecutable = migratedPath(next.environment.meshGradingExecutable, replacements: replacements)
        next.environment.externalDir = migratedPath(next.environment.externalDir, replacements: replacements)
        if !FileManager.default.isExecutableFile(atPath: next.environment.uvExecutable) {
            next.environment.uvExecutable = defaultEnvironment.uvExecutable
        }
        if !FileManager.default.isExecutableFile(atPath: next.environment.numcalcExecutable) {
            next.environment.numcalcExecutable = defaultEnvironment.numcalcExecutable
        }
        if !FileManager.default.isExecutableFile(atPath: next.environment.meshGradingExecutable) {
            next.environment.meshGradingExecutable = defaultEnvironment.meshGradingExecutable
        }
        if !FileManager.default.fileExists(atPath: next.environment.externalDir) {
            next.environment.externalDir = defaultEnvironment.externalDir
        }
        next.projects = next.projects.map { project in
            var updated = project
            updated.leftEar = migratedPath(updated.leftEar, replacements: replacements)
            updated.rightEar = migratedPath(updated.rightEar, replacements: replacements)
            updated.saveLocation = migratedPath(updated.saveLocation, replacements: replacements)
            let projectFolder = URL(fileURLWithPath: updated.saveLocation)
            let entries = try? FileManager.default.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: nil)
            let legacyIntermediates = entries?.first(where: { $0.lastPathComponent == "intermediates" })
            let currentIntermediates = entries?.first(where: { $0.lastPathComponent == "Intermediates" })
            if let legacyIntermediates, currentIntermediates == nil {
                let migrationPath = projectFolder.appendingPathComponent(".pinna2hrtf-intermediates-migration")
                try? FileManager.default.moveItem(at: legacyIntermediates, to: migrationPath)
                try? FileManager.default.moveItem(at: migrationPath, to: projectFolder.appendingPathComponent("Intermediates"))
            }
            updated.settings.inference.modelConfig = migratedPath(updated.settings.inference.modelConfig, replacements: replacements)
            updated.settings.inference.modelCheckpoint = migratedPath(updated.settings.inference.modelCheckpoint, replacements: replacements)
            if updated.settings.inference.targetLeftFolder == "Target STL Left" { updated.settings.inference.targetLeftFolder = "Input/Left" }
            if updated.settings.inference.targetRightFolder == "Target STL Right" { updated.settings.inference.targetRightFolder = "Input/Right" }
            if updated.settings.inference.predictionLeftFolder == "Prediction STL Left" { updated.settings.inference.predictionLeftFolder = "Intermediates/Prediction STL Left" }
            if updated.settings.inference.predictionRightFolder == "Prediction STL Right" { updated.settings.inference.predictionRightFolder = "Intermediates/Prediction STL Right" }
            if updated.settings.inference.predictionLeftFolder == "Intermediates/Prediction STL Left" { updated.settings.inference.predictionLeftFolder = "Intermediates/Left" }
            if updated.settings.inference.predictionRightFolder == "Intermediates/Prediction STL Right" { updated.settings.inference.predictionRightFolder = "Intermediates/Right" }
            updated.settings.preprocessing.frequencyStepCount = "\(max(Int(updated.settings.preprocessing.frequencyStepCount) ?? 129, 2))"
            if Defaults.isPackagedApp {
                let resources = packageURL.appendingPathComponent("HRTFCalculation/Inference/resources", isDirectory: true)
                let bundledConfig = resources.appendingPathComponent(URL(fileURLWithPath: updated.settings.inference.modelConfig).lastPathComponent)
                let bundledCheckpoint = resources.appendingPathComponent(URL(fileURLWithPath: updated.settings.inference.modelCheckpoint).lastPathComponent)
                if (updated.settings.inference.modelConfig.contains("HRTFCalculation/Inference/resources/") || !FileManager.default.fileExists(atPath: updated.settings.inference.modelConfig)), FileManager.default.fileExists(atPath: bundledConfig.path) {
                    updated.settings.inference.modelConfig = bundledConfig.path
                }
                if (updated.settings.inference.modelCheckpoint.contains("HRTFCalculation/Inference/resources/") || !FileManager.default.fileExists(atPath: updated.settings.inference.modelCheckpoint)), FileManager.default.fileExists(atPath: bundledCheckpoint.path) {
                    updated.settings.inference.modelCheckpoint = bundledCheckpoint.path
                }
            }
            return updated
        }
        return next
    }

    static func migratedPath(_ path: String, replacements: [(String, String)]) -> String {
        var next = path
        for replacement in replacements {
            next = next.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
        return next
    }

    func path(_ parent: URL, contains child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
