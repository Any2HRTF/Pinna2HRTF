import Foundation
import simd

@main
struct ScanPreparationChecks {
    static func cuttingPlanePreviewChecks() {
        let points: [SIMD3<Float>] = [SIMD3(-10,-4,0), SIMD3(10,-4,0), SIMD3(0,4,0), SIMD3(0,0,10)]
        let faces: [UInt32] = [0,1,2, 0,3,1, 0,2,3, 1,3,2]
        func fit(_ points: [SIMD3<Float>], _ origin: SIMD3<Float>, _ normal: SIMD3<Float>) -> CuttingPlanePreview {
            CuttingPlanePreview.fit(vertices: points.flatMap { [$0.x, $0.y, $0.z] }, faces: faces,
                                    origin: origin, normal: normal)!
        }
        let base = fit(points, .zero, SIMD3(0,0,1))
        let tip = fit(points, SIMD3(0,0,5), SIMD3(0,0,1))
        precondition(abs(base.width - 21.6) < 0.0001 && abs(base.height - 8.64) < 0.0001)
        precondition(abs(tip.width / base.width - 0.5) < 0.0001)
        precondition(abs(tip.height / base.height - 0.5) < 0.0001)
        precondition(abs(tip.center.z - 5) < 0.0001)

        // Angled planes fit the true section rather than the overall mesh bounds.
        let rotation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1,2,3)))
        let translation = SIMD3<Float>(43,-25,12)
        let rotated = points.map { rotation.act($0) + translation }
        let normal = rotation.act(SIMD3<Float>(0,0,1))
        let obliqueBase = fit(rotated, translation, normal)
        let origin = rotation.act(SIMD3<Float>(0,0,5)) + translation
        let obliqueTip = fit(rotated, origin, normal)
        precondition(abs(obliqueTip.width / obliqueBase.width - 0.5) < 0.0001)
        precondition(abs(obliqueTip.height / obliqueBase.height - 0.5) < 0.0001)
        precondition(abs(simd_dot(obliqueTip.center - origin, normal)) < 0.0001)
        for point in points.prefix(3) {
            let crossing = rotation.act((point + points[3]) / 2) + translation
            let local = obliqueTip.orientation.inverse.act(crossing - obliqueTip.center)
            precondition(abs(local.x) < obliqueTip.width / 2 && abs(local.y) < obliqueTip.height / 2)
            precondition(abs(local.z) < 0.0001)
        }
        let outside = fit(points, SIMD3(0,0,12), SIMD3(0,0,1))
        precondition(outside.width.isFinite && outside.height.isFinite && outside.center.z == 12)
        let tangent = fit(points, SIMD3(0,0,10), SIMD3(0,0,1))
        precondition(tangent.width == 0.5 && tangent.height == 0.5)
        print("Adaptive cutting-plane preview checks passed.")
    }

    static func main() throws {
        try projectDuplicationChecks()
        try outputResetChecks()
        cuttingPlanePreviewChecks()
        let root = Defaults.packageRoot()
        var project = Defaults.newProject(packageRoot: root, index: 1)
        precondition(!project.settings.inference.usePredictionsForPreprocessing)
        let oldJSON = try JSONEncoder().encode(project)
        let legacy = try JSONDecoder().decode(ProjectRecord.self, from: oldJSON)
        precondition(!legacy.scanPreparation.enabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacySignature = [legacy.leftEar, legacy.rightEar, legacy.inputHandling.rawValue, "", "",
            String(data: try encoder.encode(legacy.settings.inference), encoding: .utf8)!,
            String(data: try encoder.encode(legacy.settings.preprocessing), encoding: .utf8)!, "", "", ""].joined(separator: "\n")
        precondition(ArtifactScanner.preprocessingSignature(for: legacy) == legacySignature)
        var disabledScanProject = legacy
        disabledScanProject.settings.scanPreparation = ScanPreparationSettings()
        precondition(ArtifactScanner.preprocessingSignature(for: disabledScanProject) == legacySignature)

        let temporary = URL(fileURLWithPath: "/private/tmp/pinna-mac-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try ProcessChecks.run(in: temporary)
        let source = temporary.appendingPathComponent("Input/scan.stl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source scan".utf8).write(to: source)
        project.saveLocation = temporary.path
        var scan = ScanPreparationSettings()
        scan.enabled = true
        scan.requireManualReview = false
        scan.scanPath = source.path
        scan.rotationDegrees = "90"
        scan.prepareLeft = false
        project.settings.scanPreparation = scan
        precondition(project.pipelineLeftEar.isEmpty)
        precondition(project.pipelineRightEar.hasSuffix("Prepared/Right.stl"))
        precondition(ProjectValidation.issues(for: project).isEmpty)
        let mapping = PipelineConfigWriter.mapping(project: project, environment: Defaults.environment(root: root))
        let yaml = try ProjectConfigDocument.encode(mapping)
        let parsed = try ProjectConfigDocument.parse(yaml)
        let restored = try ProjectConfigDocument.restore(parsed, into: legacy, folder: URL(fileURLWithPath: project.saveLocation), packageRoot: root)
        precondition(restored.scanPreparation == scan)
        let merged = try ProjectConfigDocument.merged(generated: mapping, preservedJSON: "{\"scan_preparation\":{\"rotation_degrees\":270,\"crop_polygon_xz\":[[0,0],[1,0],[0,1]]}}")
        let preserved = merged["scan_preparation"] as! [String: Any]
        precondition((preserved["rotation_degrees"] as? NSNumber)?.doubleValue == 90)
        precondition(preserved["crop_polygon_xz"] != nil)
        let unexposed = try ProjectConfigDocument.merged(generated: mapping, preservedJSON: "{\"paths\":{\"left_ear\":\"old.stl\"},\"preprocessing\":{\"head_width_scale\":1.7,\"head_radius\":90,\"source_position_input_left\":[1,2,3]}}")
        let unexposedPre = unexposed["preprocessing"] as! [String: Any]
        precondition(unexposedPre["head_width_scale"] as? Double == 1.7)
        precondition(unexposedPre["head_radius"] == nil && unexposedPre["source_position_input_left"] == nil)
        precondition((unexposed["paths"] as! [String: Any])["left_ear"] is NSNull)
        var namedProject = project
        namedProject.name = "Quoted \"project\"\nwith a backslash \\"
        namedProject.settings.preprocessing.maxFrequency = "9007199254740993"
        let namedYAML = try ProjectConfigDocument.encode(PipelineConfigWriter.mapping(project: namedProject, environment: Defaults.environment(root: root)))
        let namedPre = try ProjectConfigDocument.parse(namedYAML)["preprocessing"] as! [String: Any]
        precondition(namedPre["title"] as? String == namedProject.name)
        precondition((namedPre["max_frequency"] as? NSNumber)?.int64Value == 9007199254740993)
        precondition(GeneratedOutputManifest.classify("Prepared/Left.stl") == .scanPreparation)
        precondition(GeneratedOutputManifest.classify("Prepared/mesh_preparation.json") == .scanPreparation)
        precondition(GeneratedOutputManifest.classify("Prepared/inference.json") == .inference)
        precondition(GeneratedOutputManifest.classify("Prepared/preprocessing.json") == .preprocessing)
        precondition(GeneratedOutputManifest.classify("Input/Scan/original.stl") == nil)
        func stamp(_ url: URL) throws -> [String: Any] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return ["size": attrs[.size]!, "mtime": (attrs[.modificationDate] as! Date).timeIntervalSince1970]
        }
        let outputs = try GeneratedOutputManifest(projectRoot: temporary.path, inputs: [source.path])
        try outputs.begin(.scanPreparation)
        let prepared = temporary.appendingPathComponent("Prepared")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        let ear = prepared.appendingPathComponent("Right.stl")
        try Data("validated ear".utf8).write(to: ear)
        let report: [String: Any] = ["status": "completed", "generation": "test",
            "source_identity": try stamp(source), "signature": ["settings": parsed["scan_preparation"]!],
            "ears": ["right": ["identity": try stamp(ear), "sha256": "base"]]]
        try JSONSerialization.data(withJSONObject: report).write(to: prepared.appendingPathComponent("mesh_preparation.json"))
        try outputs.complete()
        precondition(ArtifactScanner.stageIsComplete(.scanPreparation, project: project))
        let preparedRightArtifacts = ArtifactScanner.artifacts(for: project).filter {
            $0.url.standardizedFileURL.path == ear.standardizedFileURL.path
        }
        precondition(preparedRightArtifacts.count == 1)
        precondition(preparedRightArtifacts.first?.title == "Prepared right ear")
        precondition(!ArtifactScanner.stageIsComplete(.preprocessing, project: project))
        let edited = temporary.appendingPathComponent("MeshEdits/Right.stl")
        try FileManager.default.createDirectory(at: edited.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("manual work".utf8).write(to: edited)
        scan.requireManualReview = true
        project.settings.scanPreparation = scan
        precondition(!ArtifactScanner.earReviewIsCurrent(project, side: .right))
        scan.reviewedRightPath = edited.path
        project.settings.scanPreparation = scan
        let review: [String: Any] = ["kind": "ear", "side": "right", "generation": "test",
                                    "source_sha256": "base", "source_identity": try stamp(ear),
                                    "output_identity": try stamp(edited), "output_sha256": "manual"]
        try JSONSerialization.data(withJSONObject: review).write(to: edited.deletingPathExtension().appendingPathExtension("json"))
        precondition(project.pipelineRightEar == edited.path)
        precondition(ArtifactScanner.earReviewIsCurrent(project, side: .right))
        let receiptURL = prepared.appendingPathComponent("inference.json")
        try JSONSerialization.data(withJSONObject: ["generation": "test", "input_ears": ["right": "previous"]]).write(to: receiptURL)
        precondition(!ArtifactScanner.scanReceiptIsCurrent(project, stage: "inference"))
        try JSONSerialization.data(withJSONObject: ["generation": "test", "input_ears": ["right": "manual"]]).write(to: receiptURL)
        precondition(ArtifactScanner.scanReceiptIsCurrent(project, stage: "inference"))
        scan.rotationDegrees = "270"
        project.settings.scanPreparation = scan
        precondition(!ArtifactScanner.stageIsComplete(.scanPreparation, project: project))
        let unrelated = temporary.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        let reset = outputs.reset()
        precondition(reset.success && reset.deleted == 5)
        precondition(FileManager.default.fileExists(atPath: source.path))
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
        precondition(!FileManager.default.fileExists(atPath: edited.path))
        let solver = temporary.appendingPathComponent("solver")
        let sourceFolder = solver.appendingPathComponent("NumCalc/source_1")
        let stepFolder = sourceFolder.appendingPathComponent("be.out/be.1")
        try FileManager.default.createDirectory(at: stepFolder, withIntermediateDirectories: true)
        try Data("{\"numFrequencies\":1}".utf8).write(to: solver.appendingPathComponent("parameters.json"))
        let inspection = ArtifactScanner.Inspection()
        precondition(!ArtifactScanner.numcalcIsComplete(solver, inspection: inspection))
        for name in ["pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"] {
            try Data("result".utf8).write(to: stepFolder.appendingPathComponent(name))
        }
        try Data("---------- NumCalc ended:".utf8).write(to: sourceFolder.appendingPathComponent("NC1-1_log.txt"))
        precondition(!ArtifactScanner.numcalcIsComplete(solver, inspection: inspection))
        precondition(ArtifactScanner.numcalcIsComplete(solver))
        precondition(ArtifactScanner.numcalcCompleted(solver) == 1)
        print("Mac settings, legacy decoding, YAML round-trip, output ownership and freshness checks passed.")
    }
}
