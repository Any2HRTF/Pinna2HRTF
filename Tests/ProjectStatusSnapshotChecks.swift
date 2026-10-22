import Foundation

func projectStatusSnapshotChecks() throws {
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
