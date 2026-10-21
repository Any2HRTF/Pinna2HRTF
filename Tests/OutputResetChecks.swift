import Foundation

func outputResetChecks() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/pinna-output-reset-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    func write(_ relative: String, _ contents: String = "generated") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    let original = try write("Input/scan.stl", "original scan")
    let originalTemplate = try write("Input/PPM.blend", "original template")
    let unrelated = try write("Manual PPM/notes.txt", "keep notes")
    let otherMesh = try write("MeshEdits/reference.stl", "unrelated mesh")
    let generated = ["Prepared/Left.stl", "Prepared/mesh_preparation.json", "Prepared/inference.json",
        "Prepared/preprocessing.json", "Manual PPM/Left.stl", "Manual PPM/Left.json", "Manual PPM/Left.blend",
        "Manual PPM/Left.blend1", "Manual PPM/Templates/00000000-0000-0000-0000-000000000000-PPM.blend",
        "MeshEdits/AlignedScan.ply", "MeshEdits/AlignedScan.json", "MeshEdits/Left.stl", "MeshEdits/Left.json",
        "Intermediates/Left/Prediction_scan.stl", "Intermediates/Left/Prediction_Parameters_scan.csv",
        "Intermediates/Left/graded_head.ply", "Projects/Left/parameters.json",
        "Projects/Left/NumCalc/source_1/NC.inp", "Projects/Left/NumCalc/source_1/be.out/be.1/pBoundary",
        "HRTF/HRIR_test.sofa", "HRTF/HRTF_test.png"]
    for relative in generated { _ = try write(relative) }
    var project = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 1)
    project.saveLocation = root.path
    project.leftEar = ""; project.rightEar = ""
    var scan = ScanPreparationSettings()
    scan.enabled = true
    scan.originalScanPath = original.path
    scan.scanPath = root.appendingPathComponent("MeshEdits/AlignedScan.ply").path
    scan.reviewedLeftPath = root.appendingPathComponent("MeshEdits/Left.stl").path
    project.settings.scanPreparation = scan
    project.settings.manualPPMFitting.setFit(meshPath: root.appendingPathComponent("Manual PPM/Left.stl").path,
        parametersPath: root.appendingPathComponent("Manual PPM/Left.json").path,
        blendPath: root.appendingPathComponent("Manual PPM/Left.blend").path,
        sourcePath: scan.reviewedLeftPath!, sourceIdentity: "test", for: .left)
    project.settings.manualPPMFitting.templateBlendPath = root.appendingPathComponent(generated[8]).path
    project.settings.manualPPMFitting.useForPreprocessing = true

    // Existing projects have no ownership entries for saved editor work.
    let protected = project.protectedOutputInputs(resettingProjectID: project.id)
    precondition(protected.contains(original.path) && !protected.contains(scan.scanPath))
    let outputs = try GeneratedOutputManifest(projectRoot: root.path, inputs: protected)
    let result = outputs.reset()
    precondition(result.success && result.deleted == generated.count, result.summary)
    for relative in generated { precondition(!fm.fileExists(atPath: root.appendingPathComponent(relative).path), relative) }
    for url in [original, originalTemplate, unrelated, otherMesh] { precondition(fm.fileExists(atPath: url.path)) }
    project.reconcileAfterOutputReset()
    precondition(project.scanPreparation.scanPath == original.path && project.scanPreparation.originalScanPath == nil)
    precondition(project.scanPreparation.reviewedLeftPath == nil)
    precondition(project.settings.manualPPMFitting == ManualPPMFittingSettings())
    precondition(!ProjectValidation.issues(for: project).contains { $0.id.hasPrefix("manual_ppm.") })
    precondition(outputs.reset().success)

    // Repeated app saves update the fingerprint; external edits are retained.
    let mesh = try write("Manual PPM/Left.stl", "first save")
    let parameters = try write("Manual PPM/Left.json", "first parameters")
    let blend = try write("Manual PPM/Left.blend", "first blend")
    let template = try write(generated[8], "archived source template")
    try outputs.recordGeneratedFiles([mesh, parameters, blend, template])
    try Data("second app save".utf8).write(to: mesh)
    try Data("second parameters".utf8).write(to: parameters)
    try Data("externally changed template".utf8).write(to: template)
    try outputs.recordGeneratedFiles([mesh, parameters, blend, template])
    try Data("edited outside the app".utf8).write(to: blend)
    let editedResult = outputs.reset()
    precondition(editedResult.success && editedResult.deleted == 2 && editedResult.modified == 2, editedResult.summary)
    precondition(!fm.fileExists(atPath: mesh.path) && !fm.fileExists(atPath: parameters.path))
    let editedBlend = try String(contentsOf: blend, encoding: .utf8)
    precondition(editedBlend == "edited outside the app")

    // A different project's input remains protected even when already tracked.
    let shared = try write("Manual PPM/Right.stl", "shared input")
    try outputs.recordGeneratedFiles([shared])
    var other = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 2)
    other.leftEar = shared.path
    let sharedOutputs = try GeneratedOutputManifest(projectRoot: root.path,
        inputs: protected + other.protectedOutputInputs(resettingProjectID: project.id))
    let sharedResult = sharedOutputs.reset()
    precondition(sharedResult.success && sharedResult.protectedInputs == 1, sharedResult.summary)
    precondition(fm.fileExists(atPath: shared.path))

    // Linked editor folders never permit deletion outside the project.
    let linkedRoot = root.appendingPathComponent("linked-project", isDirectory: true)
    try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent("Manual PPM"), withDestinationURL: mesh.deletingLastPathComponent())
    let linkedOutputs = try GeneratedOutputManifest(projectRoot: linkedRoot.path, inputs: [])
    precondition(linkedOutputs.reset().success && fm.fileExists(atPath: shared.path))
    print("Full output reset removes legacy manual fits, editor meshes and pipeline results; original/shared inputs and external edits stay protected.")
}
