import Foundation

func spatialUpsamplingChecks() throws {
    let defaults = try JSONDecoder().decode(PostprocessingSettings.self, from: Data("{}".utf8))
    precondition(!defaults.spatialUpsampling && defaults.spatialSubdivisions == 3 && defaults.spatialNormalize)
    let root = URL(fileURLWithPath: "/private/tmp/pinna-spatial-checks-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let denseFolder = root.appendingPathComponent("HRTF/Upsampled/HRIR_test", isDirectory: true)
    try FileManager.default.createDirectory(at: denseFolder, withIntermediateDirectories: true)
    var project = Defaults.newProject(packageRoot: Defaults.packageRoot(), index: 1)
    project.saveLocation = root.path
    var settings = defaults
    settings.outputFolder = root.appendingPathComponent("HRTF", isDirectory: true).path
    settings.spatialUpsampling = true
    settings.matlabExecutable = "/Applications/MATLAB.app/bin/matlab"
    settings.amtPath = "/tmp/AMT with spaces"
    project.settings.postprocessing = settings
    let mapping = PipelineConfigWriter.mapping(project: project, environment: Defaults.environment(root: root))
    let restored = try ProjectConfigDocument.restore(mapping, into: project, folder: root, packageRoot: Defaults.packageRoot())
    precondition(restored.settings.postprocessing == settings)
    precondition(!ArtifactScanner.spatialUpsamplingIsCurrent(project))
    let source = root.appendingPathComponent("HRTF/HRIR_test.sofa", isDirectory: false)
    let target = denseFolder.appendingPathComponent("hrtf_Nd=3.sofa", isDirectory: false)
    let magic = Data([0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a])
    try magic.write(to: source); try magic.write(to: target)
    func stamp(_ url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ["size": attributes[.size]!, "mtime": (attributes[.modificationDate] as! Date).timeIntervalSince1970]
    }
    let receipt: [String: Any] = ["method": "LocaDyn-1948", "subdivisions": 3, "normalize": true,
                                  "input": try stamp(source), "output": try stamp(target)]
    try JSONSerialization.data(withJSONObject: receipt).write(to: denseFolder.appendingPathComponent("upsampling.json"))
    precondition(ArtifactScanner.spatialUpsamplingIsCurrent(project))
    project.settings.postprocessing?.spatialSubdivisions = 2
    precondition(!ArtifactScanner.spatialUpsamplingIsCurrent(project))
    project.settings.postprocessing?.spatialSubdivisions = 3
    project.settings.postprocessing?.spatialNormalize = false
    precondition(!ArtifactScanner.spatialUpsamplingIsCurrent(project))
    project.settings.postprocessing?.spatialNormalize = true
    try Data("changed".utf8).write(to: source)
    precondition(!ArtifactScanner.spatialUpsamplingIsCurrent(project))
    for name in ["hrtf_Nd=3.sofa", "hrtf_Nd=0_dense.sofa", "upsampling_report.mat", "upsampling_report.txt", "upsampling.json"] {
        precondition(GeneratedOutputManifest.classify("HRTF/Upsampled/HRIR_test/\(name)") == .postprocessing)
    }
    precondition(GeneratedOutputManifest.classify("HRTF/Upsampled/HRIR_test/notes.txt") == nil)
    let interruptedFolder = root.appendingPathComponent("HRTF/.pinna2hrtf-upsampling-abcd1234", isDirectory: true)
    try FileManager.default.createDirectory(at: interruptedFolder, withIntermediateDirectories: true)
    let interruptedPlan = interruptedFolder.appendingPathComponent("plan.json", isDirectory: false)
    try Data("{}".utf8).write(to: interruptedPlan)
    let store = try GeneratedOutputManifest(projectRoot: root.path, inputs: [])
    _ = store.reset()
    precondition(!FileManager.default.fileExists(atPath: target.path))
    precondition(!FileManager.default.fileExists(atPath: interruptedPlan.path))
    print("Spatial upsampling settings, output freshness and reset ownership checks passed.")
}
