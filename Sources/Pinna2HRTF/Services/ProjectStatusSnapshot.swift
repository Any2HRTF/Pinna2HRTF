import Foundation

/// Filesystem work for a selected project. Build on a worker queue; rendering only reads the result.
struct ProjectStatusSnapshot {
    let project: ProjectRecord
    let environment: EnvironmentConfig
    let artifacts: [Artifact]
    let states: [Stage: StageState]
    let completed: Set<Stage>
    let unavailableReasons: [Stage: String]
    let issues: [(id: String, message: String)]
    let numcalcStatus: String
    let preprocessingNeedsRerun: Bool
    let fittableSides: Set<EarSide>
    let validFitSides: Set<EarSide>
    let pipelineSides: Set<EarSide>

    static func load(project: ProjectRecord, environment: EnvironmentConfig, projects: [ProjectRecord], placingMicrophone: Bool) -> Self {
        let inspection = ArtifactScanner.Inspection()
        let completed = Set(Stage.allCases.filter { ArtifactScanner.stageIsComplete($0, project: project, inspection: inspection) })
        let states = ArtifactScanner.stageStates(for: project, runningStage: nil, failedStages: [], inspection: inspection)
        let issues = ProjectValidation.issues(for: project, inspection: inspection)
        let signatureURL = URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent(".pinna2hrtf-preprocessing-signature", isDirectory: false)
        var needsRerun = false
        if completed.contains(.preprocessing), !project.saveLocation.isEmpty {
            let signature = ArtifactScanner.preprocessingSignature(for: project, inspection: inspection)
            if let saved = try? String(contentsOf: signatureURL, encoding: .utf8) {
                needsRerun = saved != signature
            } else if !FileManager.default.fileExists(atPath: signatureURL.path) {
                try? signature.write(to: signatureURL, atomically: true, encoding: .utf8)
            }
        }
        var reasons: [Stage: String] = [:]
        for stage in Stage.allCases {
            reasons[stage] = unavailableReason(stage, project: project, environment: environment, projects: projects,
                                               placingMicrophone: placingMicrophone, inspection: inspection, completed: completed)
        }
        let pipelineSides = Set(EarSide.allCases.filter { !project.pipelineEar(for: $0, inspection: inspection).isEmpty })
        let fittable = Set(EarSide.allCases.filter { side in
            guard !project.scanPreparation.enabled || completed.contains(.scanPreparation),
                  let source = ArtifactScanner.sourceEar(for: project, side: side, inspection: inspection),
                  ["stl", "ply"].contains(source.pathExtension.lowercased()) else { return false }
            return FileManager.default.fileExists(atPath: source.path)
        })
        let validFits = Set(EarSide.allCases.filter { ArtifactScanner.validManualPPMFittingMesh(for: project, side: $0, inspection: inspection) != nil })
        let artifacts = ArtifactScanner.artifacts(for: project, inspection: inspection).map { artifact in
            var cached = artifact
            cached.cachedExists = FileManager.default.fileExists(atPath: artifact.url.path)
            return cached
        }
        return Self(project: project, environment: environment, artifacts: artifacts, states: states, completed: completed,
                    unavailableReasons: reasons, issues: issues,
                    numcalcStatus: ArtifactScanner.numcalcStatus(for: project, inspection: inspection),
                    preprocessingNeedsRerun: needsRerun, fittableSides: fittable, validFitSides: validFits, pipelineSides: pipelineSides)
    }

    static func unavailableReason(_ stage: Stage, project: ProjectRecord, environment: EnvironmentConfig,
                                  projects: [ProjectRecord], placingMicrophone: Bool,
                                  inspection: ArtifactScanner.Inspection = .init(), completed: Set<Stage>? = nil) -> String? {
        func isComplete(_ stage: Stage) -> Bool {
            completed?.contains(stage) ?? ArtifactScanner.stageIsComplete(stage, project: project, inspection: inspection)
        }
        if project.pipelineEar(for: .left, inspection: inspection).isEmpty && project.pipelineEar(for: .right, inspection: inspection).isEmpty { return "Choose at least one ear mesh." }
        if project.saveLocation.isEmpty { return "Choose a save location." }
        if project.scanPreparation.enabled && stage != .scanPreparation && (!isComplete(.scanPreparation) || [.failed, .stopped].contains(project.stageOutcomes?[Stage.scanPreparation.rawValue] ?? .ready)) {
            return "Run Scan Preparation successfully with the current scan settings first."
        }
        let requiredInputs = project.scanPreparation.enabled ? [project.scanPreparation.scanPath] : [project.leftEar, project.rightEar]
        for path in requiredInputs where !path.isEmpty {
            if !FileManager.default.fileExists(atPath: path) { return "Input mesh is missing: \(URL(fileURLWithPath: path).lastPathComponent)" }
        }
        if let issue = ProjectValidation.issues(for: project, inspection: inspection).first { return "Fix \(issue.id.split(separator: ".").last?.replacingOccurrences(of: "_", with: " ") ?? "settings"): \(issue.message)" }
        if let conflict = outputLocationConflict(for: project, projects: projects) { return conflict }
        switch stage {
        case .scanPreparation:
            if !project.scanPreparation.enabled { return "Enable full-head scan preparation first." }
        case .inference:
            if !project.settings.inference.usePredictionsForPreprocessing { return "Use Mesh2PPM is turned off." }
            if !FileManager.default.fileExists(atPath: project.settings.inference.modelConfig) || !FileManager.default.fileExists(atPath: project.settings.inference.modelCheckpoint) { return "The selected model or checkpoint is missing." }
        case .preprocessing:
            if project.settings.inference.usePredictionsForPreprocessing && (!isComplete(.inference) || [.failed, .stopped].contains(project.stageOutcomes?[Stage.inference.rawValue] ?? .ready)) { return "Run Mesh2PPM Inference successfully first." }
            if project.settings.manualPPMFitting.useForPreprocessing {
                for side in EarSide.allCases where !(side == .left ? project.pipelineEar(for: .left, inspection: inspection) : project.pipelineEar(for: .right, inspection: inspection)).isEmpty {
                    if let path = project.settings.manualPPMFitting.meshPath(for: side), !path.isEmpty,
                       ArtifactScanner.validManualPPMFittingMesh(for: project, side: side, inspection: inspection) == nil {
                        return "The saved manual \(side.rawValue) PPM fit is missing or its source ear has changed. Refit that ear before preprocessing."
                    }
                }
            }
            if placingMicrophone { return "Finish microphone placement first." }
            if !FileManager.default.isExecutableFile(atPath: environment.meshGradingExecutable) { return "The mesh-grading tool is unavailable." }
            if !FileManager.default.fileExists(atPath: environment.externalDir + "/src/Mesh2HRTF/mesh2hrtf") { return "Mesh2HRTF dependencies are unavailable." }
        case .numcalc:
            if !isComplete(.preprocessing) || [.failed, .stopped].contains(project.stageOutcomes?[Stage.preprocessing.rawValue] ?? .ready) { return "Run preprocessing successfully first." }
            if !FileManager.default.isExecutableFile(atPath: environment.numcalcExecutable) { return "The NumCalc tool is unavailable." }
        case .postprocessing:
            let output = ArtifactScanner.postprocessingDirectory(for: project).standardizedFileURL.resolvingSymlinksInPath().path
            let root = URL(fileURLWithPath: project.saveLocation).standardizedFileURL.resolvingSymlinksInPath().path
            if !output.hasPrefix(root + "/") { return "Choose a SOFA output subfolder inside this project folder." }
            if !isComplete(.numcalc) || [.failed, .stopped].contains(project.stageOutcomes?[Stage.numcalc.rawValue] ?? .ready) { return "Finish NumCalc successfully first." }
        }
        return nil
    }

    static func outputLocationConflict(for project: ProjectRecord, projects: [ProjectRecord]) -> String? {
        guard !project.saveLocation.isEmpty else { return "Choose a save location." }
        let root = URL(fileURLWithPath: project.saveLocation).standardizedFileURL.resolvingSymlinksInPath().path
        for other in projects where other.id != project.id && !other.saveLocation.isEmpty {
            let otherRoot = URL(fileURLWithPath: other.saveLocation).standardizedFileURL.resolvingSymlinksInPath().path
            if root == otherRoot || root.hasPrefix(otherRoot + "/") || otherRoot.hasPrefix(root + "/") {
                return "Choose a separate output folder; this location overlaps \(other.name)."
            }
        }
        return nil
    }

}
