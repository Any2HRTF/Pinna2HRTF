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
        let hrtfFolder = postprocessingDirectory(for: project)
        let plots = (try? FileManager.default.contentsOfDirectory(at: hrtfFolder, includingPropertiesForKeys: nil)) ?? []
        for plot in plots.filter({ ["jpeg", "jpg", "png"].contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = plot.deletingPathExtension().lastPathComponent.lowercased()
            let title = name.contains("horizontal") ? "Horizontal HRTF plot" : name.contains("median") ? "Median HRTF plot" : plot.deletingPathExtension().lastPathComponent
            next.append(Artifact(title: title, url: plot))
        }
        return next
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
        guard project.settings.inference.usePredictionsForPreprocessing else {
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
            let complete = stageIsComplete(stage, project: project)
            if failedStages.contains(stage) || project.stageOutcomes?[stage.rawValue] == .failed {
                return (stage, .failed)
            }
            if project.stageOutcomes?[stage.rawValue] == .stopped { return (stage, .stopped) }
            if stage == .inference, !project.settings.inference.usePredictionsForPreprocessing || (project.leftEar.isEmpty && project.rightEar.isEmpty) {
                return (stage, .skipped)
            }
            return (stage, complete ? .done : .ready)
        })
    }

    static func summary(for project: ProjectRecord) -> String {
        if project.stageOutcomes?.values.contains(.failed) == true { return "Latest run failed · previous results may remain" }
        if project.stageOutcomes?.values.contains(.stopped) == true { return "Task stopped · previous results may remain" }
        if project.leftEar.isEmpty && project.rightEar.isEmpty { return "Not configured" }
        if stageIsComplete(.postprocessing, project: project) { return "Postprocessed" }
        if stageIsComplete(.numcalc, project: project) { return "Solved" }
        if stageIsComplete(.preprocessing, project: project) { return "Projects ready" }
        if project.settings.inference.usePredictionsForPreprocessing && stageIsComplete(.inference, project: project) { return "Mesh2PPM Inference ready" }
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
            if project.leftEar.isEmpty && project.rightEar.isEmpty { return false }
            let leftDone = project.leftEar.isEmpty || containsMesh(output.appendingPathComponent(settings.predictionLeftFolder))
            let rightDone = project.rightEar.isEmpty || containsMesh(output.appendingPathComponent(settings.predictionRightFolder))
            return leftDone && rightDone
        case .preprocessing:
            if project.leftEar.isEmpty && project.rightEar.isEmpty { return false }
            let leftDone = project.leftEar.isEmpty || (fileHasData(output.appendingPathComponent("Projects/Left/parameters.json")) && fileHasData(output.appendingPathComponent("Intermediates/Left/graded_head.ply")))
            let rightDone = project.rightEar.isEmpty || (fileHasData(output.appendingPathComponent("Projects/Right/parameters.json")) && fileHasData(output.appendingPathComponent("Intermediates/Right/graded_head.ply")))
            return leftDone && rightDone
        case .numcalc:
            if project.leftEar.isEmpty && project.rightEar.isEmpty { return false }
            let leftDone = project.leftEar.isEmpty || numcalcIsComplete(output.appendingPathComponent("Projects/Left")) || containsSOFA(output.appendingPathComponent("Projects/Left/Output2HRTF"))
            let rightDone = project.rightEar.isEmpty || numcalcIsComplete(output.appendingPathComponent("Projects/Right")) || containsSOFA(output.appendingPathComponent("Projects/Right/Output2HRTF"))
            return leftDone && rightDone
        case .postprocessing:
            return containsSOFA(postprocessingDirectory(for: project))
        }
    }

    static func postprocessingDirectory(for project: ProjectRecord) -> URL {
        if let folder = project.settings.postprocessing?.outputFolder { return URL(fileURLWithPath: folder) }
        return URL(fileURLWithPath: project.saveLocation).appendingPathComponent("HRTF")
    }

    static func fileHasData(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    static func isSOFAContainer(_ url: URL) -> Bool {
        guard fileHasData(url), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count == 8 else { return false }
        return data == Data([0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a])
            || (data.prefix(3) == Data("CDF".utf8) && [1, 2, 5].contains(data[3]))
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func containsMesh(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        let meshes = files.filter { ["stl", "ply"].contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare("graded_head") != .orderedSame }
        let validMeshes = meshes.filter { fileHasData($0) }
        return validMeshes.contains { $0.deletingPathExtension().lastPathComponent.hasPrefix("Prediction_") } || validMeshes.count == 1
    }

    static func containsSOFA(_ url: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension.lowercased() == "sofa" && isSOFAContainer($0) }
    }

    static func numcalcCompleted(_ project: URL) -> Int {
        let source = project.appendingPathComponent("NumCalc/source_1")
        let files = (try? FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("be.out"), includingPropertiesForKeys: nil)) ?? []
        let completed = files.filter { path in
            guard path.lastPathComponent.hasPrefix("be."), let step = Int(path.lastPathComponent.dropFirst(3)) else { return false }
            return frequencyStepComplete(source: source, step: step)
        }.count
        return completed > 0 ? completed : containsSOFA(project.appendingPathComponent("Output2HRTF")) ? numcalcTotal(project) : 0
    }

    static func numcalcIsComplete(_ project: URL) -> Bool {
        let total = numcalcTotal(project)
        guard total > 0 else { return false }
        let source = project.appendingPathComponent("NumCalc/source_1")
        return (1...total).allSatisfy { frequencyStepComplete(source: source, step: $0) }
    }

    static func frequencyStepComplete(source: URL, step: Int) -> Bool {
        let output = source.appendingPathComponent("be.out/be.\(step)")
        let required = ["pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"]
        guard required.allSatisfy({ fileHasData(output.appendingPathComponent($0)) }) else { return false }
        let log = source.appendingPathComponent("NC\(step)-\(step)_log.txt")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return text.contains("---------- NumCalc ended:")
    }

    static func numcalcTotal(_ project: URL) -> Int {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("parameters.json")), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let total = object["numFrequencies"] as? Int else { return 0 }
        return total
    }
}
