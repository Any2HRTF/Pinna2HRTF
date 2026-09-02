import Foundation

enum ArtifactScanner {
    static func artifacts(for project: ProjectRecord) -> [Artifact] {
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        var next: [Artifact] = []
        if !project.leftEar.isEmpty {
            next.append(Artifact(title: "Input left ear", url: URL(fileURLWithPath: project.leftEar)))
            next.append(Artifact(title: "Left simulation mesh", url: output.appendingPathComponent("Intermediates/Left/graded_head.ply")))
        }
        if !project.rightEar.isEmpty {
            next.append(Artifact(title: "Input right ear", url: URL(fileURLWithPath: project.rightEar)))
            next.append(Artifact(title: "Right simulation mesh", url: output.appendingPathComponent("Intermediates/Right/graded_head.ply")))
        }
        for pair in [("Predicted left ear", output.appendingPathComponent(settings.predictionLeftFolder), project.leftEar), ("Predicted right ear", output.appendingPathComponent(settings.predictionRightFolder), project.rightEar)] where !pair.2.isEmpty {
            next.append(contentsOf: predictionArtifacts(title: pair.0, folder: pair.1))
        }
        let hrtfFolder = output.appendingPathComponent("HRTF")
        let plots = (try? FileManager.default.contentsOfDirectory(at: hrtfFolder, includingPropertiesForKeys: nil)) ?? []
        for plot in plots.filter({ ["jpeg", "jpg", "png"].contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = plot.deletingPathExtension().lastPathComponent.lowercased()
            let title = name.contains("horizontal") ? "Horizontal HRTF plot" : name.contains("median") ? "Median HRTF plot" : plot.deletingPathExtension().lastPathComponent
            next.append(Artifact(title: title, url: plot))
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

    static func predictionArtifacts(title: String, folder: URL) -> [Artifact] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let meshes = files.filter { $0.lastPathComponent.hasPrefix("Prediction_") && ["stl", "ply"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        if meshes.count == 1, let file = meshes.first {
            return [Artifact(title: title, url: file)]
        }
        return meshes.map { Artifact(title: "\(title) - \($0.deletingPathExtension().lastPathComponent)", url: $0) }
    }

    static func preprocessingMesh(for project: ProjectRecord, side: EarSide) -> URL? {
        let sourcePath = side == .left ? project.leftEar : project.rightEar
        guard !sourcePath.isEmpty else { return nil }
        let source = URL(fileURLWithPath: sourcePath)
        guard project.settings.inference.usePredictionsForPreprocessing, !project.leftEar.isEmpty, !project.rightEar.isEmpty else {
            return FileManager.default.fileExists(atPath: source.path) ? source : nil
        }
        let folderName = side == .left ? project.settings.inference.predictionLeftFolder : project.settings.inference.predictionRightFolder
        let folder = URL(fileURLWithPath: project.saveLocation).appendingPathComponent(folderName)
        let preferred = folder.appendingPathComponent("Prediction_\(source.deletingPathExtension().lastPathComponent).stl")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let legacyPreferred = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent).stl")
        if FileManager.default.fileExists(atPath: legacyPreferred.path) { return legacyPreferred }
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let meshes = files.filter { $0.pathExtension.lowercased() == "stl" }
        return meshes.count == 1 ? meshes[0] : nil
    }

    static func meshIdentity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
    }

    static func manualMicrophonePosition(for project: ProjectRecord, side: EarSide) -> ManualMicrophonePosition? {
        side == .left ? project.settings.preprocessing.sourcePositionInputLeft : project.settings.preprocessing.sourcePositionInputRight
    }

    static func validManualMicrophonePosition(for project: ProjectRecord, side: EarSide) -> ManualMicrophonePosition? {
        guard let placement = manualMicrophonePosition(for: project, side: side), let mesh = preprocessingMesh(for: project, side: side), placement.meshPath == mesh.standardizedFileURL.path, placement.meshIdentity == meshIdentity(mesh) else { return nil }
        return placement
    }

    static func stageStates(for project: ProjectRecord, runningStage: Stage?, failedStages: Set<Stage>) -> [Stage: StageState] {
        Dictionary(uniqueKeysWithValues: Stage.allCases.map { stage in
            if runningStage == stage {
                return (stage, .running)
            }
            if failedStages.contains(stage), !stageIsComplete(stage, project: project) {
                return (stage, .failed)
            }
            if stage == .inference, !project.settings.inference.usePredictionsForPreprocessing {
                return (stage, .skipped)
            }
            return (stage, stageIsComplete(stage, project: project) ? .done : .ready)
        })
    }

    static func summary(for project: ProjectRecord) -> String {
        let states = stageStates(for: project, runningStage: nil, failedStages: [])
        if states[.postprocessing] == .done { return "Postprocessed" }
        if states[.numcalc] == .done { return "Solved" }
        if states[.preprocessing] == .done { return "Projects ready" }
        if states[.inference] == .done { return "Mesh2PPM Inference ready" }
        return URL(fileURLWithPath: project.saveLocation).lastPathComponent
    }

    static func numcalcStatus(for project: ProjectRecord) -> String {
        let output = URL(fileURLWithPath: project.saveLocation)
        let sides = [("Left", project.leftEar), ("Right", project.rightEar)].compactMap { side, ear in
            ear.isEmpty ? nil : "\(side) \(numcalcCompleted(output.appendingPathComponent("Projects/\(side)")))/\(numcalcTotal(output.appendingPathComponent("Projects/\(side)")))"
        }
        return sides.isEmpty ? "NumCalc: no ear selected" : "NumCalc: " + sides.joined(separator: " · ")
    }

    static func stageIsComplete(_ stage: Stage, project: ProjectRecord) -> Bool {
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        switch stage {
        case .inference:
            if !settings.usePredictionsForPreprocessing { return true }
            if project.leftEar.isEmpty || project.rightEar.isEmpty { return true }
            let leftDone = project.leftEar.isEmpty || containsMesh(output.appendingPathComponent(settings.predictionLeftFolder))
            let rightDone = project.rightEar.isEmpty || containsMesh(output.appendingPathComponent(settings.predictionRightFolder))
            return leftDone && rightDone
        case .preprocessing:
            let leftDone = project.leftEar.isEmpty || (fileExists(output.appendingPathComponent("Projects/Left/parameters.json")) && fileExists(output.appendingPathComponent("Intermediates/Left/graded_head.ply")))
            let rightDone = project.rightEar.isEmpty || (fileExists(output.appendingPathComponent("Projects/Right/parameters.json")) && fileExists(output.appendingPathComponent("Intermediates/Right/graded_head.ply")))
            return leftDone && rightDone
        case .numcalc:
            let leftDone = project.leftEar.isEmpty || containsNumCalcOutput(output.appendingPathComponent("Projects/Left/NumCalc/source_1/be.out")) || containsOutput2HRTF(output.appendingPathComponent("Projects/Left/Output2HRTF"))
            let rightDone = project.rightEar.isEmpty || containsNumCalcOutput(output.appendingPathComponent("Projects/Right/NumCalc/source_1/be.out")) || containsOutput2HRTF(output.appendingPathComponent("Projects/Right/Output2HRTF"))
            return leftDone && rightDone
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

    static func containsOutput2HRTF(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension.lowercased() == "sofa" }
    }

    static func numcalcCompleted(_ project: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: project.appendingPathComponent("NumCalc/source_1/be.out"), includingPropertiesForKeys: nil)) ?? []
        let completed = files.filter { $0.lastPathComponent.hasPrefix("be.") && Int($0.lastPathComponent.dropFirst(3)) != nil }.count
        return completed > 0 ? completed : containsOutput2HRTF(project.appendingPathComponent("Output2HRTF")) ? numcalcTotal(project) : 0
    }

    static func numcalcTotal(_ project: URL) -> Int {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("parameters.json")), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let total = object["numFrequencies"] as? Int else { return 0 }
        return total
    }
}
