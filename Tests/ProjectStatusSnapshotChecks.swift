import Foundation
import Darwin

func projectStatusSnapshotChecks() throws {
    try preprocessingSignatureChecks()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func write(_ relative: String, _ text: String = "data") throws {
        let url = folder.appendingPathComponent(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    var project = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 1)
    project.saveLocation = folder.path
    project.leftEar = folder.appendingPathComponent("input.stl", isDirectory: false).path
    project.rightEar = ""
    project.settings.inference.usePredictionsForPreprocessing = false
    var environment = Defaults.environment(root: folder)
    environment.meshGradingExecutable = "/usr/bin/true"
    environment.numcalcExecutable = "/usr/bin/true"
    environment.externalDir = folder.path
    try write("input.stl")
    try write("src/Mesh2HRTF/mesh2hrtf/tool")
    func inspect() -> ProjectStatusSnapshot {
        ProjectStatusSnapshot.load(project: project, environment: environment, projects: [project], placingMicrophone: false)
    }
    let initial = inspect()
    precondition(!initial.completed.contains(.preprocessing))
    precondition(initial.unavailableReasons[.numcalc] != nil)
    precondition(initial.pipelineSides == [.left] && initial.fittableSides == [.left])
    precondition(initial.artifacts.allSatisfy { $0.cachedExists != nil })
    try write("Projects/Left/parameters.json", "{\"numFrequencies\":1}")
    try write("Intermediates/Left/graded_head.ply")
    for output in ["pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"] {
        try write("Projects/Left/NumCalc/source_1/be.out/be.1/\(output)")
    }
    try write("Projects/Left/NumCalc/source_1/NC1-1_log.txt", "---------- NumCalc ended:")
    let log = folder.appendingPathComponent("Projects/Left/NumCalc/source_1/NC1-1_log.txt", isDirectory: false)
    try FileManager.default.removeItem(at: log)
    precondition(mkfifo(log.path, 0o600) == 0)
    precondition(ProjectStatusSnapshot.configuredPreviewArtifacts(for: project).contains { $0.url.path == project.leftEar && $0.exists })
    // A blocked server log must not delay the first snapshot or sidebar labels.
    // Reading this FIFO would block forever without a writer.
    let quick = ProjectStatusSnapshot.load(project: project, environment: environment, projects: [project],
                                           placingMicrophone: false, includeSolverResults: false)
    precondition(quick.checkingSolverResults && !quick.completed.contains(.numcalc))
    precondition(quick.completed.contains(.preprocessing) && quick.fittableSides == [.left])
    precondition(quick.artifacts.contains(where: { $0.url.path == project.leftEar && $0.exists }))
    precondition(quick.unavailableReasons[.postprocessing] == "Checking solver results…")
    precondition(!ProjectStatusSnapshot.savedSummary(for: project).isEmpty)
    try FileManager.default.removeItem(at: log)
    try write("Projects/Left/NumCalc/source_1/NC1-1_log.txt", "---------- NumCalc ended:")
    let cancelled = ArtifactScanner.Inspection(isCancelled: { true })
    precondition(!ArtifactScanner.frequencyStepComplete(source: log.deletingLastPathComponent(), step: 1, inspection: cancelled))
    let solved = inspect()
    precondition(solved.completed.contains(.numcalc) && solved.states[.numcalc] == .done)
    precondition(solved.numcalcStatus.contains("Left 1/1"))
    precondition(solved.unavailableReasons[.numcalc] == nil)
    precondition(!solved.preprocessingNeedsRerun)
    project.settings.preprocessing.minFrequency = "10"
    precondition(inspect().preprocessingNeedsRerun)
    try FileManager.default.removeItem(atPath: project.leftEar)
    // Rendering an existing snapshot must never probe the share again.
    precondition(solved.artifacts.first(where: { $0.url.path == project.leftEar })?.exists == true)
    let missing = inspect()
    precondition(missing.fittableSides.isEmpty)
    precondition(missing.unavailableReasons[.numcalc]?.contains("missing") == true)
    print("Project status snapshots preserve solver readiness, freshness and cached artifact availability.")
}

private func preprocessingSignatureChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func file(_ path: String, _ contents: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url.path
    }
    func signature(_ project: ProjectRecord) -> String { ArtifactScanner.preprocessingSignature(for: project) }
    func legacy(_ project: ProjectRecord) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let manual = project.settings.manualPPMFitting
        return [project.leftEar, project.rightEar, project.inputHandling.rawValue,
                ArtifactScanner.meshIdentity(URL(fileURLWithPath: project.leftEar)) ?? "", "",
                try json(project.settings.inference), try json(project.settings.preprocessing),
                manual.useForPreprocessing ? try json(manual) : "",
                manual.useForPreprocessing ? ArtifactScanner.meshIdentity(URL(fileURLWithPath: manual.leftMeshPath!)) ?? "" : "", ""].joined(separator: "\n")
    }
    var original = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 1)
    original.leftEar = try file("old/input.stl", "ear geometry")
    original.rightEar = ""
    original.saveLocation = root.appendingPathComponent("old/results").path
    original.settings.preprocessing.evaluationGrid = root.appendingPathComponent("old/grid").path
    _ = try file("old/grid/Nodes.txt", "grid nodes")
    _ = try file("old/grid/Elements.txt", "grid elements")
    let baseline = signature(original)
    let receipt = try legacy(original)
    var moved = original
    moved.leftEar = try file("new/input.stl", "ear geometry")
    moved.settings.preprocessing.evaluationGrid = root.appendingPathComponent("new/grid").path
    _ = try file("new/grid/Nodes.txt", "grid nodes")
    _ = try file("new/grid/Elements.txt", "grid elements")
    moved.saveLocation = root.appendingPathComponent("new/results").path
    moved.name = "Renamed project"
    moved.inputHandling = original.inputHandling == .copy ? .reference : .copy
    moved.settings.inference.modelCheckpoint = "/unused/model"
    moved.settings.preprocessing.useCustomHeadRadius = false
    moved.settings.preprocessing.headRadius = "100"
    precondition(signature(moved) == baseline, "Identical relocated files and inactive settings must not invalidate results")
    precondition(PreprocessingSignature.matches(receipt, project: moved))
    let earlyReceipt = receipt.components(separatedBy: "\n").prefix(7).joined(separator: "\n")
    precondition(PreprocessingSignature.matches(earlyReceipt, project: moved))
    var changed = moved
    changed.settings.preprocessing.maxFrequency = "22000"
    precondition(signature(changed) != baseline)
    precondition(!PreprocessingSignature.matches(receipt, project: changed))
    changed = moved; changed.settings.preprocessing.meshMaxError = "0.25"
    precondition(signature(changed) != baseline)
    changed = moved; changed.settings.preprocessing.useCustomHeadRadius = true
    precondition(signature(changed) != baseline)
    changed = moved; changed.settings.preprocessing.sourceAssignmentFaceCount = "12"
    precondition(signature(changed) != baseline)
    var microphone = moved
    microphone.settings.preprocessing.sourcePositionInputLeft = ManualMicrophonePosition(x: 1, y: 2, z: 3, meshPath: original.leftEar, meshIdentity: "original provenance")
    let microphoneBaseline = signature(microphone)
    microphone.settings.preprocessing.sourcePositionInputLeft?.meshPath = moved.leftEar
    microphone.settings.preprocessing.sourcePositionInputLeft?.meshIdentity = "relocated provenance"
    precondition(signature(microphone) == microphoneBaseline)
    microphone.settings.preprocessing.sourcePositionInputLeft?.x = 4
    precondition(signature(microphone) != microphoneBaseline)
    changed = moved; changed.preservedConfigJSON = "{\"preprocessing\":{\"speed_of_sound\":350}}"
    precondition(signature(changed) != baseline)
    changed = moved; changed.preservedConfigJSON = "{\"preprocessing\":{\"title\":\"different\",\"pictures\":true}}"
    precondition(signature(changed) == baseline)
    _ = try file("new/grid/Nodes.txt", "different grid nodes")
    precondition(signature(moved) != baseline)
    _ = try file("new/grid/Nodes.txt", "grid nodes")
    _ = try file("new/input.stl", "different ear geometry")
    precondition(signature(moved) != baseline)
    _ = try file("new/input.stl", "ear geometry")

    var fitted = original
    fitted.settings.manualPPMFitting.useForPreprocessing = true
    fitted.settings.manualPPMFitting.leftMeshPath = try file("old/fit.stl", "fitted mesh")
    let fitReceipt = try legacy(fitted), fitBaseline = signature(fitted)
    var movedFit = fitted
    movedFit.leftEar = moved.leftEar
    movedFit.settings.manualPPMFitting.leftMeshPath = try file("new/fit.stl", "fitted mesh")
    movedFit.settings.manualPPMFitting.leftParametersPath = "/new/fit/parameters.json"
    movedFit.settings.manualPPMFitting.leftSourcePath = moved.leftEar
    movedFit.settings.manualPPMFitting.leftSourceIdentity = "relocated provenance"
    precondition(signature(movedFit) == fitBaseline)
    precondition(PreprocessingSignature.matches(fitReceipt, project: movedFit))
    _ = try file("new/fit.stl", "different fitted mesh")
    precondition(signature(movedFit) != fitBaseline)

    var inferred = original
    inferred.settings.inference.usePredictionsForPreprocessing = true
    inferred.settings.inference.modelConfig = try file("old/model.json", "model config")
    inferred.settings.inference.modelCheckpoint = try file("old/model.pth", "model checkpoint")
    _ = try file("old/results/Intermediates/Left/Prediction_input.stl", "prediction")
    let inferredBaseline = signature(inferred)
    var movedInference = inferred
    movedInference.leftEar = moved.leftEar
    movedInference.saveLocation = moved.saveLocation
    movedInference.settings.inference.modelConfig = try file("new/model.json", "model config")
    movedInference.settings.inference.modelCheckpoint = try file("new/model.pth", "model checkpoint")
    _ = try file("new/results/Intermediates/Left/Prediction_input.stl", "prediction")
    precondition(signature(movedInference) == inferredBaseline)
    _ = try file("new/model.pth", "different checkpoint")
    precondition(signature(movedInference) != inferredBaseline)

    // The same status loader used by the app upgrades a matching legacy receipt,
    // while preserving warnings for real setting changes and malformed receipts.
    _ = try file("new/results/Projects/Left/parameters.json", "{\"numFrequencies\":1}")
    _ = try file("new/results/Intermediates/Left/graded_head.ply", "head")
    let receiptURL = URL(fileURLWithPath: moved.saveLocation).appendingPathComponent(".pinna2hrtf-preprocessing-signature")
    try receipt.write(to: receiptURL, atomically: true, encoding: .utf8)
    func status(_ project: ProjectRecord) -> ProjectStatusSnapshot {
        ProjectStatusSnapshot.load(project: project, environment: Defaults.environment(root: root), projects: [project], placingMicrophone: false, includeSolverResults: false)
    }
    precondition(!status(moved).preprocessingNeedsRerun)
    let upgraded = try String(contentsOf: receiptURL, encoding: .utf8)
    precondition(upgraded == baseline)
    changed = moved; changed.settings.preprocessing.frequencyStepCount = "257"
    precondition(status(changed).preprocessingNeedsRerun)
    try "invalid receipt".write(to: receiptURL, atomically: true, encoding: .utf8)
    precondition(status(moved).preprocessingNeedsRerun)
    print("Preprocessing signatures ignore relocation and detect changed geometry, grids, models and calculation settings.")
}
