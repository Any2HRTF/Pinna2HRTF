import Foundation

enum PipelineConfigWriter {
    static func prepare(project: ProjectRecord, environment: EnvironmentConfig) throws -> URL {
        let output = URL(fileURLWithPath: project.saveLocation)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manualPositions = Dictionary(uniqueKeysWithValues: EarSide.allCases.compactMap { side in
            ArtifactScanner.validManualMicrophonePosition(for: project, side: side).map { (side, $0) }
        })
        var prepared = project
        if project.inputHandling == .copy {
            if !project.leftEar.isEmpty {
                prepared.leftEar = try copyInput(project.leftEar, to: output.appendingPathComponent("Input/Left"))
            }
            if !project.rightEar.isEmpty {
                prepared.rightEar = try copyInput(project.rightEar, to: output.appendingPathComponent("Input/Right"))
            }
        }
        let configURL = output.appendingPathComponent("Project Settings.yaml")
        try yaml(project: prepared, environment: environment, manualPositions: manualPositions).write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    static func copyInput(_ path: String, to folder: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL.path == target.standardizedFileURL.path {
            return source.path
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target.path
    }

    static func yaml(project: ProjectRecord, environment: EnvironmentConfig, manualPositions: [EarSide: ManualMicrophonePosition]? = nil) -> String {
        let output = URL(fileURLWithPath: project.saveLocation)
        let inference = project.settings.inference
        let preprocessing = project.settings.preprocessing
        let numcalc = project.settings.numcalc
        let postprocessing = project.settings.postprocessing ?? PostprocessingSettings()
        let selectedGrid = preprocessing.evaluationGrid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let evaluationGrid = selectedGrid.isEmpty ? "Default" : selectedGrid
        let useCustomHeadRadius = preprocessing.useCustomHeadRadius ?? (preprocessing.headRadius != nil)
        let headRadius = useCustomHeadRadius ? "  head_radius: \(yamlNumber(preprocessing.headRadius) ?? "0")\n" : ""
        let sourceAssignmentFaceCount = max(Int(preprocessing.sourceAssignmentFaceCount ?? "") ?? 6, 1)
        let frequencyStepCount = max(Int(preprocessing.frequencyStepCount) ?? 129, 2)
        let levelOffsetDB = yamlNumber(postprocessing.levelOffsetDB) ?? "-30"
        let leftEar = project.leftEar.isEmpty ? "null" : yamlString(project.leftEar)
        let rightEar = project.rightEar.isEmpty ? "null" : yamlString(project.rightEar)
        let positions = manualPositions ?? Dictionary(uniqueKeysWithValues: EarSide.allCases.compactMap { side in
            ArtifactScanner.validManualMicrophonePosition(for: project, side: side).map { (side, $0) }
        })
        let sourcePositions = EarSide.allCases.compactMap { side -> String? in
            guard let position = positions[side] else { return nil }
            return "  source_position_input_\(side.rawValue): [\(position.x), \(position.y), \(position.z)]"
        }.joined(separator: "\n")
        let sourcePositionBlock = sourcePositions.isEmpty ? "" : "\(sourcePositions)\n"
        return """
        paths:
          left_ear: \(leftEar)
          right_ear: \(rightEar)
          output_dir: \(yamlString(project.saveLocation))
          external_deps_dir: \(yamlString(environment.externalDir))
          numcalc_executable: \(yamlString(environment.numcalcExecutable))
          mesh_grading_executable: \(yamlString(environment.meshGradingExecutable))
          evaluation_grid: \(yamlString(evaluationGrid))
        inference:
          enabled: true
          model_config_file: \(yamlString(inference.modelConfig))
          model_checkpoint: \(yamlString(inference.modelCheckpoint))
          target_left_folder: \(yamlString(inference.targetLeftFolder))
          target_right_folder: \(yamlString(inference.targetRightFolder))
          prediction_left_folder: \(yamlString(inference.predictionLeftFolder))
          prediction_right_folder: \(yamlString(inference.predictionRightFolder))
          prediction_parameters_left_folder: Intermediates/Left
          prediction_parameters_right_folder: Intermediates/Right
          use_predictions_for_preprocessing: \(inference.usePredictionsForPreprocessing ? "true" : "false")
        preprocessing:
          enabled: true
          write_intermediates: true
          head_radius_scale: 1.01
          head_width_scale: 1.5
          head_height_scale: 1.5
          head_adaptive_ovalness: true
          head_ovalness_strength: 0.08
          head_min_width_scale: 1.48
          head_max_height_scale: 1.53
          head_y_deformation: 0.0
          ear_cut_clearance_scale: 1.3
          ear_cut_mode: ellipse
          projected_cut_margin: 10.0
        \(headRadius)  seam_smoothing_iterations: 5
          seam_smoothing_factor: 0.35
          mesh_min_edge_length: \(preprocessing.meshMinEdgeLength)
          mesh_max_edge_length: \(preprocessing.meshMaxEdgeLength)
          mesh_max_error: \(preprocessing.meshMaxError)
          mesh_gamma: \(preprocessing.meshGamma)
          mesh_gamma_opposite: \(preprocessing.meshGammaOpposite)
          skip_mesh_grading: false
          source_type_left: "Left ear"
          source_type_right: "Right ear"
          title: \(yamlString(project.name))
          method: ML-FMM BEM
          min_frequency: \(preprocessing.minFrequency)
          max_frequency: \(preprocessing.maxFrequency)
          frequency_vector_type: Num steps
          frequency_step_count: \(frequencyStepCount)
          compute_hrirs: true
          pictures: false
          reference: true
          unit: mm
          speed_of_sound: "346.18"
          air_density: "1.1839"
          material_search_paths: None
          source_assignment_tolerance: 2.0
          source_assignment_face_count: \(sourceAssignmentFaceCount)
        \(sourcePositionBlock)numcalc:
          enabled: false
          mode: local
          max_instances: \(numcalc.maxInstances)
          max_cpu_load: \(numcalc.maxCPULoad)
          adaptive_fmm_length: \(numcalc.adaptiveFmmLength ? "true" : "false")
        postprocessing:
          enabled: false
          output_sofa_dir: \(yamlString(output.appendingPathComponent("HRTF").path))
          overwrite: true
          normalize: \(postprocessing.normalize ? "true" : "false")
          level_offset_db: \(levelOffsetDB)
        ui:
          mesh_background: white
          show_axes: true
        """
    }

    static func yamlNumber(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return nil
        }
        guard Double(trimmed) != nil else {
            return nil
        }
        return trimmed
    }

    static func yamlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
