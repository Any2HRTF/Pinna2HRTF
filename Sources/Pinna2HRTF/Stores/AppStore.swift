import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import AppKit

final class AppStore: ObservableObject {
    @Published var projects: [ProjectRecord]
    @Published var selectedProjectID: UUID?
    @Published var environment: EnvironmentConfig
    @Published var logText = ""
    @Published var selectedMesh: URL?
    @Published var selectedImage: NSImage?
    @Published var selectedScene = SCNScene()
    @Published var artifacts: [Artifact] = []
    @Published var stageStates: [Stage: StageState] = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, .ready) })
    @Published var runningProcesses: [UUID: Process] = [:]
    @Published var runningStages: [UUID: Stage] = [:]
    @Published var environmentProcess: Process?
    @Published var failedStagesByProject: [UUID: Set<Stage>] = [:]

    let rootURL: URL
    let packageURL: URL
    let registryStore: ProjectRegistryStore

    init() {
        rootURL = Defaults.runtimeRoot
        packageURL = Defaults.pipelineRoot
        registryStore = ProjectRegistryStore(rootURL: rootURL, packageURL: packageURL)
        var registry = AppStore.migrated(registryStore.load(), rootURL: rootURL, packageURL: packageURL)
        if Defaults.isPackagedApp {
            registry.environment = Defaults.environment(root: rootURL)
        }
        projects = registry.projects
        selectedProjectID = registry.selectedProjectID ?? registry.projects.first?.id
        environment = registry.environment
        registryStore.save(ProjectRegistry(projects: projects, selectedProjectID: selectedProjectID, environment: environment))
        refreshArtifacts()
    }

    var selectedProject: ProjectRecord? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedProjectIndex: Int? {
        projects.firstIndex { $0.id == selectedProjectID }
    }

    var inferenceResourceURL: URL {
        packageURL.appendingPathComponent("HRTFCalculation/Inference/resources")
    }

    var modelOptions: [String] {
        resourceOptions(extensions: ["yaml", "yml"]).map(Self.modelName).sorted()
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

    func forgetSelectedProject() {
        guard let selectedProjectID else { return }
        runningProcesses[selectedProjectID]?.terminate()
        runningProcesses[selectedProjectID] = nil
        runningStages[selectedProjectID] = nil
        failedStagesByProject[selectedProjectID] = nil
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

    func resetViewer() {
        selectedMesh = nil
        selectedImage = nil
        selectedScene = SCNScene()
    }

    func openArtifact(_ artifact: Artifact) {
        if artifact.isMesh {
            openMesh(artifact.url)
        } else if artifact.isImage {
            openImage(artifact.url)
        } else {
            appendLog("Cannot open artifact: \(artifact.url.path)")
        }
    }

    func openMesh(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), ["stl", "ply"].contains(url.pathExtension.lowercased()) else {
            appendLog("Cannot open mesh: \(url.path)")
            return
        }
        let asset = MDLAsset(url: url)
        let scene = SCNScene()
        for index in 0..<asset.count {
            let object = asset.object(at: index)
            let node = SCNNode(mdlObject: object)
            node.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.49, green: 0.65, blue: 0.64, alpha: 1)
            node.geometry?.firstMaterial?.roughness.contents = 0.72
            scene.rootNode.addChildNode(node)
        }
        let camera = SCNCamera()
        camera.zFar = 10_000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, -280, 120)
        cameraNode.eulerAngles = SCNVector3(Float.pi / 2.8, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
        let light = SCNLight()
        light.type = .omni
        light.intensity = 900
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(0, -180, 220)
        scene.rootNode.addChildNode(lightNode)
        selectedMesh = url
        selectedImage = nil
        selectedScene = scene
        appendLog("Opened \(url.path)")
    }

    func openImage(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else {
            appendLog("Cannot open image: \(url.path)")
            return
        }
        selectedMesh = url
        selectedImage = image
        selectedScene = SCNScene()
        appendLog("Opened \(url.path)")
    }

    func runNextStage() {
        guard let project = selectedProject else {
            appendLog("Create or select a project before running.")
            return
        }
        let stage = Stage.allCases.first { !ArtifactScanner.stageIsComplete($0, project: project) } ?? .postprocessing
        run(stage: stage)
    }

    func run(stage: Stage) {
        guard let project = selectedProject else {
            appendLog("Create or select a project before running.")
            return
        }
        guard runningProcesses[project.id] == nil else {
            appendLog("\(project.name) already has a running task.")
            return
        }
        guard !project.leftEar.isEmpty, !project.rightEar.isEmpty, !project.saveLocation.isEmpty else {
            appendLog("Select a left ear mesh, right ear mesh, and save location before running.")
            return
        }
        do {
            try prepareRuntimeProject()
            if Defaults.isPackagedApp && !FileManager.default.fileExists(atPath: runtimePythonURL.path) {
                appendLog("Python runtime is missing from the app bundle.")
                return
            }
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
            process.arguments = ["-m", "HRTFCalculation.RunConfig", "--config", configURL.path, "--stage", stage.rawValue]
        } else {
            let bundledUV = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
            process.executableURL = bundledUV ? URL(fileURLWithPath: environment.uvExecutable) : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = bundledUV ? ["run", "--no-sync", "python", "-m", "HRTFCalculation.RunConfig", "--config", configURL.path, "--stage", stage.rawValue] : ["uv", "run", "--no-sync", "python", "-m", "HRTFCalculation.RunConfig", "--config", configURL.path, "--stage", stage.rawValue]
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
        appendLog("Started \(stage.title) for \(project.name)")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let store = self else { return }
            Task { @MainActor in store.appendLog(text.trimmingCharacters(in: .newlines)) }
        }
        process.terminationHandler = { [weak self] process in
            guard let store = self else { return }
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus != 0 {
                    store.failedStagesByProject[project.id, default: []].insert(stage)
                }
                store.appendLog(process.terminationStatus == 0 ? "\(stage.title) finished for \(project.name)" : "\(stage.title) for \(project.name) exited with status \(process.terminationStatus)")
                store.runningProcesses[project.id] = nil
                store.runningStages[project.id] = nil
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
            appendLog("Could not start \(stage.title): \(error.localizedDescription)")
        }
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
        let process = Process()
        let bundledUV = FileManager.default.isExecutableFile(atPath: environment.uvExecutable)
        guard bundledUV || Defaults.which("uv") != nil else {
            appendLog("UV is missing. Install uv or use a release app that bundles it, then run Set Up again.")
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
        appendLog("Setting up Python environment")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let store = self else { return }
            Task { @MainActor in store.appendLog(text.trimmingCharacters(in: .newlines)) }
        }
        process.terminationHandler = { [weak self] process in
            guard let store = self else { return }
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                store.appendLog(process.terminationStatus == 0 ? "Environment setup finished" : "Environment setup exited with status \(process.terminationStatus)")
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
        values["UV_CACHE_DIR"] = Defaults.appDataURL.appendingPathComponent("Cache/uv").path
        values["MPLCONFIGDIR"] = Defaults.appDataURL.appendingPathComponent("Cache/matplotlib").path
        values["PYTHONPATH"] = executionPackageURL.path
        values["PATH"] = URL(fileURLWithPath: environment.externalDir).appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (values["PATH"] ?? "")
        return values
    }

    var executionPackageURL: URL {
        Defaults.isPackagedApp ? Defaults.runtimeProjectURL : packageURL
    }

    var runtimePythonURL: URL {
        Defaults.runtimeProjectURL.appendingPathComponent(".venv/bin/python")
    }

    func prepareRuntimeProject() throws {
        guard Defaults.isPackagedApp else { return }
        let runtime = Defaults.runtimeProjectURL
        if !runningProcesses.isEmpty || environmentProcess != nil {
            if runtimeProjectIsReady {
                return
            }
            throw NSError(domain: "Pinna2HRTF", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled runtime is not ready. Wait for the running task to finish, then start again."])
        }
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let entries = ["HRTFCalculation", "pyproject.toml", "uv.lock", ".venv", "Python"]
        for entry in entries {
            let source = packageURL.appendingPathComponent(entry)
            let target = runtime.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    var runtimeProjectIsReady: Bool {
        FileManager.default.fileExists(atPath: Defaults.runtimeProjectURL.appendingPathComponent("HRTFCalculation/RunConfig.py").path) &&
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
                appendLog("Copied \(tool.0) into \(target.path)")
            } catch {
                appendLog("Could not copy \(tool.0) into the app dependencies: \(error.localizedDescription)")
            }
        }
    }

    func stopRunningProcess() {
        guard let project = selectedProject else { return }
        runningProcesses[project.id]?.terminate()
        appendLog("Termination requested.")
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
            "Projects",
            "HRTF",
            "Results Inference.csv",
            ".pinna2hrtf_native_run.yaml"
        ]
        for name in names {
            let url = output.appendingPathComponent(name)
            if path(url, contains: URL(fileURLWithPath: project.leftEar)) || path(url, contains: URL(fileURLWithPath: project.rightEar)) {
                appendLog("Skipped reset of \(url.path) because it contains a configured input mesh.")
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
        appendLog("Reset generated outputs in \(output.path)")
    }

    func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        logText += logText.isEmpty ? text : "\n\(text)"
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
            updated.settings.inference.modelConfig = migratedPath(updated.settings.inference.modelConfig, replacements: replacements)
            updated.settings.inference.modelCheckpoint = migratedPath(updated.settings.inference.modelCheckpoint, replacements: replacements)
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
