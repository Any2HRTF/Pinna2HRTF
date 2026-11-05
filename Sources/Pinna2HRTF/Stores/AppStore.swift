import Foundation
import Combine
import SceneKit
import AppKit

/// Coordinates the app's focused stores and is the single object the views observe.
///
/// - `ProjectLibrary`: projects, folders, selection, persistence, import/duplicate/remove
/// - `PipelineRunner`: stage runs, environment setup, output tracking, stop, notifications
/// - `ProjectStatusController`: file inspection, artifacts, stage states
/// - `ViewerModel`: scene, camera, microphone placement
/// - `ActivityLog`: activity messages and technical log locations
/// - `ProcessLauncher.shared`: every subprocess
///
/// Cross-store flows (running a stage, editors, resetting outputs, removing a project)
/// live here; everything else is forwarded so views keep using `store.…`.
@MainActor
final class AppStore: ObservableObject {
    let library = ProjectLibrary()
    let runner = PipelineRunner()
    let status = ProjectStatusController()
    let viewer = ViewerModel()
    let activity = ActivityLog()
    private var subscriptions = Set<AnyCancellable>()
    private var projectsChangePending = false

    @Published var workflowStep: WorkflowStep = .inputs
    @Published var workflowRevealRequest = UUID()
    @Published var meshEditorRequest: MeshEditorRequest?
    @Published var meshEditorError: String?
    @Published var ppmFittingRequest: PPMFittingRequest?
    @Published var ppmFittingError: String?
    @Published var projectDuplicationRequest: ProjectDuplicationRequest?

    @Published var earDistanceFocusRequest: UUID?
    @Published var geometryValues: GeometryValues?
    @Published var geometryMessage = "Load an ear mesh to calculate geometry."
    @Published var geometryEditing = false
    var geometryCache: [String: GeometryValues] = [:]
    var geometryRequests = Set<String>()
    var geometryKey = ""

    init() {
        library.store = self
        runner.store = self
        status.store = self
        viewer.store = self
        for publisher in [library.objectWillChange, runner.objectWillChange, status.objectWillChange,
                          viewer.objectWillChange, activity.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        activity.discoverExistingLogs(for: library.projects)
        activity.select(library.selectedProject)
        status.refreshSummaries(for: library.projects)
        refreshArtifacts(restoringViewer: true)
    }

    // MARK: Change propagation

    /// Called for every change to `projects`; summaries and file checks run once per batch.
    func projectsDidChange() {
        guard !projectsChangePending else { return }
        projectsChangePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.projectsChangePending = false
            self.status.refreshSummaries(for: self.projects)
            self.refreshArtifacts()
        }
    }

    /// Side effects of choosing another project.
    func selectionDidChange() {
        library.persist()
        activity.select(selectedProject)
        refreshArtifacts(restoringViewer: true)
    }

    func refreshArtifacts(restoringViewer: Bool = false) {
        status.refresh(restoringViewer: restoringViewer)
    }

    // MARK: Forwarded state

    var projects: [ProjectRecord] {
        get { library.projects }
        set { library.projects = newValue }
    }
    var folders: [ProjectFolder] {
        get { library.folders }
        set { library.folders = newValue }
    }
    var selectedProjectID: UUID? {
        get { library.selectedProjectID }
        set { library.selectedProjectID = newValue }
    }
    var environment: EnvironmentConfig { library.environment }
    var persistenceMessage: String? {
        get { library.persistenceMessage }
        set { library.persistenceMessage = newValue }
    }
    var registryRecoveryPresented: Bool {
        get { library.registryRecoveryPresented }
        set { library.registryRecoveryPresented = newValue }
    }
    var projectRevealToken: UUID { library.projectRevealToken }
    var registryStore: ProjectRegistryStore { library.registryStore }
    var rootURL: URL { library.rootURL }
    var packageURL: URL { library.packageURL }

    var projectSummaries: [UUID: String] { status.projectSummaries }
    var artifacts: [Artifact] { status.artifacts }
    var isCheckingProjectFiles: Bool { status.isCheckingProjectFiles }
    var stageStates: [Stage: StageState] { status.stageStates }
    var selectedProjectStatus: ProjectStatusSnapshot? { status.status(for: selectedProject, environment: environment) }
    var selectedValidationIssues: [(id: String, message: String)] { selectedProjectStatus?.issues ?? [] }

    var runningProcesses: [UUID: Process] { runner.runningProcesses }
    var runningStages: [UUID: Stage] { runner.runningStages }
    var environmentProcess: Process? { runner.environmentProcess }
    var hasOutputOperations: Bool { runner.hasOutputOperations }

    var logText: String { activity.text }
    var liveLogStatusByProject: [UUID: String] { activity.liveStatusByProject }
    var selectedTechnicalLogURL: URL? { activity.selectedTechnicalLogURL }

    var selectedPressure: URL? { viewer.selectedPressure }
    var selectedMesh: URL? { viewer.selectedMesh }
    var selectedImage: NSImage? { viewer.selectedImage }
    var selectedScene: SCNScene { viewer.selectedScene }
    var microphonePlacementSide: EarSide? { viewer.microphonePlacementSide }
    var pendingMicrophonePosition: ManualMicrophonePosition? { viewer.pendingMicrophonePosition }
    var microphonePlacementError: String? {
        get { viewer.microphonePlacementError }
        set { viewer.microphonePlacementError = newValue }
    }
    var isPlacingMicrophone: Bool { viewer.isPlacingMicrophone }
    var isCalculatingAutomaticMicrophone: Bool { viewer.isCalculatingAutomaticMicrophone }

    // MARK: Forwarded actions

    func persist() { library.persist() }
    func recoverProjectRegistry() { library.recoverProjectRegistry() }
    @discardableResult func createFolder(named name: String) -> UUID { library.createFolder(named: name) }
    func renameFolder(_ id: UUID, to name: String) { library.renameFolder(id, to: name) }
    func removeFolder(_ id: UUID) { library.removeFolder(id) }
    func moveProject(_ id: UUID, toFolder folderID: UUID?, before destinationID: UUID? = nil) {
        library.moveProject(id, toFolder: folderID, before: destinationID)
    }
    func revealSelectedProject() { library.revealSelectedProject() }

    func openArtifact(_ artifact: Artifact) { viewer.openArtifact(artifact) }
    func resetSelectedMeshView() { viewer.resetSelectedMeshView() }
    func updateSceneBackground(darkMode: Bool) { viewer.updateSceneBackground(darkMode: darkMode) }
    func updateCameraPosition(_ position: SCNVector3, target: SCNVector3, orientation: SCNQuaternion) {
        viewer.updateCameraPosition(position, target: target, orientation: orientation)
    }
    func beginMicrophonePlacement(_ side: EarSide) { viewer.beginMicrophonePlacement(side) }
    func previewMicrophonePosition(_ position: SCNVector3) { viewer.previewMicrophonePosition(position) }
    func completeMicrophonePlacement() { viewer.completeMicrophonePlacement() }
    func cancelMicrophonePlacement() { viewer.cancelMicrophonePlacement() }
    func useAutomaticMicrophonePosition(_ side: EarSide) { viewer.useAutomaticMicrophonePosition(side) }

    func setupEnvironment() { runner.setupEnvironment() }
    func cancelEnvironmentSetup() { runner.cancelEnvironmentSetup() }
    func stopRunningProcess() { if let id = selectedProjectID { runner.stop(id) } }
    func stopAllRunningProcesses(completion: @escaping @MainActor () -> Void) { runner.stopAll(completion: completion) }

    func appendLog(_ text: String, for projectID: UUID? = nil) { activity.append(text, for: projectID) }
    func clearSelectedProjectLog() { activity.clearSelected() }
    func openTechnicalLog() {
        guard let url = selectedTechnicalLogURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Saves pending changes and stops every subprocess tree; called when the app quits.
    func prepareForTermination() {
        library.flushPersistence()
        ProcessLauncher.shared.terminateAll()
    }

    // MARK: Selection

    var selectedProject: ProjectRecord? { library.selectedProject }
    var selectedProjectIndex: Int? { library.selectedProjectIndex }

    var selectedProjectIsRunning: Bool {
        guard let id = selectedProjectID else { return false }
        return runner.isBusy(id)
            || meshEditorRequest?.projectID == id
            || ppmFittingRequest?.projectID == id
            || library.projectsBeingRemoved.contains(id)
    }

    var selectedProjectIsManagingOutputs: Bool {
        selectedProjectID.map(runner.isManagingOutputs) ?? false
    }

    var inferenceResourceURL: URL {
        packageURL.appendingPathComponent("HRTFCalculation/Inference/resources")
    }

    var modelOptions: [String] {
        let available = Set(resourceOptions(extensions: ["yaml", "yml"]).map(Self.modelName))
        return ["1 Views", "3 Views", "9 Views", "25 Views"].filter { available.contains($0) }
    }

    // MARK: Project edits

    func setStageOutcome(_ stage: Stage, for id: UUID, to outcome: StageState) {
        setStageOutcomes([stage], for: id, to: outcome)
    }

    /// Applies several outcomes as one change.
    func setStageOutcomes(_ stages: [Stage], for id: UUID, to outcome: StageState) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        var outcomes = project.stageOutcomes ?? [:]
        var failed = runner.failedStagesByProject[id, default: []]
        for stage in stages {
            outcomes[stage.rawValue] = outcome
            if outcome == .failed { failed.insert(stage) } else { failed.remove(stage) }
        }
        project.stageOutcomes = outcomes
        library.projects[index] = project
        runner.failedStagesByProject[id] = failed
        persist()
    }

    /// Changes a project regardless of selection and saves.
    func mutateProject(_ id: UUID, _ update: (inout ProjectRecord) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        update(&project)
        library.projects[index] = project
        persist()
    }

    func updateSelectedProject(_ update: (inout ProjectRecord) -> Void) {
        guard let index = selectedProjectIndex, !selectedProjectIsRunning else { return }
        var project = projects[index]
        update(&project)
        guard project != projects[index] else { return }
        library.projects[index] = project
        persist()
    }

    func updateEnvironment(_ update: (inout EnvironmentConfig) -> Void) {
        update(&library.environment)
        persist()
        refreshArtifacts()
    }

    func setBezierPPM(_ enabled: Bool) {
        updateSelectedProject {
            $0.settings.inference.usePredictionsForPreprocessing = enabled
            if enabled { $0.settings.manualPPMFitting.useForPreprocessing = false }
        }
    }

    func setManualPPMFitting(_ enabled: Bool) {
        updateSelectedProject {
            $0.settings.manualPPMFitting.useForPreprocessing = enabled
            if enabled { $0.settings.inference.usePredictionsForPreprocessing = false }
        }
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
        updateSelectedProject {
            $0.settings.inference.modelConfig = config
            $0.settings.inference.modelCheckpoint = checkpoint
        }
    }

    nonisolated static func modelName(_ path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return stem.hasPrefix("Local ") ? String(stem.dropFirst("Local ".count)) : stem
    }

    func clearStaleMicrophonePositions(for projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        var updated = project
        for side in EarSide.allCases {
            guard ArtifactScanner.manualMicrophonePosition(for: project, side: side) != nil,
                  ArtifactScanner.validManualMicrophonePosition(for: project, side: side) == nil else { continue }
            if side == .left {
                updated.settings.preprocessing.sourcePositionInputLeft = nil
            } else {
                updated.settings.preprocessing.sourcePositionInputRight = nil
            }
        }
        if updated != project {
            mutateProject(projectID) { $0 = updated }
            appendLog("Previous microphone positions cleared.", for: projectID)
        }
    }

    // MARK: Adding projects

    func createProject() {
        let project = library.newProject()
        runner.failedStagesByProject[project.id] = []
        library.add(project)
    }

    func duplicateSelectedProject() {
        guard let project = selectedProject, !selectedProjectIsRunning,
              meshEditorRequest == nil, ppmFittingRequest == nil,
              projectDuplicationRequest == nil else { return }
        projectDuplicationRequest = library.duplicateSuggestion(for: project)
    }

    func duplicateProject(_ request: ProjectDuplicationRequest, name: String, parentFolder: String) async throws {
        let duplicate = try await library.duplicate(request, name: name, parentFolder: parentFolder)
        runner.failedStagesByProject[duplicate.id] = []
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
        if showExistingProject(at: folder) { return }
        let index = projects.count + 1
        let root = packageURL
        Task { @MainActor in
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ProjectLibrary.importedRecord(from: folder, index: index, packageRoot: root)
                }.value
                // Another import of the same folder may have finished meanwhile.
                if showExistingProject(at: folder) { return }
                runner.failedStagesByProject[imported.project.id] = []
                library.add(imported.project)
                appendLog("Imported. Checking project files…")
                if let note = imported.note { appendLog(note) }
            } catch {
                library.persistenceMessage = "Project import failed. Files were kept unchanged. \(error.localizedDescription)"
            }
        }
    }

    private func showExistingProject(at folder: URL) -> Bool {
        guard let existing = library.existingProject(at: folder) else { return false }
        selectedProjectID = existing.id
        revealSelectedProject()
        appendLog("This project is already in the list.")
        return true
    }

    // MARK: Removing projects

    func canRemoveProject(_ id: UUID) -> Bool {
        projects.contains { $0.id == id }
            && !runner.isBusy(id)
            && meshEditorRequest?.projectID != id
            && ppmFittingRequest?.projectID != id
            && !library.projectsBeingRemoved.contains(id)
    }
    var canRemoveSelectedProject: Bool { selectedProjectID.map(canRemoveProject) ?? false }

    func removeSelectedProject() {
        guard let project = selectedProject else { return }
        let projectID = project.id
        guard canRemoveProject(projectID) else {
            appendLog("Close the ear editor or wait for running tasks and output checks before removing this project.")
            return
        }

        switch library.removalPlan(for: project) {
        case .listOnly(let reason):
            let alert = NSAlert()
            alert.messageText = "Remove \(project.name) from the list?"
            alert.informativeText = reason ?? "The project has no folder on disk. It will be removed from the list."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Remove from List")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            finishRemovingProject(projectID)
        case .trash(let projectFolder):
            let alert = NSAlert()
            alert.messageText = "Move \(project.name) to Trash?"
            alert.informativeText = "The project folder and its contents will move to Trash, and the project will be removed from the list."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            library.beginRemoving(projectID)
            NSWorkspace.shared.recycle([projectFolder]) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.library.endRemoving(projectID)
                    if let error {
                        self.showProjectRemovalError("The project folder could not be moved to Trash. The project remains in the app. \(error.localizedDescription)")
                        return
                    }
                    self.finishRemovingProject(projectID)
                }
            }
        }
    }

    private func finishRemovingProject(_ id: UUID) {
        runner.forget(id)
        activity.forget(id)
        viewer.forget(id)
        library.removeRecord(id)
    }

    private func showProjectRemovalError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not move project to Trash"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Editors

    func beginScanAlignment() {
        guard let project = selectedProject, !selectedProjectIsRunning else { return }
        let source = project.scanPreparation.originalScanPath ?? project.scanPreparation.scanPath
        guard !source.isEmpty, FileManager.default.fileExists(atPath: source) else {
            meshEditorError = "Choose a full-head scan first."; return
        }
        if let conflict = outputLocationConflict(for: project) {
            meshEditorError = conflict; return
        }
        let url = URL(fileURLWithPath: source)
        meshEditorRequest = MeshEditorRequest(projectID: project.id, source: url, originalSource: url,
            destination: URL(fileURLWithPath: project.saveLocation).appendingPathComponent("MeshEdits/AlignedScan.ply"),
            side: nil, preparedGeneration: nil, preparedReport: nil,
            prepareLeft: project.scanPreparation.prepareLeft, prepareRight: project.scanPreparation.prepareRight)
    }

    func beginEarEditing(_ side: EarSide) {
        guard let project = selectedProject, !selectedProjectIsRunning else { return }
        guard !project.saveLocation.isEmpty else { meshEditorError = "Choose a save location first."; return }
        if let conflict = outputLocationConflict(for: project) { meshEditorError = conflict; return }
        if !project.scanPreparation.enabled {
            let path = side == .left ? project.leftEar : project.rightEar
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                meshEditorError = "Choose an existing ear mesh first."; return
            }
            let base = URL(fileURLWithPath: path)
            let source = ArtifactScanner.sourceEar(for: project, side: side) ?? base
            meshEditorRequest = MeshEditorRequest(projectID: project.id, source: source, originalSource: base,
                destination: URL(fileURLWithPath: project.saveLocation).appendingPathComponent("MeshEdits/Individual\(side.title).stl"),
                side: side, preparedGeneration: nil, preparedReport: nil)
            return
        }
        guard ArtifactScanner.scanPreparationIsCurrent(project) else {
            meshEditorError = "Run Scan Preparation successfully first."; return
        }
        let root = URL(fileURLWithPath: project.saveLocation)
        let reportURL = root.appendingPathComponent("Prepared/mesh_preparation.json")
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generation = report["generation"] as? String else {
            meshEditorError = "The scan preparation report is missing."; return
        }
        let base = root.appendingPathComponent("Prepared/\(side.title).stl")
        let reviewed = project.scanPreparation.earEdit(side)
        let source = ArtifactScanner.earReviewIsCurrent(project, side: side) ? reviewed.map { URL(fileURLWithPath: $0) } ?? base : base
        meshEditorRequest = MeshEditorRequest(projectID: project.id, source: source, originalSource: base,
            destination: root.appendingPathComponent("MeshEdits/\(side.title).stl"), side: side,
            preparedGeneration: generation, preparedReport: reportURL)
    }

    func beginManualPPMFitting(_ side: EarSide) {
        guard let project = selectedProject, !selectedProjectIsRunning else { return }
        guard !project.saveLocation.isEmpty else {
            ppmFittingError = "Choose a project save location first."; return
        }
        if project.scanPreparation.enabled && !ArtifactScanner.scanPreparationIsCurrent(project) {
            ppmFittingError = "Run Scan Preparation successfully with the current scan settings first."; return
        }
        guard let target = ArtifactScanner.sourceEar(for: project, side: side),
              FileManager.default.fileExists(atPath: target.path),
              let identity = ArtifactScanner.meshIdentity(target) else {
            ppmFittingError = "Choose or prepare a valid \(side.rawValue) ear mesh first."; return
        }
        guard ["stl", "ply"].contains(target.pathExtension.lowercased()) else {
            ppmFittingError = "Manual PPM fitting requires an STL or PLY ear mesh."; return
        }
        if let conflict = outputLocationConflict(for: project) {
            ppmFittingError = conflict; return
        }
        let folder = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Manual PPM", isDirectory: true)
        let desktopBlend = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/PPM.blend")
        let current = project.settings.manualPPMFitting
        let savedParameters = current.parametersPath(for: side).map { URL(fileURLWithPath: $0) }
        let template = current.templateBlendPath.map { URL(fileURLWithPath: $0) }
        let initialTemplate = template.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? (FileManager.default.fileExists(atPath: desktopBlend.path) ? desktopBlend : nil)
        ppmFittingRequest = PPMFittingRequest(
            projectID: project.id,
            side: side,
            targetMesh: target,
            sourceIdentity: identity,
            destinationMesh: folder.appendingPathComponent("\(side.title).stl"),
            destinationParameters: folder.appendingPathComponent("\(side.title).json"),
            destinationBlend: folder.appendingPathComponent("\(side.title).blend"),
            savedParameters: savedParameters.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            initialTemplateBlend: initialTemplate
        )
    }

    func finishManualPPMFitting(_ request: PPMFittingRequest, templateBlendPath: String) {
        guard let index = projects.firstIndex(where: { $0.id == request.projectID }) else { return }
        guard let source = ArtifactScanner.sourceEar(for: projects[index], side: request.side),
              ArtifactScanner.meshIdentity(source) == request.sourceIdentity else {
            ppmFittingError = "The source ear changed before the fit could be saved. Reopen the fitting workspace for the current mesh."; return
        }
        var project = projects[index]
        var fitting = project.settings.manualPPMFitting
        fitting.setFit(meshPath: request.destinationMesh.path,
                       parametersPath: request.destinationParameters.path,
                       blendPath: request.destinationBlend.path,
                       sourcePath: request.targetMesh.path,
                       sourceIdentity: request.sourceIdentity,
                       for: request.side)
        if !templateBlendPath.isEmpty { fitting.templateBlendPath = templateBlendPath }
        fitting.selectedMethod = .manual
        fitting.useForPreprocessing = true
        project.settings.manualPPMFitting = fitting
        project.settings.inference.usePredictionsForPreprocessing = false
        library.projects[index] = project
        runner.recordEditorOutputs(for: project, urls: [request.destinationMesh, request.destinationParameters,
            request.destinationBlend] + (templateBlendPath.isEmpty ? [] : [URL(fileURLWithPath: templateBlendPath)]))
        persist()
        appendLog("Saved the manual \(request.side.rawValue) PPM fit. Preprocessing will use it until the source ear changes.", for: request.projectID)
    }

    func finishEarSelection(_ request: MeshEditorRequest) {
        guard request.prepareLeft || request.prepareRight else { return }
        mutateProject(request.projectID) { project in
            var scan = project.scanPreparation
            scan.prepareLeft = request.prepareLeft
            scan.prepareRight = request.prepareRight
            project.settings.scanPreparation = scan
        }
    }

    func finishMeshEditing(_ request: MeshEditorRequest) {
        guard let index = projects.firstIndex(where: { $0.id == request.projectID }) else { return }
        var project = projects[index]
        var scan = project.scanPreparation
        if let side = request.side {
            scan.setEarEdit(request.destination.path, side: side)
        } else {
            scan.prepareLeft = request.prepareLeft
            scan.prepareRight = request.prepareRight
            scan.originalScanPath = request.originalSource.path
            scan.scanPath = request.destination.path
            scan.rotationDegrees = "0"
            scan.reviewedLeftPath = nil; scan.reviewedRightPath = nil
        }
        project.settings.scanPreparation = scan
        project.settings.preprocessing.sourcePositionInputLeft = nil
        project.settings.preprocessing.sourcePositionInputRight = nil
        runner.recordEditorOutputs(for: project, urls: [request.destination,
            request.destination.deletingPathExtension().appendingPathExtension("json")])
        library.projects[index] = project
        let resetStages = request.isAlignment ? Stage.allCases : Stage.allCases.filter { $0 != .scanPreparation }
        setStageOutcomes(resetStages, for: request.projectID, to: .ready)
        appendLog("Saved \(request.isAlignment ? "nose-and-ear-aligned scan" : "reviewed ear"): \(request.destination.lastPathComponent)", for: request.projectID)
        viewer.openMesh(request.destination, resetCamera: true)
    }

    // MARK: Running

    func runNextStage() {
        guard selectedProject != nil else {
            appendLog("Create or select a project before running.")
            return
        }
        run(stage: nextStage ?? .postprocessing)
    }

    var nextStage: Stage? {
        guard let project = selectedProject else { return nil }
        return Stage.allCases.filter { ($0 != .scanPreparation || project.scanPreparation.enabled) && ($0 != .inference || project.settings.inference.usePredictionsForPreprocessing) }.first {
            ($0 == .preprocessing && preprocessingNeedsRerun(for: project)) || [.failed, .stopped].contains(project.stageOutcomes?[$0.rawValue] ?? .ready) || !(selectedProjectStatus?.completed.contains($0) ?? false)
        }
    }

    func stageBlocked(_ stage: Stage) -> Bool {
        guard let project = selectedProject else { return false }
        return stage == .preprocessing && project.settings.inference.usePredictionsForPreprocessing && !(selectedProjectStatus?.completed.contains(.inference) ?? false)
    }

    func canRun(stage: Stage) -> Bool { runUnavailableReason(stage: stage) == nil }

    func runUnavailableReason(stage: Stage) -> String? {
        guard let project = selectedProject else { return "Select a project first." }
        if meshEditorRequest != nil || ppmFittingRequest != nil { return "Finish editing before running the pipeline." }
        if selectedProjectIsRunning { return runner.stoppingProjects.contains(project.id) ? "Waiting for the task to stop." : "Wait for the current task and output checks to finish." }
        if environmentProcess != nil { return "Wait for dependency setup to finish." }
        if stage == .preprocessing && isPlacingMicrophone { return "Finish microphone placement first." }
        guard let status = selectedProjectStatus, !isCheckingProjectFiles else { return "Checking project files…" }
        return status.unavailableReasons[stage]
    }

    func canRunNextStage() -> Bool {
        guard let project = selectedProject, runningProcesses[project.id] == nil else { return false }
        guard let next = nextStage else { return false }
        return canRun(stage: next)
    }

    func stageUnavailableReason(_ stage: Stage, project: ProjectRecord) -> String? {
        ProjectStatusSnapshot.unavailableReason(stage, project: project, environment: environment,
                                               projects: projects, placingMicrophone: isPlacingMicrophone)
    }

    func outputLocationConflict(for project: ProjectRecord) -> String? {
        ProjectStatusSnapshot.outputLocationConflict(for: project, projects: projects)
    }

    func preprocessingNeedsRerun(for project: ProjectRecord) -> Bool {
        selectedProjectStatus?.project == project && selectedProjectStatus?.preprocessingNeedsRerun == true
    }

    func run(stage: Stage) {
        guard let project = selectedProject else {
            appendLog("Create or select a project before running.")
            return
        }
        guard !runner.isBusy(project.id) else {
            appendLog("A task is already running.")
            return
        }
        guard environmentProcess == nil else {
            appendLog("Wait for dependency setup to finish.")
            return
        }
        if [.numcalc, .postprocessing].contains(stage), preprocessingNeedsRerun(for: project) {
            guard confirmRerunPreprocessing() else { return }
            run(stage: .preprocessing)
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
        guard (!project.pipelineLeftEar.isEmpty || !project.pipelineRightEar.isEmpty), !project.saveLocation.isEmpty else {
            appendLog("Select an ear mesh and save location first.")
            return
        }
        if let reason = stageUnavailableReason(stage, project: project) {
            appendLog(reason)
            return
        }
        if stage == .preprocessing { checkEarDistanceAndRun(project); return }
        runner.prepareAndRun(stage: stage, project: project)
    }

    // MARK: Resetting outputs

    func confirmResetSelectedProjectOutputs() {
        guard selectedProject != nil, !selectedProjectIsRunning else { return }
        if confirmResetOutputs() {
            resetSelectedProjectOutputs()
        }
    }

    func confirmSetBezierPPM(_ enabled: Bool) {
        guard let project = selectedProject, !selectedProjectIsRunning else { return }
        guard project.settings.inference.usePredictionsForPreprocessing != enabled else { return }
        Task { @MainActor in
            // File checks run off the main thread.
            let hasOutputs = await Task.detached(priority: .userInitiated) { Self.hasGeneratedOutputs(project) }.value
            guard selectedProject == project, !selectedProjectIsRunning else { return }
            if hasOutputs {
                guard confirmResetOutputs() else { return }
                resetSelectedProjectOutputs { success in
                    guard success, self.selectedProjectID == project.id else { return }
                    self.setBezierPPM(enabled)
                }
                return
            }
            setBezierPPM(enabled)
        }
    }

    nonisolated static func hasGeneratedOutputs(_ project: ProjectRecord) -> Bool {
        let fitting = project.settings.manualPPMFitting
        if [fitting.leftMeshPath, fitting.rightMeshPath, fitting.leftParametersPath, fitting.rightParametersPath,
            fitting.leftBlendPath, fitting.rightBlendPath, project.scanPreparation.individualLeftEdit, project.scanPreparation.individualRightEdit, project.scanPreparation.reviewedLeftPath,
            project.scanPreparation.reviewedRightPath, project.scanPreparation.originalScanPath == nil
                ? nil : project.scanPreparation.scanPath].compactMap({ $0 }).contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        guard (!project.pipelineLeftEar.isEmpty || !project.pipelineRightEar.isEmpty) && !project.saveLocation.isEmpty else { return false }
        return (project.scanPreparation.enabled && ArtifactScanner.stageIsComplete(.scanPreparation, project: project))
            || (project.settings.inference.usePredictionsForPreprocessing && ArtifactScanner.stageIsComplete(.inference, project: project))
            || ArtifactScanner.stageIsComplete(.preprocessing, project: project)
            || ArtifactScanner.stageIsComplete(.numcalc, project: project)
            || ArtifactScanner.stageIsComplete(.postprocessing, project: project)
    }

    private func confirmRerunPreprocessing() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Preprocessing is out of date"
        alert.informativeText = "Run preprocessing again before continuing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run preprocessing")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmResetOutputs() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset generated outputs?"
        alert.informativeText = "Remove generated pipeline results? Original inputs, saved ear edits, scan alignments, manual PPM fits, microphone positions, settings, logs, and modified or unrelated files are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset outputs")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func resetSelectedProjectOutputs(completion: ((Bool) -> Void)? = nil) {
        guard let project = selectedProject else { return }
        guard !selectedProjectIsRunning else {
            appendLog("Stop the running pipeline before resetting outputs.")
            return
        }
        do {
            let outputs = try runner.outputsFor(project, resettingOutputs: true)
            runner.beginOutputOperation(project.id)
            if isPlacingMicrophone { viewer.cancelMicrophonePlacement() }
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) { outputs.reset() }.value
                runner.endOutputOperation(project.id)
                if result.success { runner.failedStagesByProject[project.id] = [] }
                mutateProject(project.id) { record in
                    record.reconcileAfterOutputReset()
                    if result.success { record.stageOutcomes = nil }
                }
                if selectedProjectID == project.id {
                    viewer.resetViewer()
                    refreshArtifacts()
                }
                appendLog(result.summary, for: project.id)
                completion?(result.success)
            }
        } catch {
            appendLog("Could not reset outputs: \(error.localizedDescription)", for: project.id)
            completion?(false)
        }
    }
}
