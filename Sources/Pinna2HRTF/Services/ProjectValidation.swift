import Foundation

enum ProjectValidation {
    static func fieldMessage(_ id: String, text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let integerIDs = ["mesh2hrtf.min_frequency", "mesh2hrtf.max_frequency", "mesh2hrtf.frequency_steps", "mesh2hrtf.microphone_faces", "numcalc.parallel_instances", "numcalc.cpu_limit", "postprocessing.sampling_rate"]
        if integerIDs.contains(id) {
            guard let number = Int(value) else { return "Enter a whole number." }
            switch id {
            case "mesh2hrtf.min_frequency": return number >= 0 ? nil : "Use 0 Hz or more."
            case "mesh2hrtf.frequency_steps": return number >= 2 ? nil : "Use at least 2 frequency steps."
            case "numcalc.cpu_limit": return (1...100).contains(number) ? nil : "Use a CPU limit from 1 to 100%."
            case "postprocessing.sampling_rate": return number > 0 && number % 10 == 0 ? nil : "Use a positive rate divisible by 10 Hz."
            default: return number > 0 ? nil : "Use a positive whole number."
            }
        }
        let decimalIDs = ["mesh2hrtf.head_radius", "mesh_grading.min_edge_length", "mesh_grading.max_edge_length", "mesh_grading.max_error", "mesh_grading.gamma", "mesh_grading.gamma_opposite", "postprocessing.level_offset"]
        guard decimalIDs.contains(id) else { return nil }
        guard let number = Double(value), number.isFinite else { return "Enter a finite number." }
        if id == "postprocessing.level_offset" { return nil }
        if ["mesh2hrtf.head_radius", "mesh_grading.max_error"].contains(id) { return number >= 0 ? nil : "Use 0 or more." }
        return number > 0 ? nil : "Use a number greater than 0."
    }

    static func issues(for project: ProjectRecord, inspection: ArtifactScanner.Inspection = .init()) -> [(id: String, message: String)] {
        let pre = project.settings.preprocessing
        let post = project.settings.postprocessing ?? PostprocessingSettings()
        var fields: [(String, String)] = [
            ("mesh2hrtf.min_frequency", pre.minFrequency), ("mesh2hrtf.max_frequency", pre.maxFrequency),
            ("mesh2hrtf.frequency_steps", pre.frequencyStepCount), ("mesh2hrtf.microphone_faces", pre.sourceAssignmentFaceCount ?? "6"),
            ("mesh_grading.min_edge_length", pre.meshMinEdgeLength), ("mesh_grading.max_edge_length", pre.meshMaxEdgeLength),
            ("mesh_grading.max_error", pre.meshMaxError), ("mesh_grading.gamma", pre.meshGamma), ("mesh_grading.gamma_opposite", pre.meshGammaOpposite),
            ("numcalc.parallel_instances", project.settings.numcalc.maxInstances), ("numcalc.cpu_limit", project.settings.numcalc.maxCPULoad)
        ]
        if pre.useCustomHeadRadius ?? (pre.headRadius != nil) { fields.append(("mesh2hrtf.head_radius", pre.headRadius ?? "")) }
        if post.normalize { fields.append(("postprocessing.level_offset", post.levelOffsetDB)) }
        if post.resampleHrirs { fields.append(("postprocessing.sampling_rate", post.samplingRate)) }
        var errors = fields.compactMap { id, value in fieldMessage(id, text: value).map { (id: id, message: $0) } }
        if post.spatialUpsampling {
            if !(0...5).contains(post.spatialSubdivisions) { errors.append(("postprocessing.spatial_subdivisions", "Choose a subdivision level from 0 to 5.")) }
            if EarSide.allCases.contains(where: { project.pipelineEar(for: $0, inspection: inspection).isEmpty }) {
                errors.append(("postprocessing.spatial_upsampling", "Spatial upsampling requires both left and right ears."))
            }
        }
        if let min = Int(pre.minFrequency), let max = Int(pre.maxFrequency), max <= min {
            errors.append(("mesh2hrtf.max_frequency", "Max frequency must be greater than min frequency."))
        }
        if let min = Double(pre.meshMinEdgeLength), let max = Double(pre.meshMaxEdgeLength), max < min {
            errors.append(("mesh_grading.max_edge_length", "Max edge length must be at least the min edge length."))
        }
        if project.settings.manualPPMFitting.useForPreprocessing {
            var hasValidFit = false
            for side in EarSide.allCases where !(side == .left ? project.pipelineLeftEar : project.pipelineRightEar).isEmpty {
                guard let path = project.settings.manualPPMFitting.meshPath(for: side), !path.isEmpty else { continue }
                if ArtifactScanner.validManualPPMFittingMesh(for: project, side: side, inspection: inspection) != nil {
                    hasValidFit = true
                } else {
                    errors.append(("manual_ppm.\(side.rawValue)", "The saved \(side.rawValue) PPM fit is missing or no longer matches its source ear."))
                }
            }
            if !hasValidFit {
                errors.append(("manual_ppm.fit", "Fit at least one ear with the manual PPM editor before selecting manual preprocessing."))
            }
        }
        let scan = project.scanPreparation
        if scan.enabled {
            if scan.scanPath.isEmpty { errors.append(("scan.path", "Choose a full-head scan.")) }
            if !scan.prepareLeft && !scan.prepareRight { errors.append(("scan.sides", "Select at least one ear.")) }
            let fields = [("rotation", scan.rotationDegrees, -Double.infinity), ("target_edge", scan.targetEdgeMM, 0.0),
                          ("left_margin", scan.leftMarginMM, -0.001), ("right_margin", scan.rightMarginMM, -0.001),
                          ("side_min", scan.sideMinMM, -0.001), ("side_max", scan.sideMaxMM, 0.0)]
            for (key, value, minimum) in fields {
                if let number = Double(value), number.isFinite, number > minimum { continue }
                errors.append(("scan.\(key)", "Enter a valid finite \(key.replacingOccurrences(of: "_", with: " ")) value."))
            }
            if let minimum = Double(scan.sideMinMM), let maximum = Double(scan.sideMaxMM), minimum >= maximum {
                errors.append(("scan.side_max", "Outer crop limit must exceed inner crop limit."))
            }
        }
        return errors
    }

    static func validate(_ project: ProjectRecord) throws {
        if let issue = issues(for: project).first { throw Failure(message: issue.message) }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
