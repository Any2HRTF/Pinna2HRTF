import Foundation

// Use the same safe YAML parser as the bundled pipeline; never interpret a config as code.
enum ProjectConfigDocument {
    static var pythonURL: URL? {
        let bundled = Defaults.pipelineRoot.appendingPathComponent(".venv/bin/python")
        if Defaults.isPackagedApp { return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil }
        return [bundled, Defaults.packageRoot().appendingPathComponent(".venv/bin/python"), URL(fileURLWithPath: "/Applications/Pinna2HRTF.app/Contents/Resources/.venv/bin/python")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func runPython(_ script: String, input: Data, arguments: [String] = []) throws -> Data {
        guard let pythonURL else { throw ProjectValidation.Failure(message: "The bundled Python runtime is unavailable.") }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("pinna-config-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let inputURL = temporary.appendingPathComponent("input")
        let outputURL = temporary.appendingPathComponent("output")
        let errorURL = temporary.appendingPathComponent("error")
        try input.write(to: inputURL)
        fm.createFile(atPath: outputURL.path, contents: nil)
        fm.createFile(atPath: errorURL.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? inputHandle.close(); try? outputHandle.close(); try? errorHandle.close() }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-B", "-c", script] + arguments
        process.currentDirectoryURL = Defaults.pipelineRoot
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw ProjectValidation.Failure(message: "Could not read or validate project data: \(detail)")
        }
        return try Data(contentsOf: outputURL)
    }

    static func parse(_ yaml: String) throws -> [String: Any] {
        let data = try runPython("""
        import sys, json, yaml
        value = yaml.safe_load(sys.stdin.read())
        if not isinstance(value, dict):
            raise ValueError('Project settings must contain a YAML mapping.')
        print(json.dumps(value, allow_nan=False))
        """, input: Data(yaml.utf8))
        guard let mapping = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectValidation.Failure(message: "Project settings must contain a mapping.")
        }
        return mapping
    }

    static func encode(_ mapping: [String: Any]) throws -> String {
        let output = try runPython("""
        import sys, json, yaml
        print(yaml.safe_dump(json.load(sys.stdin), sort_keys=False), end='')
        """, input: JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys]))
        guard let yaml = String(data: output, encoding: .utf8) else { throw ProjectValidation.Failure(message: "Could not encode project settings.") }
        return yaml
    }

    static func merged(generated current: [String: Any], preservedJSON: String) throws -> [String: Any] {
        guard var saved = try JSONSerialization.jsonObject(with: Data(preservedJSON.utf8)) as? [String: Any] else {
            throw ProjectValidation.Failure(message: "The imported settings snapshot is unreadable.")
        }
        let editable: [String: [String]] = [
            "scan_preparation": ["enabled", "scan_path", "rotation_degrees", "prepare_left", "prepare_right", "target_edge_mm", "left_margin_mm", "right_margin_mm", "side_min_mm", "side_max_mm", "require_manual_review", "reviewed_left", "reviewed_right"],
            "paths": ["left_ear", "right_ear", "output_dir", "external_deps_dir", "numcalc_executable", "mesh_grading_executable", "evaluation_grid"],
            "inference": ["model_config_file", "model_checkpoint", "target_left_folder", "target_right_folder", "prediction_left_folder", "prediction_right_folder", "use_predictions_for_preprocessing"],
            "manual_ppm": ["enabled", "left_mesh", "right_mesh", "left_parameters", "right_parameters", "left_blend", "right_blend", "left_source", "right_source", "left_source_identity", "right_source_identity", "template_blend"],
            "preprocessing": ["title", "head_radius", "min_frequency", "max_frequency", "frequency_step_count", "source_assignment_face_count", "source_position_input_left", "source_position_input_right", "mesh_min_edge_length", "mesh_max_edge_length", "mesh_max_error", "mesh_gamma", "mesh_gamma_opposite", "skip_mesh_grading"],
            "numcalc": ["max_instances", "max_cpu_load", "adaptive_fmm_length"],
            "postprocessing": ["output_sofa_dir", "normalize", "level_offset_db", "resample_hrirs", "sampling_rate"]
        ]
        for (section, keys) in editable {
            var values = saved[section] as? [String: Any] ?? current[section] as? [String: Any] ?? [:]
            let generatedValues = current[section] as? [String: Any] ?? [:]
            for key in keys {
                if let value = generatedValues[key] { values[key] = value } else { values.removeValue(forKey: key) }
            }
            saved[section] = values
        }
        return saved
    }

    static func restore(_ config: [String: Any], into original: ProjectRecord, folder: URL, packageRoot: URL) throws -> ProjectRecord {
        var project = original
        let paths = config["paths"] as? [String: Any] ?? [:]
        let inference = config["inference"] as? [String: Any] ?? [:]
        let manualPPM = config["manual_ppm"] as? [String: Any] ?? [:]
        let pre = config["preprocessing"] as? [String: Any] ?? [:]
        let num = config["numcalc"] as? [String: Any] ?? [:]
        let post = config["postprocessing"] as? [String: Any] ?? [:]
        func text(_ mapping: [String: Any], _ key: String) -> String? {
            if let string = mapping[key] as? String { return string }
            if let number = mapping[key] as? NSNumber { return number.stringValue }
            return nil
        }
        func bool(_ mapping: [String: Any], _ key: String) -> Bool? { mapping[key] as? Bool }
        let oldRoot = text(paths, "output_dir") ?? ""
        func relocated(_ value: String) -> String {
            guard !value.isEmpty else { return value }
            if value == "Default" { return value }
            if !oldRoot.isEmpty, value == oldRoot || value.hasPrefix(oldRoot + "/") {
                return folder.path + String(value.dropFirst(oldRoot.count))
            }
            if !value.hasPrefix("/") { return folder.appendingPathComponent(value).standardizedFileURL.path }
            return value
        }
        func relocatedIdentity(_ value: String?) -> String? {
            guard let value, let separator = value.firstIndex(of: "|") else { return value }
            let originalPath = String(value[..<separator])
            return relocated(originalPath) + String(value[separator...])
        }
        let scan = config["scan_preparation"] as? [String: Any] ?? [:]
        var restoredScan = ScanPreparationSettings()
        restoredScan.enabled = bool(scan, "enabled") ?? false
        restoredScan.scanPath = text(scan, "scan_path").map(relocated) ?? ""
        restoredScan.rotationDegrees = text(scan, "rotation_degrees") ?? "0"
        restoredScan.requireManualReview = bool(scan, "require_manual_review") ?? false
        restoredScan.reviewedLeftPath = text(scan, "reviewed_left").map(relocated)
        restoredScan.reviewedRightPath = text(scan, "reviewed_right").map(relocated)
        restoredScan.prepareLeft = bool(scan, "prepare_left") ?? true
        restoredScan.prepareRight = bool(scan, "prepare_right") ?? true
        let scanKeys: [(String, WritableKeyPath<ScanPreparationSettings, String>)] = [
            ("target_edge_mm", \.targetEdgeMM), ("left_margin_mm", \.leftMarginMM),
            ("right_margin_mm", \.rightMarginMM), ("side_min_mm", \.sideMinMM), ("side_max_mm", \.sideMaxMM)]
        for (key, path) in scanKeys { if let value = text(scan, key) { restoredScan[keyPath: path] = value } }
        project.settings.scanPreparation = restoredScan
        if let name = text(pre, "title"), !name.isEmpty { project.name = name }
        for (key, side) in [("left_ear", EarSide.left), ("right_ear", EarSide.right)] {
            if paths[key] is NSNull {
                if side == .left { project.leftEar = "" } else { project.rightEar = "" }
            } else if let value = text(paths, key) {
                let path = relocated(value)
                // If copied input data exists, prefer the portable in-project copy over a missing original path.
                if FileManager.default.fileExists(atPath: path) || (side == .left ? project.leftEar : project.rightEar).isEmpty {
                    if side == .left { project.leftEar = path } else { project.rightEar = path }
                }
            }
        }
        func modelPath(_ key: String, fallback: String) -> String {
            guard let value = text(inference, key) else { return fallback }
            let local = packageRoot.appendingPathComponent("HRTFCalculation/Inference/resources").appendingPathComponent(URL(fileURLWithPath: value).lastPathComponent)
            let path = relocated(value)
            if FileManager.default.fileExists(atPath: path) { return path }
            return FileManager.default.fileExists(atPath: local.path) ? local.path : path
        }
        project.settings.inference.modelConfig = modelPath("model_config_file", fallback: project.settings.inference.modelConfig)
        project.settings.inference.modelCheckpoint = modelPath("model_checkpoint", fallback: project.settings.inference.modelCheckpoint)
        project.settings.inference.usePredictionsForPreprocessing = bool(inference, "use_predictions_for_preprocessing") ?? bool(inference, "enabled") ?? false
        var restoredManualPPM = ManualPPMFittingSettings()
        restoredManualPPM.useForPreprocessing = bool(manualPPM, "enabled") ?? false
        restoredManualPPM.leftMeshPath = text(manualPPM, "left_mesh").map(relocated)
        restoredManualPPM.rightMeshPath = text(manualPPM, "right_mesh").map(relocated)
        restoredManualPPM.leftParametersPath = text(manualPPM, "left_parameters").map(relocated)
        restoredManualPPM.rightParametersPath = text(manualPPM, "right_parameters").map(relocated)
        restoredManualPPM.leftBlendPath = text(manualPPM, "left_blend").map(relocated)
        restoredManualPPM.rightBlendPath = text(manualPPM, "right_blend").map(relocated)
        restoredManualPPM.leftSourcePath = text(manualPPM, "left_source").map(relocated)
        restoredManualPPM.rightSourcePath = text(manualPPM, "right_source").map(relocated)
        restoredManualPPM.leftSourceIdentity = relocatedIdentity(text(manualPPM, "left_source_identity"))
        restoredManualPPM.rightSourceIdentity = relocatedIdentity(text(manualPPM, "right_source_identity"))
        restoredManualPPM.templateBlendPath = text(manualPPM, "template_blend").map(relocated)
        project.settings.manualPPMFitting = restoredManualPPM
        if restoredManualPPM.useForPreprocessing {
            project.settings.inference.usePredictionsForPreprocessing = false
        }
        let inferenceKeys: [(String, WritableKeyPath<InferenceSettings, String>)] = [
            ("target_left_folder", \.targetLeftFolder), ("target_right_folder", \.targetRightFolder),
            ("prediction_left_folder", \.predictionLeftFolder), ("prediction_right_folder", \.predictionRightFolder)
        ]
        for (key, path) in inferenceKeys { if let value = text(inference, key) { project.settings.inference[keyPath: path] = value } }
        let preprocessingKeys: [(String, WritableKeyPath<PreprocessingSettings, String>)] = [
            ("min_frequency", \.minFrequency), ("max_frequency", \.maxFrequency), ("frequency_step_count", \.frequencyStepCount),
            ("mesh_min_edge_length", \.meshMinEdgeLength), ("mesh_max_edge_length", \.meshMaxEdgeLength),
            ("mesh_max_error", \.meshMaxError), ("mesh_gamma", \.meshGamma), ("mesh_gamma_opposite", \.meshGammaOpposite)
        ]
        for (key, path) in preprocessingKeys { if let value = text(pre, key) { project.settings.preprocessing[keyPath: path] = value } }
        project.settings.preprocessing.evaluationGrid = text(paths, "evaluation_grid").map(relocated)
        project.settings.preprocessing.headRadius = text(pre, "head_radius")
        project.settings.preprocessing.useCustomHeadRadius = project.settings.preprocessing.headRadius != nil
        project.settings.preprocessing.sourceAssignmentFaceCount = text(pre, "source_assignment_face_count") ?? "6"
        for side in EarSide.allCases {
            if let coordinates = pre["source_position_input_\(side.rawValue)"] as? [NSNumber], coordinates.count == 3,
               let mesh = ArtifactScanner.preprocessingMesh(for: project, side: side), let identity = ArtifactScanner.meshIdentity(mesh) {
                let position = ManualMicrophonePosition(x: coordinates[0].doubleValue, y: coordinates[1].doubleValue, z: coordinates[2].doubleValue, meshPath: mesh.standardizedFileURL.path, meshIdentity: identity)
                if side == .left { project.settings.preprocessing.sourcePositionInputLeft = position } else { project.settings.preprocessing.sourcePositionInputRight = position }
            }
        }
        project.settings.numcalc.maxInstances = text(num, "max_instances") ?? "1"
        project.settings.numcalc.maxCPULoad = text(num, "max_cpu_load") ?? "90"
        project.settings.numcalc.adaptiveFmmLength = bool(num, "adaptive_fmm_length") ?? true
        var restoredPost = PostprocessingSettings()
        restoredPost.normalize = bool(post, "normalize") ?? true
        restoredPost.levelOffsetDB = text(post, "level_offset_db") ?? "-30"
        restoredPost.resampleHrirs = bool(post, "resample_hrirs") ?? false
        restoredPost.samplingRate = text(post, "sampling_rate") ?? "48000"
        restoredPost.outputFolder = text(post, "output_sofa_dir").map(relocated)
        project.settings.postprocessing = restoredPost
        project.preservedConfigJSON = String(data: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), encoding: .utf8)
        return project
    }
}
