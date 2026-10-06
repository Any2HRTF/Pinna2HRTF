import Foundation

@main
struct MacOSFeatureChecks {
    static let fm = FileManager.default
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/pinna2hrtf-feature-checks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ content: String = "generated") throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }

        let generated = ["Intermediates/Left/Prediction_Left.stl", "Intermediates/Left/graded_head.ply",
            "Projects/Left/parameters.json", "Projects/Left/NumCalc/source_1/NC.inp",
            "Projects/Left/NumCalc/source_1/NC1-2_log.txt", "Projects/Left/NumCalc/source_1/be.out/be.1/pEvalGrid",
            "Projects/Left/Output2HRTF/report_source_1.csv", "HRTF/HRIR_Left.sofa"]
        for path in generated { try write(path) }
        for path in ["Project Settings.yaml", "project.log", "Input/Left/ear.stl", "Projects/Left/notes.txt",
            "HRTF/HRIR_Input.sofa", "Projects/Left/EvaluationGrids/User/Nodes.txt"] { try write(path, "user data") }
        try fm.createDirectory(at: root.appendingPathComponent("Projects/Right/NumCalc/source_2/be.out/be.9"), withIntermediateDirectories: true)
        let protected = ["HRTF/HRIR_Input.sofa", "Projects/Left/EvaluationGrids/User"].map { root.appendingPathComponent($0).path }
        let store = try GeneratedOutputManifest(projectRoot: root.path, inputs: protected)
        try store.begin(.numcalc)
        require(!store.reset().success, "Reset must refuse a running stage")
        let competing = try GeneratedOutputManifest(projectRoot: root.path, inputs: protected)
        require(!competing.reset().success, "A second app instance must honor the output lock")
        try store.complete()
        try write("Intermediates/Left/graded_head.ply", "manually edited")
        let result = store.reset()
        require(result.errors == 0 && result.modified == 1 && result.deleted == generated.count - 1, "Reset accounting is incorrect: \(result.summary)")
        require(exists("Intermediates/Left/graded_head.ply"), "Edited output must survive")
        require(!exists("Projects/Right"), "Empty failed-stage shells must be removed")
        for path in generated where path != "Intermediates/Left/graded_head.ply" { require(!exists(path), "Generated file survived: \(path)") }
        for path in ["Project Settings.yaml", "project.log", "Input/Left/ear.stl", "Projects/Left/notes.txt", "HRTF/HRIR_Input.sofa", "Projects/Left/EvaluationGrids/User/Nodes.txt"] {
            require(exists(path), "Protected or unrelated file was removed: \(path)")
        }
        require(store.reset().modified == 1, "Repeated reset must not rebaseline an edited file")

        let recoveryRoot = root.appendingPathComponent("recovery")
        var interrupted: GeneratedOutputManifest? = try GeneratedOutputManifest(projectRoot: recoveryRoot.path, inputs: [])
        try interrupted!.begin(.inference)
        let recoveredFile = recoveryRoot.appendingPathComponent("Intermediates/Right/Prediction_Right.stl")
        try fm.createDirectory(at: recoveredFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: recoveredFile)
        interrupted = nil
        let recovery = try GeneratedOutputManifest(projectRoot: recoveryRoot.path, inputs: [])
        require(recovery.reset().deleted == 1, "Crash recovery must capture partial stage output")
        require(!fm.fileExists(atPath: recoveredFile.path), "Recovered output survived reset")

        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("HRIR_Outside.sofa"))
        try fm.createSymbolicLink(at: recoveryRoot.appendingPathComponent("HRTF"), withDestinationURL: outside)
        require(recovery.reset().errors == 0, "Symlinked outputs should be skipped")
        require(fm.fileExists(atPath: outside.appendingPathComponent("HRIR_Outside.sofa").path), "Reset followed a symlink")
        try Data("invalid".utf8).write(to: recoveryRoot.appendingPathComponent(".pinna2hrtf/generated-output-manifest.json"))
        require(!recovery.reset().success, "Corrupt manifests must stop deletion")

        let old = try JSONDecoder().decode(PostprocessingSettings.self, from: Data(#"{"normalize":false,"levelOffsetDB":"-12"}"#.utf8))
        require(!old.resampleHrirs && old.samplingRate == "48000" && !old.normalize, "Old project settings must remain readable")
        var post = old
        post.resampleHrirs = true; post.samplingRate = "44100"
        let restored = try JSONDecoder().decode(PostprocessingSettings.self, from: JSONEncoder().encode(post))
        require(restored == post && restored.normalizedSamplingRate == 44100, "Resampling settings did not round-trip")
        for rate in ["0", "-48000", "44101", "invalid"] { post.samplingRate = rate; require(post.normalizedSamplingRate == 48000, "Invalid rate should use the Windows default") }
        var project = ProjectRecord(name: "Test", leftEar: "", rightEar: "", saveLocation: root.path, settings: ProjectSettings(inference: InferenceSettings(modelConfig: "", modelCheckpoint: "")))
        post.samplingRate = "44100"; project.settings.postprocessing = post
        let yaml = PipelineConfigWriter.yaml(project: project, environment: EnvironmentConfig(uvExecutable: "uv", numcalcExecutable: "NumCalc", meshGradingExecutable: "hrtf_mesh_grading", externalDir: root.path), manualPositions: [:])
        require(yaml.contains("resample_hrirs: true") && yaml.contains("sampling_rate: 44100"), "Resampling options are missing from pipeline YAML")
        print("Passed macOS checks: output deletion, protected and edited files, empty shells, locking, recovery, symlinks, corrupt metadata, settings migration, and resampling YAML.")
    }
}
