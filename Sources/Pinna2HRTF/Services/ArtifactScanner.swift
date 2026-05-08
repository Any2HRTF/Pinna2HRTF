import Foundation

enum ArtifactScanner {
    static func artifacts(for project: ProjectRecord) -> [Artifact] {
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        var next = [
            Artifact(title: "Input left ear", url: URL(fileURLWithPath: project.leftEar)),
            Artifact(title: "Input right ear", url: URL(fileURLWithPath: project.rightEar)),
            Artifact(title: "Prepared inference left ear", url: output.appendingPathComponent(settings.targetLeftFolder).appendingPathComponent(URL(fileURLWithPath: project.leftEar).lastPathComponent)),
            Artifact(title: "Prepared inference right ear", url: output.appendingPathComponent(settings.targetRightFolder).appendingPathComponent(URL(fileURLWithPath: project.rightEar).lastPathComponent)),
            Artifact(title: "Closed left ear", url: output.appendingPathComponent("intermediates/left/closed_ear.stl")),
            Artifact(title: "Closed right ear", url: output.appendingPathComponent("intermediates/right/closed_ear.stl")),
            Artifact(title: "Dummy head", url: output.appendingPathComponent("intermediates/dummy_head.stl")),
            Artifact(title: "Cut left head", url: output.appendingPathComponent("intermediates/left/cut_head.stl")),
            Artifact(title: "Cut right head", url: output.appendingPathComponent("intermediates/right/cut_head.stl")),
            Artifact(title: "Stitched left head", url: output.appendingPathComponent("intermediates/left/stitched_head.stl")),
            Artifact(title: "Stitched right head", url: output.appendingPathComponent("intermediates/right/stitched_head.stl")),
            Artifact(title: "Graded left head", url: output.appendingPathComponent("intermediates/left/graded_head.ply")),
            Artifact(title: "Graded right head", url: output.appendingPathComponent("intermediates/right/graded_head.ply"))
        ]
        for pair in [("Predicted left ear", output.appendingPathComponent(settings.predictionLeftFolder)), ("Predicted right ear", output.appendingPathComponent(settings.predictionRightFolder))] {
            if let files = try? FileManager.default.contentsOfDirectory(at: pair.1, includingPropertiesForKeys: nil) {
                for file in files.sorted(by: { $0.path < $1.path }) where ["stl", "ply"].contains(file.pathExtension.lowercased()) {
                    next.append(Artifact(title: "\(pair.0) \(file.deletingPathExtension().lastPathComponent)", url: file))
                }
            }
        }
        for plot in [
            ("HRTF horizontal plane", "HRTF/HRIR_EvalGrid_merged_3D_horizontal_plane.jpeg"),
            ("HRTF median plane", "HRTF/HRIR_EvalGrid_merged_3D_median_plane.jpeg")
        ] {
            let hrtfPlot = output.appendingPathComponent(plot.1)
            if FileManager.default.fileExists(atPath: hrtfPlot.path) {
                next.append(Artifact(title: plot.0, url: hrtfPlot))
            }
        }
        return next
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
