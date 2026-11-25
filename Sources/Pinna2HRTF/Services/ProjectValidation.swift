import Foundation

enum ProjectValidation {
    static func fieldMessage(_ id: String, text: String) -> String? {
        SettingsCatalog.fieldMessage(id, text: text)
    }

    static func formValues(for project: ProjectRecord) -> [String: String] {
        let pre = project.settings.preprocessing
        let post = project.settings.postprocessing ?? PostprocessingSettings()
        let scan = project.scanPreparation
        var values = [
            "mesh2hrtf.min_frequency": pre.minFrequency, "mesh2hrtf.max_frequency": pre.maxFrequency,
            "mesh2hrtf.frequency_steps": pre.frequencyStepCount, "mesh2hrtf.microphone_faces": pre.sourceAssignmentFaceCount ?? "",
            "mesh2hrtf.ear_distance": pre.earDistance ?? "",
            "mesh_grading.min_edge_length": pre.meshMinEdgeLength, "mesh_grading.max_edge_length": pre.meshMaxEdgeLength,
            "mesh_grading.max_error": pre.meshMaxError, "mesh_grading.gamma": pre.meshGamma, "mesh_grading.gamma_opposite": pre.meshGammaOpposite,
            "numcalc.parallel_instances": project.settings.numcalc.maxInstances, "numcalc.cpu_limit": project.settings.numcalc.maxCPULoad,
            "postprocessing.normalize": String(post.normalize), "postprocessing.level_offset": post.levelOffsetDB,
            "postprocessing.resample_hrirs": String(post.resampleHrirs), "postprocessing.sampling_rate": post.samplingRate,
            "postprocessing.spatial_upsampling": String(post.spatialUpsampling), "postprocessing.spatial_subdivisions": String(post.spatialSubdivisions),
            "scan.enabled": String(scan.enabled), "scan.path": scan.scanPath, "scan.rotation": scan.rotationDegrees,
            "scan.prepare_left": String(scan.prepareLeft), "scan.prepare_right": String(scan.prepareRight),
            "scan.target_edge": scan.targetEdgeMM, "scan.left_margin": scan.leftMarginMM, "scan.right_margin": scan.rightMarginMM,
            "scan.side_min": scan.sideMinMM, "scan.side_max": scan.sideMaxMM,
            "ear_model.method": project.workflowMethod?.rawValue ?? ""
        ]
        for field in PreprocessingSettings.headShapeFields {
            values[field.id] = pre[keyPath: field.keyPath] ?? SettingsCatalog.text("preprocessing." + field.config)
        }
        return values
    }

    static func issues(for project: ProjectRecord, stage: Stage? = nil, inspection: ArtifactScanner.Inspection = .init()) -> [(id: String, message: String)] {
        var errors = SettingsCatalog.issues(formValues(for: project), stage: stage)
        let post = project.settings.postprocessing ?? PostprocessingSettings()
        if stage == nil || stage == .postprocessing, post.spatialUpsampling,
           EarSide.allCases.contains(where: { project.pipelineEar(for: $0, inspection: inspection).isEmpty }) {
            errors.append(("postprocessing.spatial_upsampling", "Spatial upsampling requires both left and right ears."))
        }
        if stage == nil || stage == .preprocessing, project.settings.manualPPMFitting.useForPreprocessing {
            for side in project.includedEars where ArtifactScanner.validManualPPMFittingMesh(for: project, side: side, inspection: inspection) == nil {
                errors.append(("manual_ppm.\(side.rawValue)", "Fit the \(side.rawValue) ear: manual mode requires a current saved fit for every included ear."))
            }
        }
        if stage == nil || stage == .inference || stage == .preprocessing {
            for side in EarSide.allCases where !project.pipelineEar(for: side, inspection: inspection).isEmpty {
                if project.scanPreparation.earEdit(side) != nil && !ArtifactScanner.earReviewIsCurrent(project, side: side, inspection: inspection) {
                    errors.append(("ear_edit.\(side.rawValue)", "The saved \(side.rawValue) ear edit is outdated. Edit again or use the original ear in Ear preparation & modelling."))
                }
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
