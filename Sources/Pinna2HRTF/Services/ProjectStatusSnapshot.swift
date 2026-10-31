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
    let checkingSolverResults: Bool

    /// Configured paths can be offered before directory discovery completes.
    /// Opening a preview still validates and loads the actual file.
    static func configuredPreviewArtifacts(for project: ProjectRecord) -> [Artifact] {
        var files: [Artifact] = []
        if project.scanPreparation.enabled {
            if !project.scanPreparation.scanPath.isEmpty {
                files.append(Artifact(title: "Full-head scan", url: URL(fileURLWithPath: project.scanPreparation.scanPath, isDirectory: false), cachedExists: true))
            }
        } else {
            for (title, path) in [("Input left ear", project.leftEar), ("Input right ear", project.rightEar)] where !path.isEmpty {
                files.append(Artifact(title: title, url: URL(fileURLWithPath: path, isDirectory: false), cachedExists: true))
            }
        }
        for side in EarSide.allCases {
            if let path = project.settings.manualPPMFitting.meshPath(for: side), !path.isEmpty {
                files.append(Artifact(title: "Manual \(side.rawValue) PPM fit", url: URL(fileURLWithPath: path, isDirectory: false), cachedExists: true))
            }
        }
        return files
    }

    var summary: String {
        if project.stageOutcomes?.values.contains(.failed) == true { return "Latest run failed · previous results may remain" }
        if project.stageOutcomes?.values.contains(.stopped) == true { return "Task stopped · previous results may remain" }
        if completed.contains(.postprocessing) { return "Postprocessed" }
        if completed.contains(.numcalc) { return "Solved" }
        if completed.contains(.preprocessing) { return "Projects ready" }
        if project.settings.inference.usePredictionsForPreprocessing && completed.contains(.inference) { return "Mesh2PPM Inference ready" }
        return Self.savedSummary(for: project)
    }

    static func savedSummary(for project: ProjectRecord) -> String {
        if project.stageOutcomes?.values.contains(.failed) == true { return "Latest run failed · previous results may remain" }
        if project.stageOutcomes?.values.contains(.stopped) == true { return "Task stopped · previous results may remain" }
        if project.stageOutcomes?[Stage.postprocessing.rawValue] == .done { return "Postprocessed" }
        if project.stageOutcomes?[Stage.numcalc.rawValue] == .done { return "Solved" }
        if project.stageOutcomes?[Stage.preprocessing.rawValue] == .done { return "Projects ready" }
        return URL(fileURLWithPath: project.saveLocation, isDirectory: true).lastPathComponent
    }

    static func load(project: ProjectRecord, environment: EnvironmentConfig, projects: [ProjectRecord], placingMicrophone: Bool,
                     includeSolverResults: Bool = true, isCancelled: @escaping () -> Bool = { false }) -> Self {
        let inspection = ArtifactScanner.Inspection(isCancelled: isCancelled)
        let completed = Set(Stage.allCases.filter { (includeSolverResults || $0 != .numcalc) && !isCancelled() && ArtifactScanner.stageIsComplete($0, project: project, inspection: inspection) })
        let states = ArtifactScanner.stageStates(for: project, runningStage: nil, failedStages: [], inspection: inspection, completedStages: completed)
        let issues = ProjectValidation.issues(for: project, inspection: inspection)
        let signatureURL = URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent(".pinna2hrtf-preprocessing-signature", isDirectory: false)
        var needsRerun = false
        if completed.contains(.preprocessing), !project.saveLocation.isEmpty {
            let signature = ArtifactScanner.preprocessingSignature(for: project, inspection: inspection)
            if let saved = try? String(contentsOf: signatureURL, encoding: .utf8) {
                needsRerun = !PreprocessingSignature.matches(saved, project: project, current: signature, inspection: inspection)
                if !needsRerun && saved != signature {
                    try? signature.write(to: signatureURL, atomically: true, encoding: .utf8)
                }
            } else if !FileManager.default.fileExists(atPath: signatureURL.path) {
                needsRerun = true
            }
        }
        var reasons: [Stage: String] = [:]
        for stage in Stage.allCases {
            reasons[stage] = unavailableReason(stage, project: project, environment: environment, projects: projects,
                                               placingMicrophone: placingMicrophone, inspection: inspection, completed: completed, resolveOutputLocations: false)
        }
        if needsRerun {
            for stage in [Stage.numcalc, .postprocessing] { reasons[stage] = "Run preprocessing with the current settings first." }
        }
        if !includeSolverResults { reasons[.postprocessing] = "Checking solver results…" }
        let pipelineSides = Set(EarSide.allCases.filter { !project.pipelineEar(for: $0, inspection: inspection).isEmpty })
        let fittable = Set(EarSide.allCases.filter { side in
            guard !project.scanPreparation.enabled || completed.contains(.scanPreparation),
                  let source = ArtifactScanner.sourceEar(for: project, side: side, inspection: inspection),
                  ["stl", "ply"].contains(source.pathExtension.lowercased()) else { return false }
            return FileManager.default.fileExists(atPath: source.path)
        })
        let validFits = Set(EarSide.allCases.filter { ArtifactScanner.validManualPPMFittingMesh(for: project, side: $0, inspection: inspection) != nil })
        let artifacts = ArtifactScanner.artifacts(for: project, inspection: inspection, includeSolverResults: includeSolverResults).map { artifact in
            var cached = artifact
            cached.cachedExists = FileManager.default.fileExists(atPath: artifact.url.path)
            return cached
        }
        return Self(project: project, environment: environment, artifacts: artifacts, states: states, completed: completed,
                    unavailableReasons: reasons, issues: issues,
                    numcalcStatus: includeSolverResults ? ArtifactScanner.numcalcStatus(for: project, inspection: inspection) : "NumCalc: checking results…",
                    preprocessingNeedsRerun: needsRerun, fittableSides: fittable, validFitSides: validFits, pipelineSides: pipelineSides, checkingSolverResults: !includeSolverResults)
    }

    static func unavailableReason(_ stage: Stage, project: ProjectRecord, environment: EnvironmentConfig,
                                  projects: [ProjectRecord], placingMicrophone: Bool,
                                  inspection: ArtifactScanner.Inspection = .init(), completed: Set<Stage>? = nil,
                                  resolveOutputLocations: Bool = true) -> String? {
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
        if let issue = ProjectValidation.issues(for: project, stage: stage, inspection: inspection).first { return "Fix \(issue.id.split(separator: ".").last?.replacingOccurrences(of: "_", with: " ") ?? "settings"): \(issue.message)" }
        if let conflict = outputLocationConflict(for: project, projects: projects, resolvingSymlinks: resolveOutputLocations) { return conflict }
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
            let outputURL = ArtifactScanner.postprocessingDirectory(for: project).standardizedFileURL
            let rootURL = URL(fileURLWithPath: project.saveLocation, isDirectory: true).standardizedFileURL
            let output = (resolveOutputLocations ? outputURL.resolvingSymlinksInPath() : outputURL).path
            let root = (resolveOutputLocations ? rootURL.resolvingSymlinksInPath() : rootURL).path
            if !output.hasPrefix(root + "/") { return "Choose a SOFA output subfolder inside this project folder." }
            let protected = ["Input", "Projects", "Intermediates", "Prepared", "Manual PPM", "MeshEdits", "Logs", ".pinna2hrtf"].map { root + "/" + $0 } + project.protectedOutputInputs()
            if protected.contains(where: { path in output == path || output.hasPrefix(path + "/") || path.hasPrefix(output + "/") }) {
                return "Choose a separate SOFA folder that does not contain inputs or project work."
            }
            if !isComplete(.numcalc) || [.failed, .stopped].contains(project.stageOutcomes?[Stage.numcalc.rawValue] ?? .ready) { return "Finish NumCalc successfully first." }
        }
        return nil
    }

    static func outputLocationConflict(for project: ProjectRecord, projects: [ProjectRecord], resolvingSymlinks: Bool = true) -> String? {
        guard !project.saveLocation.isEmpty else { return "Choose a save location." }
        let rootURL = URL(fileURLWithPath: project.saveLocation, isDirectory: true).standardizedFileURL
        let root = (resolvingSymlinks ? rootURL.resolvingSymlinksInPath() : rootURL).path
        for other in projects where other.id != project.id && !other.saveLocation.isEmpty {
            let otherURL = URL(fileURLWithPath: other.saveLocation, isDirectory: true).standardizedFileURL
            let otherRoot = (resolvingSymlinks ? otherURL.resolvingSymlinksInPath() : otherURL).path
            if root == otherRoot || root.hasPrefix(otherRoot + "/") || otherRoot.hasPrefix(root + "/") {
                return "Choose a separate output folder; this location overlaps \(other.name)."
            }
        }
        return nil
    }

}
