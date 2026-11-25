import Foundation

enum ProjectConfigDocument {
    struct SettingsRevisionConflict: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Settings {
        let config: [String: Any]
        let revision: String
        let microphonePlacements: [String: String]
    }
    static var pythonURL: URL? {
        let bundled = Defaults.pipelineRoot.appendingPathComponent(".venv/bin/python")
        if Defaults.isPackagedApp { return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil }
        let source = Defaults.packageRoot().appendingPathComponent(".venv/bin/python")
        for candidate in [bundled, source] where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        let installed = URL(fileURLWithPath: "/Applications/Pinna2HRTF.app/Contents/Resources/.venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { return nil }
        NSLog("Pinna2HRTF: no source-tree Python environment at %@ (run Set Up Python); falling back to %@", source.path, installed.path)
        return installed
    }

    static func run(_ arguments: [String], input: Data, timeout: TimeInterval = 60, operation: String = "Python operation") throws -> Data {
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
        process.arguments = ["-B"] + arguments
        process.currentDirectoryURL = Defaults.pipelineRoot
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try ProcessLauncher.shared.launch(process)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            ProcessTreeTerminator.terminate(process)
            throw ProjectValidation.Failure(message: "\(operation) took longer than \(Int(timeout)) seconds and was stopped.")
        }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            let reply = detail.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if reply?["error"] as? String == "SettingsRevisionConflict" {
                throw SettingsRevisionConflict(message: reply?["message"] as? String ?? detail)
            }
            throw ProjectValidation.Failure(message: "\(operation) failed: \(detail)")
        }
        return try Data(contentsOf: outputURL)
    }

    static func request(_ action: String, _ payload: [String: Any], timeout: TimeInterval = 60) throws -> Data {
        try run(["-m", "HRTFCalculation", "project", action], input: JSONSerialization.data(withJSONObject: payload),
                timeout: timeout, operation: action)
    }

    static func read(_ url: URL) throws -> Settings {
        let data = try request("read", ["path": url.path, "with_revision": true])
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = reply["config"] as? [String: Any], let revision = reply["revision"] as? String else {
            throw ProjectValidation.Failure(message: "Project settings must contain a mapping.")
        }
        return Settings(config: config, revision: revision, microphonePlacements: reply["microphone_placements"] as? [String: String] ?? [:])
    }

    static func restore(_ settings: Settings, into original: ProjectRecord, folder: URL, packageRoot: URL) throws -> ProjectRecord {
        let config = settings.config
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
        restoredScan.originalScanPath = text(scan, "original_scan_path").map(relocated)
        restoredScan.rotationDegrees = text(scan, "rotation_degrees") ?? SettingsCatalog.text("scan_preparation.rotation_degrees")
        restoredScan.requireManualReview = bool(scan, "require_manual_review") ?? SettingsCatalog.flag("scan_preparation.require_manual_review")
        restoredScan.individualLeftEdit = text(paths, "edited_left_ear").map(relocated)
        restoredScan.individualRightEdit = text(paths, "edited_right_ear").map(relocated)
        restoredScan.reviewedLeftPath = text(scan, "reviewed_left").map(relocated)
        restoredScan.reviewedRightPath = text(scan, "reviewed_right").map(relocated)
        restoredScan.prepareLeft = bool(scan, "prepare_left") ?? SettingsCatalog.flag("scan_preparation.prepare_left")
        restoredScan.prepareRight = bool(scan, "prepare_right") ?? SettingsCatalog.flag("scan_preparation.prepare_right")
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
                if FileManager.default.fileExists(atPath: path) || (side == .left ? project.leftEar : project.rightEar).isEmpty {
                    if side == .left { project.leftEar = path } else { project.rightEar = path }
                }
            }
        }
        func modelPath(_ key: String, fallback: String) -> String {
            guard let value = text(inference, key) else { return fallback }
            let local = packageRoot.appendingPathComponent("HRTFCalculation/Inference/resources").appendingPathComponent(URL(fileURLWithPath: value).lastPathComponent)
            let path = relocated(value)
            if key == "model_checkpoint" {
                let bundled = Defaults.bundledModelCheckpoint(value, resources: packageRoot.appendingPathComponent("HRTFCalculation/Inference/resources"))
                if FileManager.default.fileExists(atPath: bundled.path),
                   !FileManager.default.fileExists(atPath: path) || value.contains("HRTFCalculation/Inference/resources/") {
                    return bundled.path
                }
            }
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
        if let ui = config["ui"] as? [String: Any], let raw = ui["ear_model_method"] as? String, let method = EarModelMethod(rawValue: raw) {
            project.settings.selectEarModel(method)
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
        project.settings.preprocessing.evaluationGrid = text(paths, "evaluation_grid").map {
            $0 == Defaults.evaluationGrid ? $0 : relocated($0)
        }
        project.settings.preprocessing.earDistance = text(pre, "ear_distance") ?? text(pre, "head_radius")
        project.settings.preprocessing.torsoMode = text(pre, "torso_mode") ?? SettingsCatalog.text("preprocessing.torso_mode")
        for field in PreprocessingSettings.geometryFields {
            project.settings.preprocessing[keyPath: field.keyPath] = text(pre, field.config)
        }
        project.settings.preprocessing.sourceAssignmentFaceCount = text(pre, "source_assignment_face_count") ?? SettingsCatalog.text("preprocessing.source_assignment_face_count")
        for side in EarSide.allCases {
            var position: ManualMicrophonePosition?
            if settings.microphonePlacements[side.rawValue] != "stale",
               let coordinates = pre["source_position_input_\(side.rawValue)"] as? [NSNumber], coordinates.count == 3,
               let mesh = ArtifactScanner.preprocessingMesh(for: project, side: side), let identity = ArtifactScanner.meshIdentity(mesh) {
                position = ManualMicrophonePosition(x: coordinates[0].doubleValue, y: coordinates[1].doubleValue, z: coordinates[2].doubleValue, meshPath: mesh.standardizedFileURL.path, meshIdentity: identity)
            }
            if side == .left { project.settings.preprocessing.sourcePositionInputLeft = position } else { project.settings.preprocessing.sourcePositionInputRight = position }
        }
        project.automaticMicrophoneSides = nil
        project.settings.numcalc.maxInstances = text(num, "max_instances") ?? SettingsCatalog.text("numcalc.max_instances")
        project.settings.numcalc.maxCPULoad = text(num, "max_cpu_load") ?? SettingsCatalog.text("numcalc.max_cpu_load")
        project.settings.numcalc.adaptiveFmmLength = bool(num, "adaptive_fmm_length") ?? SettingsCatalog.flag("numcalc.adaptive_fmm_length")
        var restoredPost = PostprocessingSettings()
        if let value = bool(post, "normalize") { restoredPost.normalize = value }
        if let value = text(post, "level_offset_db") { restoredPost.levelOffsetDB = value }
        if let value = bool(post, "resample_hrirs") { restoredPost.resampleHrirs = value }
        if let value = text(post, "sampling_rate") { restoredPost.samplingRate = value }
        if let value = bool(post, "spatial_upsampling") { restoredPost.spatialUpsampling = value }
        if let value = text(post, "spatial_subdivisions").flatMap({ Int($0) }) { restoredPost.spatialSubdivisions = value }
        if let value = bool(post, "spatial_normalize") { restoredPost.spatialNormalize = value }
        restoredPost.matlabExecutable = text(post, "matlab_executable").map(relocated)
        restoredPost.amtPath = text(post, "amt_path").map(relocated)
        restoredPost.outputFolder = text(post, "output_sofa_dir").map(relocated)
        project.settings.postprocessing = restoredPost
        project.preservedConfigJSON = String(data: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), encoding: .utf8)
        return project
    }
}
