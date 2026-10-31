import Foundation

enum PipelineConfigWriter {
    static func prepare(project: ProjectRecord, environment: EnvironmentConfig, stage: Stage? = nil) throws -> URL {
        try HeadGeometrySettings.validate(project.settings.preprocessing)
        if let issue = ProjectValidation.issues(for: project, stage: stage).first { throw ProjectValidation.Failure(message: issue.message) }

        let output = URL(fileURLWithPath: project.saveLocation)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
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
        let mapping = try project.preservedConfigJSON.map { try ProjectConfigDocument.merged(generated: generated, preservedJSON: $0) } ?? generated
        let document = try ProjectConfigDocument.encode(mapping)
        try document.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    static func copyInput(_ path: String, to folder: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL.path == target.standardizedFileURL.path {
            return source.path
        }
        try FilePublication.publish([(source, target)])
        return target.path
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
            "frequency_step_count": max(Int(pre.frequencyStepCount) ?? 129, 2),
            "source_assignment_face_count": max(Int(pre.sourceAssignmentFaceCount ?? "") ?? 6, 1),
            "mesh_min_edge_length": number(pre.meshMinEdgeLength),
            "mesh_max_edge_length": number(pre.meshMaxEdgeLength),
            "mesh_max_error": number(pre.meshMaxError),
            "mesh_gamma": number(pre.meshGamma),
            "mesh_gamma_opposite": number(pre.meshGammaOpposite),
            "skip_mesh_grading": false
        ]
        if let distance = pre.earDistance {
            preprocessing["ear_distance"] = number(distance)
        }
        for (side, position) in positions {
            preprocessing["source_position_input_\(side.rawValue)"] = [position.x, position.y, position.z]
        }
        // Unexposed settings use the pipeline's defaults; imported overrides are merged separately.
        return [
            "paths": [
                "left_ear": path(project.leftEar), "right_ear": path(project.rightEar),
                "output_dir": project.saveLocation, "external_deps_dir": environment.externalDir,
                "numcalc_executable": environment.numcalcExecutable,
                "mesh_grading_executable": environment.meshGradingExecutable,
                "evaluation_grid": grid.isEmpty ? "Default" : grid
            ],
            "scan_preparation": [
                "enabled": scan.enabled, "scan_path": path(scan.scanPath), "original_scan_path": nullable(scan.originalScanPath),
                "rotation_degrees": number(scan.rotationDegrees), "require_manual_review": false,
                "reviewed_left": nullable(scan.reviewedLeftPath), "reviewed_right": nullable(scan.reviewedRightPath),
                "prepare_left": scan.prepareLeft, "prepare_right": scan.prepareRight,
                "target_edge_mm": number(scan.targetEdgeMM, fallback: 0.75),
                "left_margin_mm": number(scan.leftMarginMM, fallback: 20),
                "right_margin_mm": number(scan.rightMarginMM, fallback: 10),
                "side_min_mm": number(scan.sideMinMM, fallback: 30),
                "side_max_mm": number(scan.sideMaxMM, fallback: 110)
            ],
            "inference": [
                "enabled": inference.usePredictionsForPreprocessing,
                "model_config_file": inference.modelConfig, "model_checkpoint": inference.modelCheckpoint,
                "target_left_folder": inference.targetLeftFolder, "target_right_folder": inference.targetRightFolder,
                "prediction_left_folder": inference.predictionLeftFolder, "prediction_right_folder": inference.predictionRightFolder,
                "use_predictions_for_preprocessing": inference.usePredictionsForPreprocessing
            ],
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
            "numcalc": [
                "enabled": false, "mode": "local", "max_instances": number(numcalc.maxInstances),
                "max_cpu_load": number(numcalc.maxCPULoad), "adaptive_fmm_length": numcalc.adaptiveFmmLength
            ],
            "postprocessing": [
                "enabled": false, "overwrite": true,
                "output_sofa_dir": post.outputFolder ?? URL(fileURLWithPath: project.saveLocation).appendingPathComponent("HRTF").path,
                "normalize": post.normalize, "level_offset_db": number(post.levelOffsetDB, fallback: -30),
                "resample_hrirs": post.resampleHrirs, "sampling_rate": post.normalizedSamplingRate,
                "spatial_upsampling": post.spatialUpsampling, "spatial_subdivisions": post.spatialSubdivisions,
                "spatial_normalize": post.spatialNormalize,
                "matlab_executable": nullable(post.matlabExecutable), "amt_path": nullable(post.amtPath)
            ]
        ]
    }

    private static func nullable(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func path(_ value: String) -> Any { value.isEmpty ? NSNull() : value as Any }
    private static func number(_ value: String?, fallback: Double? = nil) -> Any {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let integer = Int(text) { return integer }
        if let number = Double(text), number.isFinite { return number }
        return fallback.map { $0 as Any } ?? NSNull()

    }
}
