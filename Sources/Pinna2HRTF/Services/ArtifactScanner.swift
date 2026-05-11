import Foundation

enum ArtifactScanner {
    static func artifacts(for project: ProjectRecord) -> [Artifact] {
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        var next = [
            Artifact(title: "Left simulation mesh", url: output.appendingPathComponent("intermediates/left/graded_head.ply")),
            Artifact(title: "Right simulation mesh", url: output.appendingPathComponent("intermediates/right/graded_head.ply"))
        ]
        for pair in [("Generated left ear", output.appendingPathComponent(settings.predictionLeftFolder)), ("Generated right ear", output.appendingPathComponent(settings.predictionRightFolder))] {
            next.append(contentsOf: meshArtifacts(title: pair.0, folder: pair.1))
        }
        for plot in [
            ("Horizontal HRTF plot", "HRTF/HRIR_EvalGrid_merged_3D_horizontal_plane.jpeg"),
            ("Median HRTF plot", "HRTF/HRIR_EvalGrid_merged_3D_median_plane.jpeg")
        ] {
            let hrtfPlot = output.appendingPathComponent(plot.1)
            if FileManager.default.fileExists(atPath: hrtfPlot.path) {
                next.append(Artifact(title: plot.0, url: hrtfPlot))
            }
        }
        return next
    }

    static func meshArtifacts(title: String, folder: URL) -> [Artifact] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let meshes = files.filter { ["stl", "ply"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        if meshes.count == 1, let file = meshes.first {
            return [Artifact(title: title, url: file)]
        }
        return meshes.map { Artifact(title: "\(title) - \($0.deletingPathExtension().lastPathComponent)", url: $0) }
    }

    static func stageStates(for project: ProjectRecord, runningStage: Stage?, failedStages: Set<Stage>) -> [Stage: StageState] {
        Dictionary(uniqueKeysWithValues: Stage.allCases.map { stage in
            if runningStage == stage {
                return (stage, .running)
            }
            if failedStages.contains(stage), !stageIsComplete(stage, project: project) {
                return (stage, .failed)
            }
            return (stage, stageIsComplete(stage, project: project) ? .done : .ready)
        })
    }

    static func summary(for project: ProjectRecord) -> String {
        let states = stageStates(for: project, runningStage: nil, failedStages: [])
        if states[.postprocessing] == .done { return "Postprocessed" }
        if states[.numcalc] == .done { return "Solved" }
        if states[.preprocessing] == .done { return "Projects ready" }
        if states[.inference] == .done { return "Inference ready" }
        return URL(fileURLWithPath: project.saveLocation).lastPathComponent
    }

    static func stageIsComplete(_ stage: Stage, project: ProjectRecord) -> Bool {
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        switch stage {
        case .inference:
            return containsMesh(output.appendingPathComponent(settings.predictionLeftFolder)) && containsMesh(output.appendingPathComponent(settings.predictionRightFolder))
        case .preprocessing:
            return fileExists(output.appendingPathComponent("Projects/Left/parameters.json")) && fileExists(output.appendingPathComponent("Projects/Right/parameters.json")) && fileExists(output.appendingPathComponent("intermediates/left/graded_head.ply")) && fileExists(output.appendingPathComponent("intermediates/right/graded_head.ply"))
        case .numcalc:
            return containsNumCalcOutput(output.appendingPathComponent("Projects/Left/NumCalc/source_1/be.out")) && containsNumCalcOutput(output.appendingPathComponent("Projects/Right/NumCalc/source_1/be.out"))
        case .postprocessing:
            return containsSOFA(output.appendingPathComponent("HRTF"))
        }
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func containsMesh(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return files.contains { ["stl", "ply"].contains($0.pathExtension.lowercased()) }
    }

    static func containsSOFA(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension.lowercased() == "sofa" }
    }

    static func containsNumCalcOutput(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.lastPathComponent.hasPrefix("be.") }
    }
}
