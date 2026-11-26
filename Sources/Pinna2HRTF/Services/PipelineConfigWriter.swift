import Foundation

enum PipelineConfigWriter {
    struct PreparedSettings: Sendable {
        let url: URL
        let revision: String
    }

    static func prepare(project: ProjectRecord, environment: EnvironmentConfig, stage: Stage? = nil) throws -> PreparedSettings {
        try HeadGeometrySettings.validate(project.settings.preprocessing)
        if let issue = ProjectValidation.issues(for: project, stage: stage).first { throw ProjectValidation.Failure(message: issue.message) }

        let output = URL(fileURLWithPath: project.saveLocation)
        let manualPositions = Dictionary(uniqueKeysWithValues: EarSide.allCases.compactMap { side in
            ArtifactScanner.validManualMicrophonePosition(for: project, side: side).map { (side, $0) }
        })
        var prepared = project
        if project.inputHandling == .copy && project.scanPreparation.enabled {
            var scan = project.scanPreparation
            scan.scanPath = try copyInput(scan.scanPath, to: output.appendingPathComponent("Input/Scan"))
            prepared.settings.scanPreparation = scan
        }
        if project.inputHandling == .copy && !project.scanPreparation.enabled {
            if !project.leftEar.isEmpty {
                prepared.leftEar = try copyInput(project.leftEar, to: output.appendingPathComponent("Input/Left"))
            }
            if !project.rightEar.isEmpty {
                prepared.rightEar = try copyInput(project.rightEar, to: output.appendingPathComponent("Input/Right"))
            }
        }
        let configURL = output.appendingPathComponent("Project Settings.yaml")
        let generated = mapping(project: prepared, environment: environment, manualPositions: manualPositions)
        var request: [String: Any] = ["config": generated, "path": configURL.path, "preserve_fields": true, "merge": true]
        if let stage { request["stage"] = stage.rawValue }
        if let revision = project.settingsRevision {
            request["revision"] = revision
        } else if !FileManager.default.fileExists(atPath: configURL.path) {
            request["revision"] = NSNull()
        }
        if let preserved = project.preservedConfigJSON {
            request["preserved"] = try JSONSerialization.jsonObject(with: Data(preserved.utf8))
        }
        struct Reply: Decodable { let revision: String }
        let reply = try JSONDecoder().decode(Reply.self, from: ProjectConfigDocument.request("save", request))
        return PreparedSettings(url: configURL, revision: reply.revision)
    }

    static func copyInput(_ path: String, to folder: URL) throws -> String {
        struct Reply: Decodable { let path: String }
        let response = try ProjectConfigDocument.request("copy-input", ["source": path, "folder": folder.path], timeout: 600)
        return try JSONDecoder().decode(Reply.self, from: response).path
    }

    static func mapping(project: ProjectRecord, environment: EnvironmentConfig, manualPositions: [EarSide: ManualMicrophonePosition]? = nil) -> [String: Any] {
        let scan = project.scanPreparation
        let inference = project.settings.inference
        let manual = project.settings.manualPPMFitting
        let pre = project.settings.preprocessing
        let numcalc = project.settings.numcalc
        let post = project.settings.postprocessing ?? PostprocessingSettings()
        let grid = pre.evaluationGrid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let positions = manualPositions ?? Dictionary(uniqueKeysWithValues: EarSide.allCases.compactMap { side in
            ArtifactScanner.validManualMicrophonePosition(for: project, side: side).map { (side, $0) }
        })
        var preprocessing: [String: Any] = [
            "title": project.name,
            "min_frequency": number(pre.minFrequency),
            "max_frequency": number(pre.maxFrequency),
            "frequency_step_count": number(pre.frequencyStepCount),
            "source_assignment_face_count": number(pre.sourceAssignmentFaceCount),
            "mesh_min_edge_length": number(pre.meshMinEdgeLength),
            "mesh_max_edge_length": number(pre.meshMaxEdgeLength),
            "mesh_max_error": number(pre.meshMaxError),
            "mesh_gamma": number(pre.meshGamma),
            "mesh_gamma_opposite": number(pre.meshGammaOpposite),
            "skip_mesh_grading": false
        ]
        preprocessing["ear_distance"] = pre.earDistance.map { number($0) } ?? NSNull()
        preprocessing["torso_mode"] = pre.torsoMode ?? SettingsCatalog.text("preprocessing.torso_mode")
        for field in PreprocessingSettings.geometryFields {
            if let value = pre[keyPath: field.keyPath] { preprocessing[field.config] = number(value) }
        }
        for side in EarSide.allCases {
            if let position = positions[side] {
                preprocessing["source_position_input_\(side.rawValue)"] = [position.x, position.y, position.z]
            } else if ArtifactScanner.manualMicrophonePosition(for: project, side: side) == nil,
                      project.automaticMicrophoneSides?.contains(side) == true {
                preprocessing["source_position_input_\(side.rawValue)"] = NSNull()
            }
        }
        return [
            "paths": [
                "edited_left_ear": nullable(scan.individualLeftEdit), "edited_right_ear": nullable(scan.individualRightEdit),
                "left_ear": path(project.leftEar), "right_ear": path(project.rightEar),
                "output_dir": project.saveLocation, "external_deps_dir": environment.externalDir,
                "mesh2hrtf_path": environment.effectiveMesh2HRTFPath,
                "numcalc_executable": environment.numcalcExecutable,
                "mesh_grading_executable": environment.meshGradingExecutable,
                "evaluation_grid": grid.isEmpty ? Defaults.evaluationGrid : grid
            ],
            "scan_preparation": [
                "enabled": scan.enabled, "scan_path": path(scan.scanPath), "original_scan_path": nullable(scan.originalScanPath),
                "rotation_degrees": number(scan.rotationDegrees), "require_manual_review": scan.requireManualReview ?? false,
                "reviewed_left": nullable(scan.reviewedLeftPath), "reviewed_right": nullable(scan.reviewedRightPath),
                "prepare_left": scan.prepareLeft, "prepare_right": scan.prepareRight,
                "target_edge_mm": number(scan.targetEdgeMM),
                "left_margin_mm": number(scan.leftMarginMM),
                "right_margin_mm": number(scan.rightMarginMM),
                "side_min_mm": number(scan.sideMinMM),
                "side_max_mm": number(scan.sideMaxMM)
            ],
            "inference": [
                "enabled": inference.usePredictionsForPreprocessing,
                "model_config_file": inference.modelConfig, "model_checkpoint": inference.modelCheckpoint,
                "target_left_folder": inference.targetLeftFolder, "target_right_folder": inference.targetRightFolder,
                "prediction_left_folder": inference.predictionLeftFolder, "prediction_right_folder": inference.predictionRightFolder,
                "use_predictions_for_preprocessing": inference.usePredictionsForPreprocessing
            ],
            "ui": ["ear_model_method": nullable(project.settings.manualPPMFitting.selectedMethod?.rawValue)],
            "manual_ppm": [
                "enabled": manual.useForPreprocessing,
                "left_mesh": nullable(manual.leftMeshPath), "right_mesh": nullable(manual.rightMeshPath),
                "left_parameters": nullable(manual.leftParametersPath), "right_parameters": nullable(manual.rightParametersPath),
                "left_blend": nullable(manual.leftBlendPath), "right_blend": nullable(manual.rightBlendPath),
                "left_source": nullable(manual.leftSourcePath), "right_source": nullable(manual.rightSourcePath),
                "left_source_identity": nullable(manual.leftSourceIdentity), "right_source_identity": nullable(manual.rightSourceIdentity),
                "template_blend": nullable(manual.templateBlendPath)
            ],
            "preprocessing": preprocessing,
            "acoustic_torso": AcousticTorsoSettings.effective(project).payload,
            "numcalc": [
                "enabled": false, "max_instances": number(numcalc.maxInstances),
                "max_cpu_load": number(numcalc.maxCPULoad), "adaptive_fmm_length": numcalc.adaptiveFmmLength
            ],
            "postprocessing": [
                "enabled": false, "overwrite": true,
                "output_sofa_dir": post.outputFolder ?? URL(fileURLWithPath: project.saveLocation).appendingPathComponent("HRTF").path,
                "normalize": post.normalize, "level_offset_db": number(post.levelOffsetDB),
                "resample_hrirs": post.resampleHrirs, "sampling_rate": post.normalizedSamplingRate,
                "spatial_upsampling": post.spatialUpsampling, "spatial_subdivisions": post.spatialSubdivisions,
                "spatial_normalize": post.spatialNormalize
            ]
        ]
    }

    private static func nullable(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func path(_ value: String) -> Any { value.isEmpty ? NSNull() : value as Any }
    private static func number(_ value: String?) -> Any {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let integer = Int(text) { return integer }
        if let number = Double(text), number.isFinite { return number }
        return NSNull()
    }
}
