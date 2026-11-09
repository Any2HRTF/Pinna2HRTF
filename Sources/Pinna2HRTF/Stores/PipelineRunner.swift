import Foundation
import AppKit
import UserNotifications

/// Runs pipeline stages and environment setup, tracks generated outputs, captures
/// technical logs, stops process trees and posts completion notifications.
@MainActor
final class PipelineRunner: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private struct PipelineRun {
        let process: Process
        let stage: Stage
    }

    @Published private var runs: [UUID: PipelineRun] = [:]
    @Published private(set) var stoppingProjects = Set<UUID>()
    /// Number of output operations in flight per project; overlapping operations
    /// each hold their own reference.
    @Published private var outputOperationCounts: [UUID: Int] = [:]
    @Published private(set) var environmentProcess: Process?
    @Published var failedStagesByProject: [UUID: Set<Stage>] = [:]
    private var environmentSetupCancelled = false
    private var outputStores: [String: GeneratedOutputManifest] = [:]
    private var notificationsConfigured = false
    private let launcher = ProcessLauncher.shared

    weak var store: AppStore?

    var runningProcesses: [UUID: Process] { runs.mapValues(\.process) }
    var runningStages: [UUID: Stage] { runs.mapValues(\.stage) }

    private func log(_ text: String, for projectID: UUID? = nil) { store?.appendLog(text, for: projectID) }
    private var activity: ActivityLog? { store?.activity }

    // MARK: Output operations

    func beginOutputOperation(_ id: UUID) { outputOperationCounts[id, default: 0] += 1 }

    func endOutputOperation(_ id: UUID) {
        guard let count = outputOperationCounts[id] else { return }
        outputOperationCounts[id] = count > 1 ? count - 1 : nil
    }

    func isManagingOutputs(_ id: UUID) -> Bool { outputOperationCounts[id] != nil }
    var hasOutputOperations: Bool { !outputOperationCounts.isEmpty }

    func isBusy(_ id: UUID) -> Bool {
        runs[id] != nil || isManagingOutputs(id) || stoppingProjects.contains(id)
    }

    func forget(_ id: UUID) {
        runs[id] = nil
        failedStagesByProject[id] = nil
    }

    func outputsFor(_ project: ProjectRecord, resettingOutputs: Bool = false) throws -> GeneratedOutputManifest {
        guard let store else { throw GeneratedOutputManifest.Failure.invalidRoot }
        guard !project.saveLocation.isEmpty else { throw GeneratedOutputManifest.Failure.invalidRoot }
        let projects = store.projects
        let root = ProjectLibrary.realPath(project.saveLocation)
        for other in projects where other.id != project.id && !other.saveLocation.isEmpty {
            let otherRoot = ProjectLibrary.realPath(other.saveLocation)
            guard !ProjectLibrary.path(root, contains: otherRoot), !ProjectLibrary.path(otherRoot, contains: root) else {
                throw GeneratedOutputManifest.Failure.invalidRoot
            }
        }
        let inputs = projects.flatMap { $0.protectedOutputInputs(resettingProjectID: resettingOutputs ? project.id : nil) }.sorted()
        let key = project.saveLocation + "\n" + (project.settings.postprocessing?.outputFolder ?? "") + "\n" + inputs.joined(separator: "\n")
        if let existing = outputStores[key] { return existing }
        let outputs = try GeneratedOutputManifest(projectRoot: project.saveLocation, inputs: inputs, outputFolder: project.settings.postprocessing?.outputFolder)
        outputStores[key] = outputs
        return outputs
    }

    func recordEditorOutputs(for project: ProjectRecord, urls: [URL]) {
        do {
            let outputs = try outputsFor(project, resettingOutputs: true)
            beginOutputOperation(project.id)
            Task { @MainActor in
                defer { endOutputOperation(project.id); store?.refreshArtifacts() }
                do { try await Task.detached(priority: .userInitiated) { try outputs.recordGeneratedFiles(urls) }.value }
                catch { log("Could not record saved editor outputs: \(error.localizedDescription)", for: project.id) }
            }
        } catch { log("Could not record saved editor outputs: \(error.localizedDescription)", for: project.id) }
    }

    // MARK: Pipeline stages

    func prepareAndRun(stage: Stage, project: ProjectRecord) {
        guard let environment = store?.environment, !isManagingOutputs(project.id), runs[project.id] == nil else { return }
        beginOutputOperation(project.id)
        Task { @MainActor in
            do {
                _ = try outputsFor(project)
                try prepareRuntimeProject()
                let configURL = try await Task.detached(priority: .userInitiated) {
                    try PipelineConfigWriter.prepare(project: project, environment: environment, stage: stage)
                }.value
                endOutputOperation(project.id)
                guard store?.projects.contains(where: { $0.id == project.id }) == true else { return }
                startProcess(stage: stage, project: project, configURL: configURL, environment: environment)
            } catch {
                endOutputOperation(project.id)
                store?.setStageOutcome(stage, for: project.id, to: .failed)
                store?.refreshArtifacts()
                log("Could not prepare project: \(error.localizedDescription)", for: project.id)
            }
        }
    }

    private func startProcess(stage: Stage, project: ProjectRecord, configURL: URL, environment: EnvironmentConfig) {
        guard !isManagingOutputs(project.id), runs[project.id] == nil else { return }
        do {
            let outputs = try outputsFor(project)
            beginOutputOperation(project.id)
            Task { @MainActor in
                defer { endOutputOperation(project.id); store?.refreshArtifacts() }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try outputs.begin(GeneratedOutputManifest.OutputStage(rawValue: stage.rawValue.capitalized)!)
                    }.value
                    await launchProcess(stage: stage, project: project, configURL: configURL, outputs: outputs, environment: environment)
                } catch {
                    store?.setStageOutcome(stage, for: project.id, to: .failed)
                    log("Could not track project outputs: \(error.localizedDescription)", for: project.id)
                }
            }
        } catch {
            store?.setStageOutcome(stage, for: project.id, to: .failed)
            log("Could not track project outputs: \(error.localizedDescription)", for: project.id)
        }
    }

    private func launchProcess(stage: Stage, project: ProjectRecord, configURL: URL, outputs: GeneratedOutputManifest,
                               environment: EnvironmentConfig) async {
        if AppPreferences.notificationEnabled(AppPreferences.notifyCompletion) || AppPreferences.notificationEnabled(AppPreferences.notifyFailure) {
            configureNotifications()
        }
        let process: Process
        do {
            process = try launcher.makeProcess(.pipelineStage(stage, config: configURL), environment: environment, liveEvents: true)
        } catch {
            store?.setStageOutcome(stage, for: project.id, to: .failed)
            log("Could not start \(stage.title): \(error.localizedDescription)", for: project.id)
            do { try await Task.detached { try outputs.complete() }.value }
            catch { log("Output tracking is pending; it will be retried before reset.", for: project.id) }
            return
        }
        let runID = UUID()
        let startedAt = Date()
        let logURL = ActivityLog.technicalLogURL(project: project, stage: stage, runID: runID, date: startedAt)
        let capture: PipelineLogCapture?
        do {
            let header = [
                "Pinna2HRTF technical output",
                "Project: \(project.name)",
                "Stage: \(stage.title)",
                "Started: \(startedAt.formatted(date: .complete, time: .standard))",
                "Command: \(process.executableURL?.path ?? "") \((process.arguments ?? []).joined(separator: " "))",
                "",
                "--- stdout and stderr ---",
                ""
            ].joined(separator: "\n")
            capture = try PipelineLogCapture(fileURL: logURL, header: header, onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.activity?.record(event, stage: stage, projectID: project.id, runID: runID)
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.log("Could not save complete technical output: \(message)", for: project.id)
                }
            })
            activity?.setTechnicalLog(logURL, for: project.id)
        } catch {
            capture = nil
            log("Could not create a technical log: \(error.localizedDescription)", for: project.id)
        }
        runs[project.id] = PipelineRun(process: process, stage: stage)
        activity?.liveStatusByProject[project.id] = "Running · \(stage.title)"
        store?.setStageOutcome(stage, for: project.id, to: .running)
        store?.refreshArtifacts()
        let details = stageStartDetails(stage: stage, project: project)
        log("\(stage.title) started\(details.isEmpty ? "" : " · \(details)")", for: project.id)
        let onExit: @Sendable (Process) -> Void = { [weak self] process in
            Task { @MainActor [weak self] in
                await self?.finishRun(stage: stage, project: project, status: process.terminationStatus,
                                      startedAt: startedAt, outputs: outputs)
            }
        }
        do {
            try launcher.launch(process, capturing: capture, onExit: onExit)
        } catch {
            store?.setStageOutcome(stage, for: project.id, to: .failed)
            runs[project.id] = nil
            activity?.liveStatusByProject[project.id] = "Could not start · \(stage.title)"
            store?.refreshArtifacts()
            log("Could not start \(stage.title): \(error.localizedDescription)", for: project.id)
            do { try await Task.detached { try outputs.complete() }.value }
            catch { log("Output tracking is pending; it will be retried before reset.", for: project.id) }
        }
    }

    private func finishRun(stage: Stage, project: ProjectRecord, status: Int32, startedAt: Date, outputs: GeneratedOutputManifest) async {
        guard let store else { return }
        beginOutputOperation(project.id)
        runs[project.id] = nil
        activity?.liveStatusByProject[project.id] = "Checking outputs · \(stage.title)"
        let stopped = stoppingProjects.contains(project.id) || store.projects.first(where: { $0.id == project.id })?.stageOutcomes?[stage.rawValue] == .stopped
        var outcome: StageState = stopped ? .stopped : .failed
        var validationError: String?
        if status == 0 && !stopped {
            do {
                try await Task.detached(priority: .userInitiated) { try OutputValidation.validate(stage: stage, project: project) }.value
                if [.inference, .postprocessing].contains(stage) {
                    try await Task.detached { try StageReceipt.record(stage, project) }.value
                }
                outcome = .done
            } catch { validationError = error.localizedDescription }
        }
        if (stage == .scanPreparation || stage == .inference), outcome == .done { store.clearStaleMicrophonePositions(for: project.id) }
        if stage == .scanPreparation, outcome == .done {
            store.mutateProject(project.id) { project in
                var scan = project.scanPreparation
                scan.reviewedLeftPath = nil
                scan.reviewedRightPath = nil
                project.settings.scanPreparation = scan
            }
        }
        if stage == .preprocessing, outcome == .done {
            await Task.detached(priority: .utility) { Self.recordPreprocessingSignature(for: project) }.value
        }
        do {
            try await Task.detached(priority: .userInitiated) { try outputs.complete() }.value
        } catch {
            log("Output tracking is pending; it will be retried before reset.", for: project.id)
        }
        store.setStageOutcome(stage, for: project.id, to: outcome)
        let elapsed = Self.elapsedDescription(since: startedAt)
        if outcome == .done {
            activity?.liveStatusByProject[project.id] = "Completed · \(stage.title)"
            if AppPreferences.notificationEnabled(AppPreferences.notifyCompletion) {
                sendNotification(title: "\(stage.title) complete", body: "\(project.name): \(stage.title) finished successfully.")
            }
            log("\(stage.title) finished in \(elapsed) · outputs verified", for: project.id)
        } else if outcome == .stopped {
            activity?.liveStatusByProject[project.id] = "Stopped · \(stage.title)"
            log("\(stage.title) stopped after \(elapsed). Previous results may still be available.", for: project.id)
        } else {
            activity?.liveStatusByProject[project.id] = "Failed · \(stage.title)"
            let cause = validationError ?? "Exit status \(status)."
            let logHint = activity?.technicalLogURLs[project.id].map { "Technical output: \($0.lastPathComponent)." } ?? "Open the technical log for details."
            let detail = "\(cause) \(logHint)"
            if AppPreferences.notificationEnabled(AppPreferences.notifyFailure) {
                sendNotification(title: "\(stage.title) failed", body: "\(project.name): \(detail)")
            }
            log("\(stage.title) failed after \(elapsed): \(detail) Previous results are not a successful rerun.", for: project.id)
        }
        endOutputOperation(project.id)
        store.refreshArtifacts()
    }

    nonisolated static func recordPreprocessingSignature(for project: ProjectRecord) {
        guard !project.saveLocation.isEmpty else { return }
        let output = URL(fileURLWithPath: project.saveLocation)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? ArtifactScanner.preprocessingSignature(for: project)
            .write(to: output.appendingPathComponent(".pinna2hrtf-preprocessing-mac-v2.json"), atomically: true, encoding: .utf8)
    }

    // MARK: Stopping

    func stop(_ projectID: UUID) {
        guard let run = runs[projectID], !stoppingProjects.contains(projectID) else { return }
        stoppingProjects.insert(projectID)
        store?.setStageOutcome(run.stage, for: projectID, to: .stopped)
        log("Stopping task and its child processes.", for: projectID)
        launcher.cancel(run.process) { [weak self] in
            Task { @MainActor [weak self] in
                self?.stoppingProjects.remove(projectID)
                self?.store?.refreshArtifacts()
            }
        }
    }

    /// Stops pipeline runs, environment setup and every helper, then calls `completion`.
    func stopAll(completion: @escaping @MainActor () -> Void) {
        for (id, stage) in runningStages {
            stoppingProjects.insert(id)
            store?.setStageOutcome(stage, for: id, to: .stopped)
        }
        let launcher = launcher
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { launcher.terminateAll() }.value
            completion()
        }
    }

    // MARK: Environment setup

    func setupEnvironment() {
        guard let store else { return }
        guard environmentProcess == nil else {
            log("Environment setup is already running.")
            return
        }
        do {
            try prepareRuntimeProject()
        } catch {
            log("Could not prepare runtime folder: \(error.localizedDescription)")
            return
        }
        if !Defaults.isPackagedApp {
            copyPathToolsIntoEnvironment()
        }
        let logProjectID = store.selectedProjectID
        let process: Process
        do {
            process = try launcher.makeProcess(.uvSync, environment: store.environment, liveEvents: true)
        } catch {
            log(error.localizedDescription)
            return
        }
        environmentProcess = process
        environmentSetupCancelled = false
        let runID = UUID()
        let projectForLog = logProjectID.flatMap { id in store.projects.first { $0.id == id } }
        let logDirectory = projectForLog.flatMap(ActivityLog.projectLogDirectory(for:))
            ?? Defaults.appDataURL.appendingPathComponent("Logs", isDirectory: true)
        let logURL = logDirectory.appendingPathComponent("Environment-\(runID.uuidString).log")
        let capture: PipelineLogCapture?
        do {
            capture = try PipelineLogCapture(fileURL: logURL, header: "Pinna2HRTF environment setup\nStarted: \(Date().formatted(date: .complete, time: .standard))\n\n--- stdout and stderr ---\n\n", onEvent: { _ in }, onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.log("Could not save complete environment setup output: \(message)", for: logProjectID)
                }
            })
            activity?.setEnvironmentLog(logURL)
            activity?.setTechnicalLog(logURL, for: logProjectID)
        } catch {
            capture = nil
            log("Could not create an environment setup log: \(error.localizedDescription)", for: logProjectID)
        }
        log("Environment setup started.", for: logProjectID)
        if let logProjectID { activity?.liveStatusByProject[logProjectID] = "Setting up environment" }
        let onExit: @Sendable (Process) -> Void = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cancelled = self.environmentSetupCancelled
                let result = cancelled ? "Environment setup cancelled."
                    : status == 0 ? "Environment setup finished."
                    : "Environment setup failed (status \(status)). Technical output: \(logURL.lastPathComponent)."
                self.log(result, for: logProjectID)
                if let logProjectID {
                    self.activity?.liveStatusByProject[logProjectID] = cancelled ? "Environment setup cancelled"
                        : status == 0 ? "Environment ready" : "Environment setup failed"
                }
                self.environmentProcess = nil
                self.store?.refreshArtifacts()
            }
        }
        do {
            try launcher.launch(process, capturing: capture, onExit: onExit)
        } catch {
            environmentProcess = nil
            if let logProjectID { activity?.liveStatusByProject[logProjectID] = "Could not start environment setup" }
            log("Could not start environment setup: \(error.localizedDescription)")
        }
    }

    func cancelEnvironmentSetup() {
        guard let process = environmentProcess, !environmentSetupCancelled else { return }
        environmentSetupCancelled = true
        log("Cancelling environment setup…", for: store?.selectedProjectID)
        launcher.cancel(process)
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

    private var runtimeProjectIsReady: Bool {
        let package = ProcessLauncher.packageURL
        let pythonPath = store?.environment.pythonExecutable ?? ProcessLauncher.runtimePythonURL.path
        return FileManager.default.fileExists(atPath: package.appendingPathComponent("HRTFCalculation/RunConfig.py").path) &&
            FileManager.default.fileExists(atPath: package.appendingPathComponent("HRTFCalculation/__main__.py").path) &&
            FileManager.default.isExecutableFile(atPath: pythonPath)
    }

    private func copyPathToolsIntoEnvironment() {
        guard let store else { return }
        let bin = URL(fileURLWithPath: store.environment.externalDir).appendingPathComponent("bin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        } catch {
            log("Could not prepare dependency folder \(bin.path): \(error.localizedDescription)")
            return
        }
        let tools = [
            ("uv", \EnvironmentConfig.uvExecutable),
            ("NumCalc", \EnvironmentConfig.numcalcExecutable),
            ("hrtf_mesh_grading", \EnvironmentConfig.meshGradingExecutable)
        ]
        for tool in tools {
            let current = store.environment[keyPath: tool.1]
            if FileManager.default.isExecutableFile(atPath: current) {
                continue
            }
            guard let source = Defaults.which(tool.0) else {
                log("\(tool.0) is missing from the app bundle and PATH.")
                continue
            }
            let target = bin.appendingPathComponent(tool.0)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                store.updateEnvironment {
                    switch tool.0 {
                    case "uv": $0.uvExecutable = target.path
                    case "NumCalc": $0.numcalcExecutable = target.path
                    default: $0.meshGradingExecutable = target.path
                    }
                }
            } catch {
                log("Could not copy \(tool.0) into the app dependencies: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Notifications

    private func configureNotifications() {
        guard !notificationsConfigured else { return }
        notificationsConfigured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                if error != nil {
                    self?.log("Primary desktop notifications unavailable; stage completions will use the macOS fallback.")
                } else if !granted {
                    self?.log("Desktop notifications are disabled in macOS settings.")
                }
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let identifier = "Pinna2HRTF-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.log("Primary completion notification failed; using the macOS fallback.")
                    self?.sendFallbackNotification(title: title, body: body)
                }
            }
        }
    }

    private func sendFallbackNotification(title: String, body: String) {
        guard AppPreferences.enabled(AppPreferences.notifyAll) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(Self.appleScriptString(body)) with title \(Self.appleScriptString(title))"]
        try? launcher.launch(process)
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(AppPreferences.enabled(AppPreferences.notifyAll) ? [.banner, .sound] : [])
    }

    // MARK: Helpers

    private func stageStartDetails(stage: Stage, project: ProjectRecord) -> String {
        if stage == .scanPreparation {
            let scan = URL(fileURLWithPath: project.scanPreparation.scanPath).lastPathComponent
            let sides = [project.scanPreparation.prepareLeft ? "Left" : nil, project.scanPreparation.prepareRight ? "Right" : nil].compactMap { $0 }.joined(separator: " + ")
            return "\(scan) · \(sides) ear\(sides.contains("+") ? "s" : "") · rotation \(project.scanPreparation.rotationDegrees)°"
        }
        if stage == .numcalc || stage == .postprocessing { return "Project output: \(URL(fileURLWithPath: project.saveLocation).lastPathComponent)" }
        let inputs = [("Left", project.pipelineLeftEar), ("Right", project.pipelineRightEar)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0) \(URL(fileURLWithPath: $0.1).lastPathComponent)" }
        return inputs.isEmpty ? "" : "Inputs: \(inputs.joined(separator: ", "))"
    }

    private static func elapsedDescription(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
