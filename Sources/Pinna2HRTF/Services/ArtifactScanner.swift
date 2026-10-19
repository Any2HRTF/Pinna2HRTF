import Foundation

enum ArtifactScanner {
    /// One refresh owns one inspection; subsequent refreshes always read fresh files.
    final class Inspection {
        private var documents: [URL: [String: Any]?] = [:]
        private var metadata: [URL: [FileAttributeKey: Any]?] = [:]
        fileprivate var completedSteps: [URL: Bool] = [:]

        func document(_ url: URL) -> [String: Any]? {
            if let cached = documents[url] { return cached }
            let result = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            documents.updateValue(result, forKey: url)
            return result
        }

        func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
            if let cached = metadata[url] { return cached }
            let result = try? FileManager.default.attributesOfItem(atPath: url.path)
            metadata.updateValue(result, forKey: url)
            return result
        }
    }

    static func artifacts(for project: ProjectRecord, inspection: Inspection = Inspection()) -> [Artifact] {
        let leftEar = project.pipelineEar(for: .left, inspection: inspection)
        let rightEar = project.pipelineEar(for: .right, inspection: inspection)
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        var next: [Artifact] = []
        if project.scanPreparation.enabled && !project.scanPreparation.scanPath.isEmpty {
            next.append(Artifact(title: "Full-head scan", url: URL(fileURLWithPath: project.scanPreparation.scanPath)))
        }
        if project.scanPreparation.enabled && scanPreparationIsCurrent(project, inspection: inspection) {
            for side in EarSide.allCases {
                guard side == .left ? project.scanPreparation.prepareLeft : project.scanPreparation.prepareRight,
                      let mesh = preparedEarURL(for: side, in: project, inspection: inspection),
                      FileManager.default.fileExists(atPath: mesh.path) else { continue }
                next.append(Artifact(title: earReviewIsCurrent(project, side: side, inspection: inspection) ? "Reviewed \(side.rawValue) ear" : "Prepared \(side.rawValue) ear", url: mesh))
            }
        }
        if !leftEar.isEmpty {
            next.append(Artifact(title: "Input left ear", url: URL(fileURLWithPath: leftEar)))
            next.append(Artifact(title: "Left simulation mesh", url: output.appendingPathComponent("Intermediates/Left/graded_head.ply")))
        }
        if !rightEar.isEmpty {
            next.append(Artifact(title: "Input right ear", url: URL(fileURLWithPath: rightEar)))
            next.append(Artifact(title: "Right simulation mesh", url: output.appendingPathComponent("Intermediates/Right/graded_head.ply")))
        }
        for side in EarSide.allCases {
            if let path = project.settings.manualPPMFitting.meshPath(for: side),
               FileManager.default.fileExists(atPath: path) {
                next.append(Artifact(title: "Manual \(side.rawValue) PPM fit", url: URL(fileURLWithPath: path)))
            }
        }
        for pair in [("Predicted left ear", output.appendingPathComponent(settings.predictionLeftFolder), leftEar), ("Predicted right ear", output.appendingPathComponent(settings.predictionRightFolder), rightEar)] where !pair.2.isEmpty {
            next.append(contentsOf: predictionArtifacts(title: pair.0, folder: pair.1))
        }
        let hrtfFolder = postprocessingDirectory(for: project)
        let plots = (try? FileManager.default.contentsOfDirectory(at: hrtfFolder, includingPropertiesForKeys: nil)) ?? []
        for plot in plots.filter({ ["jpeg", "jpg", "png"].contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = plot.deletingPathExtension().lastPathComponent.lowercased()
            let title = name.contains("horizontal") ? "Horizontal HRTF plot" : name.contains("median") ? "Median HRTF plot" : plot.deletingPathExtension().lastPathComponent
            next.append(Artifact(title: title, url: plot))
        }
        var seenPaths = Set<String>()
        return next.filter { artifact in
            seenPaths.insert(artifact.url.standardizedFileURL.path).inserted
        }
    }

    static func predictionArtifacts(title: String, folder: URL) -> [Artifact] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let meshes = files.filter { $0.lastPathComponent.hasPrefix("Prediction_") && ["stl", "ply"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        if meshes.count == 1, let file = meshes.first {
            return [Artifact(title: title, url: file)]
        }
        return meshes.map { Artifact(title: "\(title) - \($0.deletingPathExtension().lastPathComponent)", url: $0) }
    }

    static func preprocessingMesh(for project: ProjectRecord, side: EarSide, inspection: Inspection = Inspection()) -> URL? {
        if project.settings.manualPPMFitting.useForPreprocessing,
           project.settings.manualPPMFitting.meshPath(for: side) != nil {
            return validManualPPMFittingMesh(for: project, side: side, inspection: inspection)
        }
        let sourcePath = side == .left ? project.pipelineEar(for: .left, inspection: inspection) : project.pipelineEar(for: .right, inspection: inspection)
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

    static func sourceEar(for project: ProjectRecord, side: EarSide, inspection: Inspection = Inspection()) -> URL? {
        if project.scanPreparation.enabled {
            return preparedEarURL(for: side, in: project, inspection: inspection)
        }
        let path = side == .left ? project.leftEar : project.rightEar
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static func validManualPPMFittingMesh(for project: ProjectRecord, side: EarSide, inspection: Inspection = Inspection()) -> URL? {
        let settings = project.settings.manualPPMFitting
        guard let path = settings.meshPath(for: side),
              let sourcePath = settings.sourcePath(for: side),
              let sourceIdentity = settings.sourceIdentity(for: side),
              let source = sourceEar(for: project, side: side, inspection: inspection),
              source.standardizedFileURL.path == URL(fileURLWithPath: sourcePath).standardizedFileURL.path,
              meshIdentity(source, inspection: inspection) == sourceIdentity,
              FileManager.default.fileExists(atPath: path),
              let parameters = settings.parametersPath(for: side),
              FileManager.default.fileExists(atPath: parameters) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func meshIdentity(_ url: URL, inspection: Inspection = Inspection()) -> String? {
        guard let attributes = inspection.attributes(url) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
    }

    static func manualMicrophonePosition(for project: ProjectRecord, side: EarSide) -> ManualMicrophonePosition? {
        side == .left ? project.settings.preprocessing.sourcePositionInputLeft : project.settings.preprocessing.sourcePositionInputRight
    }

    static func validManualMicrophonePosition(for project: ProjectRecord, side: EarSide, inspection: Inspection = Inspection()) -> ManualMicrophonePosition? {
        guard let placement = manualMicrophonePosition(for: project, side: side), let mesh = preprocessingMesh(for: project, side: side, inspection: inspection), placement.meshPath == mesh.standardizedFileURL.path, placement.meshIdentity == meshIdentity(mesh, inspection: inspection) else { return nil }
        return placement
    }

    static func stageStates(for project: ProjectRecord, runningStage: Stage?, failedStages: Set<Stage>, inspection: Inspection = Inspection()) -> [Stage: StageState] {
        Dictionary(uniqueKeysWithValues: Stage.allCases.map { stage in
            if runningStage == stage {
                return (stage, .running)
            }
            if stage == .scanPreparation && !project.scanPreparation.enabled { return (stage, .skipped) }
            let complete = stageIsComplete(stage, project: project, inspection: inspection)
            if failedStages.contains(stage) || project.stageOutcomes?[stage.rawValue] == .failed {
                return (stage, .failed)
            }
            if project.stageOutcomes?[stage.rawValue] == .stopped { return (stage, .stopped) }
            if stage == .inference, !project.settings.inference.usePredictionsForPreprocessing || (project.pipelineEar(for: .left, inspection: inspection).isEmpty && project.pipelineEar(for: .right, inspection: inspection).isEmpty) {
                return (stage, .skipped)
            }
            return (stage, complete ? .done : .ready)
        })
    }

    static func summary(for project: ProjectRecord, inspection: Inspection = Inspection()) -> String {
        if project.stageOutcomes?.values.contains(.failed) == true { return "Latest run failed · previous results may remain" }
        if project.stageOutcomes?.values.contains(.stopped) == true { return "Task stopped · previous results may remain" }
        if project.pipelineEar(for: .left, inspection: inspection).isEmpty && project.pipelineEar(for: .right, inspection: inspection).isEmpty { return "Not configured" }
        if stageIsComplete(.postprocessing, project: project, inspection: inspection) { return "Postprocessed" }
        if stageIsComplete(.numcalc, project: project, inspection: inspection) { return "Solved" }
        if stageIsComplete(.preprocessing, project: project, inspection: inspection) { return "Projects ready" }
        if project.settings.inference.usePredictionsForPreprocessing && stageIsComplete(.inference, project: project, inspection: inspection) { return "Mesh2PPM Inference ready" }
        return URL(fileURLWithPath: project.saveLocation).lastPathComponent
    }

    static func numcalcStatus(for project: ProjectRecord, inspection: Inspection = Inspection()) -> String {
        let output = URL(fileURLWithPath: project.saveLocation)
        let sides = [("Left", project.pipelineEar(for: .left, inspection: inspection)), ("Right", project.pipelineEar(for: .right, inspection: inspection))].compactMap { side, ear in
            ear.isEmpty ? nil : "\(side) \(numcalcCompleted(output.appendingPathComponent("Projects/\(side)"), inspection: inspection))/\(numcalcTotal(output.appendingPathComponent("Projects/\(side)"), inspection: inspection))"
        }
        return sides.isEmpty ? "NumCalc: no ear selected" : "NumCalc: " + sides.joined(separator: " · ")
    }

    static func stageIsComplete(_ stage: Stage, project: ProjectRecord, inspection: Inspection = Inspection()) -> Bool {
        let output = URL(fileURLWithPath: project.saveLocation)
        let settings = project.settings.inference
        if stage == .inference && !settings.usePredictionsForPreprocessing { return true }
        if project.scanPreparation.enabled && stage != .scanPreparation {
            guard scanPreparationIsCurrent(project, inspection: inspection) else { return false }
            if stage == .inference && settings.usePredictionsForPreprocessing && !scanReceiptIsCurrent(project, stage: "inference", inspection: inspection) { return false }
            if [.preprocessing, .numcalc, .postprocessing].contains(stage) && !scanReceiptIsCurrent(project, stage: "preprocessing", inspection: inspection) { return false }
        }
        let sides = EarSide.allCases.filter { !project.pipelineEar(for: $0, inspection: inspection).isEmpty }
        switch stage {
        case .scanPreparation:
            return !project.scanPreparation.enabled || scanPreparationIsCurrent(project, inspection: inspection)
        case .inference:
            return !sides.isEmpty && sides.allSatisfy { side in
                let folder = side == .left ? settings.predictionLeftFolder : settings.predictionRightFolder
                return containsMesh(output.appendingPathComponent(folder), inspection: inspection)
            }
        case .preprocessing:
            return !sides.isEmpty && sides.allSatisfy { side in
                if project.settings.manualPPMFitting.useForPreprocessing,
                   let savedMesh = project.settings.manualPPMFitting.meshPath(for: side), !savedMesh.isEmpty,
                   validManualPPMFittingMesh(for: project, side: side, inspection: inspection) == nil { return false }
                return fileHasData(output.appendingPathComponent("Projects/\(side.title)/parameters.json"), inspection: inspection)
                    && fileHasData(output.appendingPathComponent("Intermediates/\(side.title)/graded_head.ply"), inspection: inspection)
            }
        case .numcalc:
            return !sides.isEmpty && sides.allSatisfy { side in
                let folder = output.appendingPathComponent("Projects/\(side.title)")
                return numcalcIsComplete(folder, inspection: inspection)
                    || containsSOFA(folder.appendingPathComponent("Output2HRTF"), inspection: inspection)
            }
        case .postprocessing:
            return containsSOFA(postprocessingDirectory(for: project), inspection: inspection)
        }
    }

    static func preprocessingSignature(for project: ProjectRecord, inspection: Inspection = Inspection()) -> String {
        let leftEar = project.pipelineEar(for: .left, inspection: inspection)
        let rightEar = project.pipelineEar(for: .right, inspection: inspection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let inference = (try? encoder.encode(project.settings.inference)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let preprocessing = (try? encoder.encode(project.settings.preprocessing)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let manualPPMFitting = project.settings.manualPPMFitting.useForPreprocessing
            ? ((try? encoder.encode(project.settings.manualPPMFitting)).flatMap { String(data: $0, encoding: .utf8) } ?? "") : ""
        let leftIdentity = leftEar.isEmpty ? "" : (ArtifactScanner.meshIdentity(URL(fileURLWithPath: leftEar), inspection: inspection) ?? "")
        let rightIdentity = rightEar.isEmpty ? "" : (ArtifactScanner.meshIdentity(URL(fileURLWithPath: rightEar), inspection: inspection) ?? "")
        let fittedLeftIdentity = project.settings.manualPPMFitting.useForPreprocessing ? project.settings.manualPPMFitting.leftMeshPath.flatMap { meshIdentity(URL(fileURLWithPath: $0), inspection: inspection) } ?? "" : ""
        let fittedRightIdentity = project.settings.manualPPMFitting.useForPreprocessing ? project.settings.manualPPMFitting.rightMeshPath.flatMap { meshIdentity(URL(fileURLWithPath: $0), inspection: inspection) } ?? "" : ""
        let original = [leftEar, rightEar, project.inputHandling.rawValue, leftIdentity, rightIdentity, inference, preprocessing, manualPPMFitting, fittedLeftIdentity, fittedRightIdentity].joined(separator: "\n")
        guard project.scanPreparation.enabled else { return original }
        let scan = (try? encoder.encode(project.scanPreparation)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return original + "\n" + scan
    }

    static func scanPreparationIsCurrent(_ project: ProjectRecord, inspection: Inspection = Inspection()) -> Bool {
        let scan = project.scanPreparation
        let root = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Prepared")
        guard let report = inspection.document(root.appendingPathComponent("mesh_preparation.json")),
              report["status"] as? String == "completed",
              let signature = report["signature"] as? [String: Any],
              let settings = signature["settings"] as? [String: Any],
              let ears = report["ears"] as? [String: [String: Any]],
              settings["prepare_left"] as? Bool == scan.prepareLeft,
              settings["prepare_right"] as? Bool == scan.prepareRight else { return false }
        let numbers = [("rotation_degrees", scan.rotationDegrees), ("target_edge_mm", scan.targetEdgeMM),
                       ("left_margin_mm", scan.leftMarginMM), ("right_margin_mm", scan.rightMarginMM),
                       ("side_min_mm", scan.sideMinMM), ("side_max_mm", scan.sideMaxMM)]
        guard numbers.allSatisfy({ (settings[$0.0] as? NSNumber)?.doubleValue == Double($0.1) }) else { return false }
        // Copy-input projects record the portable copy. The source fingerprint still
        // lets changes to the selected original invalidate the prepared geometry.
        let source = URL(fileURLWithPath: scan.scanPath)
        guard let sourceStamp = report["source_identity"] as? [String: Any],
              matchesStamp(source, sourceStamp, inspection: inspection) else { return false }
        for (side, selected) in [("left", scan.prepareLeft), ("right", scan.prepareRight)] where selected {
            guard let ear = ears[side], let stamp = ear["identity"] as? [String: Any],
                  matchesStamp(root.appendingPathComponent("\(side.capitalized).stl"), stamp, inspection: inspection) else { return false }
        }
        return scan.prepareLeft || scan.prepareRight
    }

    static func earReviewIsCurrent(_ project: ProjectRecord, side: EarSide, inspection: Inspection = Inspection()) -> Bool {
        let scan = project.scanPreparation
        guard let path = side == .left ? scan.reviewedLeftPath : scan.reviewedRightPath else { return false }
        let folder = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Prepared")
        let baseEar = folder.appendingPathComponent("\(side.title).stl")
        guard let report = inspection.document(folder.appendingPathComponent("mesh_preparation.json")),
              let generation = report["generation"] as? String,
              let ears = report["ears"] as? [String: [String: Any]],
              let baseDigest = ears[side.rawValue]?["sha256"] as? String,
              let receipt = inspection.document(URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("json")),
              receipt["kind"] as? String == "ear", receipt["side"] as? String == side.rawValue,
              receipt["generation"] as? String == generation, receipt["source_sha256"] as? String == baseDigest,
              receipt["source_identity"] as? [String: Any] != nil,
              let stamp = receipt["output_identity"] as? [String: Any] else { return false }
        return matchesStamp(baseEar, receipt["source_identity"] as? [String: Any] ?? [:], inspection: inspection) &&
            matchesStamp(URL(fileURLWithPath: path), stamp, inspection: inspection)
    }

    static func preparedEarURL(for side: EarSide, in project: ProjectRecord, inspection: Inspection = Inspection()) -> URL? {
        let scan = project.scanPreparation
        guard scan.enabled, side == .left ? scan.prepareLeft : scan.prepareRight else { return nil }
        if earReviewIsCurrent(project, side: side, inspection: inspection),
           let reviewed = side == .left ? scan.reviewedLeftPath : scan.reviewedRightPath {
            return URL(fileURLWithPath: reviewed)
        }
        return URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Prepared/\(side.title).stl")
    }

    static func preparedEarSide(for mesh: URL, in project: ProjectRecord, inspection: Inspection = Inspection()) -> EarSide? {
        for side in EarSide.allCases where preparedEarURL(for: side, in: project, inspection: inspection)?.standardizedFileURL.path == mesh.standardizedFileURL.path {
            return side
        }
        return nil
    }

    static func scanReceiptIsCurrent(_ project: ProjectRecord, stage: String, inspection: Inspection = Inspection()) -> Bool {
        let folder = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Prepared")
        guard let report = inspection.document(folder.appendingPathComponent("mesh_preparation.json")),
              let generation = report["generation"] as? String,
              let receipt = inspection.document(folder.appendingPathComponent("\(stage).json")) else { return false }
        guard receipt["generation"] as? String == generation else { return false }
        if let expected = receipt["input_ears"] as? [String: String] {
            let baseEars = report["ears"] as? [String: [String: Any]] ?? [:]
            for (side, selected, path) in [(EarSide.left, project.scanPreparation.prepareLeft, project.scanPreparation.reviewedLeftPath), (.right, project.scanPreparation.prepareRight, project.scanPreparation.reviewedRightPath)] where selected {
                var digest = baseEars[side.rawValue]?["sha256"] as? String
                if let path, earReviewIsCurrent(project, side: side, inspection: inspection), let review = inspection.document(URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("json")) { digest = review["output_sha256"] as? String }
                guard expected[side.rawValue] == digest else { return false }
            }
        } else if EarSide.allCases.contains(where: { earReviewIsCurrent(project, side: $0, inspection: inspection) }) { return false }
        return true
    }

    static func matchesStamp(_ url: URL, _ stamp: [String: Any], inspection: Inspection = Inspection()) -> Bool {
        guard let attrs = inspection.attributes(url),
              let size = attrs[.size] as? NSNumber, let date = attrs[.modificationDate] as? Date,
              let expectedSize = stamp["size"] as? NSNumber,
              let modified = stamp["mtime"] as? NSNumber else { return false }
        return size.int64Value == expectedSize.int64Value && abs(date.timeIntervalSince1970 - modified.doubleValue) < 0.001
    }

    static func postprocessingDirectory(for project: ProjectRecord) -> URL {
        if let folder = project.settings.postprocessing?.outputFolder { return URL(fileURLWithPath: folder) }
        return URL(fileURLWithPath: project.saveLocation).appendingPathComponent("HRTF")
    }

    static func fileHasData(_ url: URL, inspection: Inspection = Inspection()) -> Bool {
        guard let attributes = inspection.attributes(url),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    static func isSOFAContainer(_ url: URL, inspection: Inspection = Inspection()) -> Bool {
        guard fileHasData(url, inspection: inspection), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count == 8 else { return false }
        return data == Data([0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a])
            || (data.prefix(3) == Data("CDF".utf8) && [1, 2, 5].contains(data[3]))
    }

    static func containsMesh(_ url: URL, inspection: Inspection = Inspection()) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        let meshes = files.filter { ["stl", "ply"].contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare("graded_head") != .orderedSame }
        let validMeshes = meshes.filter { fileHasData($0, inspection: inspection) }
        return validMeshes.contains { $0.deletingPathExtension().lastPathComponent.hasPrefix("Prediction_") } || validMeshes.count == 1
    }

    static func containsSOFA(_ url: URL, inspection: Inspection = Inspection()) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension.lowercased() == "sofa" && isSOFAContainer($0, inspection: inspection) }
    }

    static func numcalcCompleted(_ project: URL, inspection: Inspection = Inspection()) -> Int {
        let source = project.appendingPathComponent("NumCalc/source_1")
        let files = (try? FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("be.out"), includingPropertiesForKeys: nil)) ?? []
        let completed = files.filter { path in
            guard path.lastPathComponent.hasPrefix("be."), let step = Int(path.lastPathComponent.dropFirst(3)) else { return false }
            return frequencyStepComplete(source: source, step: step, inspection: inspection)
        }.count
        return completed > 0 ? completed : containsSOFA(project.appendingPathComponent("Output2HRTF"), inspection: inspection) ? numcalcTotal(project, inspection: inspection) : 0
    }

    static func numcalcIsComplete(_ project: URL, inspection: Inspection = Inspection()) -> Bool {
        let total = numcalcTotal(project, inspection: inspection)
        guard total > 0 else { return false }
        let source = project.appendingPathComponent("NumCalc/source_1")
        return (1...total).allSatisfy { frequencyStepComplete(source: source, step: $0, inspection: inspection) }
    }

    static func frequencyStepComplete(source: URL, step: Int, inspection: Inspection = Inspection()) -> Bool {
        let log = source.appendingPathComponent("NC\(step)-\(step)_log.txt")
        if let complete = inspection.completedSteps[log] { return complete }
        let output = source.appendingPathComponent("be.out/be.\(step)")
        let required = ["pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"]
        let complete = required.allSatisfy { fileHasData(output.appendingPathComponent($0), inspection: inspection) }
            && ((try? String(contentsOf: log, encoding: .utf8))?.contains("---------- NumCalc ended:") == true)
        inspection.completedSteps[log] = complete
        return complete
    }

    static func numcalcTotal(_ project: URL, inspection: Inspection = Inspection()) -> Int {
        guard let object = inspection.document(project.appendingPathComponent("parameters.json")), let total = object["numFrequencies"] as? Int else { return 0 }
        return total
    }
}
