import Foundation

enum PipelineConfigWriter {
    static func prepare(project: ProjectRecord, environment: EnvironmentConfig) throws -> URL {
        let output = URL(fileURLWithPath: project.saveLocation)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var prepared = project
        if project.inputHandling == .copy {
            prepared.leftEar = try copyInput(project.leftEar, to: output.appendingPathComponent("Input/Left"))
            prepared.rightEar = try copyInput(project.rightEar, to: output.appendingPathComponent("Input/Right"))
        }
        let configURL = output.appendingPathComponent(".pinna2hrtf_native_run.yaml")
        try yaml(project: prepared, environment: environment).write(to: configURL, atomically: true, encoding: .utf8)
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

    static func yaml(project: ProjectRecord, environment: EnvironmentConfig) -> String {
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
        let levelOffsetDB = yamlNumber(postprocessing.levelOffsetDB) ?? "-30"
        return """
        paths:
          left_ear: \(project.leftEar)
          right_ear: \(project.rightEar)
          output_dir: \(project.saveLocation)
          external_deps_dir: \(environment.externalDir)
          numcalc_executable: \(environment.numcalcExecutable)
          mesh_grading_executable: \(environment.meshGradingExecutable)
          evaluation_grid: \(evaluationGrid)
        inference:
          enabled: true
          model_config_file: \(inference.modelConfig)
          model_checkpoint: \(inference.modelCheckpoint)
          target_left_folder: \(inference.targetLeftFolder)
          target_right_folder: \(inference.targetRightFolder)
          prediction_left_folder: \(inference.predictionLeftFolder)
          prediction_right_folder: \(inference.predictionRightFolder)
          prediction_parameters_left_folder: Prediction Parameters Left
          prediction_parameters_right_folder: Prediction Parameters Right
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
          mesh_gamma_left: \(preprocessing.meshGammaLeft)
          mesh_gamma_right: \(preprocessing.meshGammaRight)
          mesh_hole_size: 0.2
          source_type_left: Left ear
          source_type_right: Right ear
          title: \(project.name)
          method: ML-FMM BEM
          min_frequency: \(preprocessing.minFrequency)
          max_frequency: \(preprocessing.maxFrequency)
          frequency_vector_type: Num steps
          frequency_step_count: \(preprocessing.frequencyStepCount)
          compute_hrirs: true
          pictures: false
          reference: true
          unit: mm
          speed_of_sound: "346.18"
          air_density: "1.1839"
          material_search_paths: None
          source_assignment_tolerance: 2.0
          source_assignment_face_count: \(sourceAssignmentFaceCount)
        numcalc:
          enabled: false
          mode: local
          max_instances: \(numcalc.maxInstances)
          max_cpu_load: \(numcalc.maxCPULoad)
        postprocessing:
          enabled: false
          output_sofa_dir: \(output.appendingPathComponent("HRTF").path)
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
}
