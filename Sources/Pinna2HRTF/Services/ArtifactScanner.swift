import Foundation
import CryptoKit

enum ArtifactScanner {
    /// One refresh owns one inspection; subsequent refreshes always read fresh files.
    final class Inspection {
        private var documents: [URL: [String: Any]?] = [:]
        private var metadata: [URL: [FileAttributeKey: Any]?] = [:]
        fileprivate var completedSteps: [URL: Bool] = [:]
        let isCancelled: () -> Bool

        init(isCancelled: @escaping () -> Bool = { false }) { self.isCancelled = isCancelled }

        func document(_ url: URL) -> [String: Any]? {
            if let cached = documents[url] { return cached }
            let result = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            documents.updateValue(result, forKey: url)
            return result
        }

        func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
            if let cached = metadata[url] { return cached }
            // FileManager's full attribute dictionary also fetches extended attributes.
            // On SMB volumes those extra requests block status and validation views.
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let values = try? freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey])
            let result: [FileAttributeKey: Any]?
            if let values, values.fileResourceType == .regular,
               let size = values.fileSize, let modified = values.contentModificationDate {
                result = [.size: NSNumber(value: size), .modificationDate: modified, .type: FileAttributeType.typeRegular]
            } else if values != nil {
                // Preserve existing behavior for directories, symbolic links and special files.
                result = try? FileManager.default.attributesOfItem(atPath: url.path)
            } else {
                result = nil
            }
            metadata.updateValue(result, forKey: url)
            return result
        }
    }

    static func artifacts(for project: ProjectRecord, inspection: Inspection = Inspection(), includeSolverResults: Bool = true) -> [Artifact] {
        let leftEar = project.pipelineEar(for: .left, inspection: inspection)
        let rightEar = project.pipelineEar(for: .right, inspection: inspection)
        let output = URL(fileURLWithPath: project.saveLocation, isDirectory: true)
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
        for side in EarSide.allCases where includeSolverResults && !inspection.isCancelled() {
            let solver = output.appendingPathComponent("Projects/\(side.title)/NumCalc", isDirectory: true)
            let sources = (try? FileManager.default.contentsOfDirectory(at: solver, includingPropertiesForKeys: nil)) ?? []
            for source in sources.filter({ $0.lastPathComponent.hasPrefix("source_") }).sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let input = source.appendingPathComponent("NC.inp", isDirectory: false)
                let steps = (try? FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("be.out", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
                if FileManager.default.fileExists(atPath: input.path), steps.contains(where: {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("pBoundary", isDirectory: false).path) || FileManager.default.fileExists(atPath: $0.appendingPathComponent("pEvalGrid", isDirectory: false).path)
                }) {
                    let name = source.lastPathComponent.replacingOccurrences(of: "source_", with: "Source ")
                    next.append(Artifact(title: "\(side.title) pressure · \(name)", url: input))
                }
            }
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
        let folder = URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent(folderName)
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
              meshIdentityMatches(sourceIdentity, meshIdentity(source, inspection: inspection)),
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

    static func stageStates(for project: ProjectRecord, runningStage: Stage?, failedStages: Set<Stage>, inspection: Inspection = Inspection(), completedStages: Set<Stage>? = nil) -> [Stage: StageState] {
        Dictionary(uniqueKeysWithValues: Stage.allCases.map { stage in
            if runningStage == stage {
                return (stage, .running)
            }
            if stage == .scanPreparation && !project.scanPreparation.enabled { return (stage, .skipped) }
            let complete = completedStages?.contains(stage) ?? stageIsComplete(stage, project: project, inspection: inspection)
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
        return URL(fileURLWithPath: project.saveLocation, isDirectory: true).lastPathComponent
    }

    static func numcalcStatus(for project: ProjectRecord, inspection: Inspection = Inspection()) -> String {
        let output = URL(fileURLWithPath: project.saveLocation, isDirectory: true)
        let sides = [("Left", project.pipelineEar(for: .left, inspection: inspection)), ("Right", project.pipelineEar(for: .right, inspection: inspection))].compactMap { side, ear in
            ear.isEmpty ? nil : "\(side) \(numcalcCompleted(output.appendingPathComponent("Projects/\(side)"), inspection: inspection))/\(numcalcTotal(output.appendingPathComponent("Projects/\(side)"), inspection: inspection))"
        }
        return sides.isEmpty ? "NumCalc: no ear selected" : "NumCalc: " + sides.joined(separator: " · ")
    }

    static func stageIsComplete(_ stage: Stage, project: ProjectRecord, inspection: Inspection = Inspection()) -> Bool {
        let output = URL(fileURLWithPath: project.saveLocation, isDirectory: true)
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
                let folder = output.appendingPathComponent("Projects/\(side.title)", isDirectory: true)
                return containsSOFA(folder.appendingPathComponent("Output2HRTF", isDirectory: true), inspection: inspection)
                    || numcalcIsComplete(folder, inspection: inspection)
            }
        case .postprocessing:
            let folder = postprocessingDirectory(for: project)
            return containsSOFA(folder, inspection: inspection) && spatialUpsamplingIsCurrent(project, inspection: inspection)
        }
    }

    /// Filesystem timestamps may round slightly when a project is copied between
    /// volumes or serialized through JSON. Preserve source validation without
    /// treating sub-microsecond representation differences as changed geometry.
    static func meshIdentityMatches(_ saved: String, _ current: String?) -> Bool {
        guard let current else { return false }
        if saved == current { return true }
        let a = saved.components(separatedBy: "|")
        let b = current.components(separatedBy: "|")
        guard a.count >= 3, b.count >= 3,
              a.dropLast(2) == b.dropLast(2),
              a[a.count - 2] == b[b.count - 2],
              let first = Double(a[a.count - 1]), let second = Double(b[b.count - 1]) else { return false }
        return abs(first - second) < 0.000001
    }

    static func preprocessingSignature(for project: ProjectRecord, inspection: Inspection = Inspection()) -> String {
        PreprocessingSignature.capture(project, inspection: inspection)
    }

    static func scanPreparationIsCurrent(_ project: ProjectRecord, inspection: Inspection = Inspection()) -> Bool {
        let scan = project.scanPreparation
        let root = URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent("Prepared")
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
        let folder = URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent("Prepared")
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
        return URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent("Prepared/\(side.title).stl")
    }

    static func preparedEarSide(for mesh: URL, in project: ProjectRecord, inspection: Inspection = Inspection()) -> EarSide? {
        for side in EarSide.allCases where preparedEarURL(for: side, in: project, inspection: inspection)?.standardizedFileURL.path == mesh.standardizedFileURL.path {
            return side
        }
        return nil
    }

    static func scanReceiptIsCurrent(_ project: ProjectRecord, stage: String, inspection: Inspection = Inspection()) -> Bool {
        let folder = URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent("Prepared")
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
        return URL(fileURLWithPath: project.saveLocation, isDirectory: true).appendingPathComponent("HRTF")
    }

    static func spatialUpsamplingIsCurrent(_ project: ProjectRecord, inspection: Inspection = Inspection()) -> Bool {
        let settings = project.settings.postprocessing ?? PostprocessingSettings()
        guard settings.spatialUpsampling else { return true }
        let root = postprocessingDirectory(for: project)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return false }
        let sources = files.filter { $0.lastPathComponent.hasPrefix("HRIR_") && $0.pathExtension.lowercased() == "sofa" }
        let denseName = "hrtf_Nd=\(settings.spatialSubdivisions)\(settings.spatialSubdivisions == 0 ? "_dense" : "").sofa"
        return !sources.isEmpty && sources.allSatisfy { source in
            let folder = root.appendingPathComponent("Upsampled/\(source.deletingPathExtension().lastPathComponent)", isDirectory: true)
            let target = folder.appendingPathComponent(denseName, isDirectory: false)
            guard let receipt = inspection.document(folder.appendingPathComponent("upsampling.json", isDirectory: false)),
                  receipt["method"] as? String == "LocaDyn-1948",
                  receipt["subdivisions"] as? Int == settings.spatialSubdivisions,
                  receipt["normalize"] as? Bool == settings.spatialNormalize,
                  let inputStamp = receipt["input"] as? [String: Any], let outputStamp = receipt["output"] as? [String: Any] else { return false }
            return matchesStamp(source, inputStamp, inspection: inspection) && matchesStamp(target, outputStamp, inspection: inspection) && isSOFAContainer(target, inspection: inspection)
        }
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
        if containsSOFA(project.appendingPathComponent("Output2HRTF", isDirectory: true), inspection: inspection) {
            return numcalcTotal(project, inspection: inspection)
        }
        let source = project.appendingPathComponent("NumCalc/source_1", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: source.appendingPathComponent("be.out", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
        let completed = files.filter { path in
            guard !inspection.isCancelled(), path.lastPathComponent.hasPrefix("be."), let step = Int(path.lastPathComponent.dropFirst(3)) else { return false }
            return frequencyStepComplete(source: source, step: step, inspection: inspection)
        }.count
        return completed > 0 ? completed : containsSOFA(project.appendingPathComponent("Output2HRTF", isDirectory: true), inspection: inspection) ? numcalcTotal(project, inspection: inspection) : 0
    }

    static func numcalcIsComplete(_ project: URL, inspection: Inspection = Inspection()) -> Bool {
        let total = numcalcTotal(project, inspection: inspection)
        guard total > 0 else { return false }
        let source = project.appendingPathComponent("NumCalc/source_1", isDirectory: true)
        return (1...total).allSatisfy { frequencyStepComplete(source: source, step: $0, inspection: inspection) }
    }

    static func frequencyStepComplete(source: URL, step: Int, inspection: Inspection = Inspection()) -> Bool {
        guard !inspection.isCancelled() else { return false }
        let log = source.appendingPathComponent("NC\(step)-\(step)_log.txt", isDirectory: false)
        if let complete = inspection.completedSteps[log] { return complete }
        let output = source.appendingPathComponent("be.out/be.\(step)", isDirectory: true)
        let required = ["pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"]
        let complete = required.allSatisfy { fileHasData(output.appendingPathComponent($0, isDirectory: false), inspection: inspection) }
            && ((try? String(contentsOf: log, encoding: .utf8))?.contains("---------- NumCalc ended:") == true)
        inspection.completedSteps[log] = complete
        return complete
    }

    static func numcalcTotal(_ project: URL, inspection: Inspection = Inspection()) -> Int {
        guard let object = inspection.document(project.appendingPathComponent("parameters.json", isDirectory: false)), let total = object["numFrequencies"] as? Int else { return 0 }
        return total
    }
}

/// Compares the inputs and effective settings that determine preprocessing results.
/// Storage locations, input-copy policy, and inactive settings are deliberately absent.
enum PreprocessingSignature {
    private static let format = "pinna2hrtf-preprocessing-v2"
    private static let cacheLock = NSLock()
    private static var digests: [String: String] = [:]

    static func capture(_ project: ProjectRecord, inspection: ArtifactScanner.Inspection) -> String {
        var value = configuration(project)
        value["format"] = format
        var inputs: [String: String] = [:]
        for side in EarSide.allCases {
            inputs[side.rawValue] = fingerprint(project.pipelineEar(for: side, inspection: inspection), inspection: inspection)
            if project.settings.manualPPMFitting.useForPreprocessing {
                inputs["fitted_" + side.rawValue] = fingerprint(project.settings.manualPPMFitting.meshPath(for: side) ?? "", inspection: inspection)
            } else if project.settings.inference.usePredictionsForPreprocessing {
                inputs["predicted_" + side.rawValue] = fingerprint(ArtifactScanner.preprocessingMesh(for: project, side: side, inspection: inspection)?.path ?? "", inspection: inspection)
            }
        }
        if project.settings.inference.usePredictionsForPreprocessing && !project.settings.manualPPMFitting.useForPreprocessing {
            inputs["model_config"] = fingerprint(project.settings.inference.modelConfig, inspection: inspection)
            inputs["model_checkpoint"] = fingerprint(project.settings.inference.modelCheckpoint, inspection: inspection)
        }
        if project.scanPreparation.enabled { inputs["scan"] = fingerprint(project.scanPreparation.scanPath, inspection: inspection) }
        let grid = gridPath(project.settings.preprocessing.evaluationGrid)
        for name in ["Nodes.txt", "Elements.txt"] {
            inputs["grid_" + name] = fingerprint(URL(fileURLWithPath: grid).appendingPathComponent(name).path, inspection: inspection)
        }
        value["inputs"] = inputs
        return encoded(value)
    }

    static func matches(_ saved: String, project: ProjectRecord, current: String? = nil,
                        inspection: ArtifactScanner.Inspection = .init()) -> Bool {
        let next = current ?? capture(project, inspection: inspection)
        if saved == next { return true }
        // Early receipts contain seven fields; later ones add three manual-fit
        // fields and an optional scan-settings field.
        // Never blindly accept a legacy receipt or re-baseline genuinely changed settings.
        var fields = saved.components(separatedBy: "\n")
        if fields.count == 7 { fields += ["", "", ""] }
        guard fields.count == 10 || fields.count == 11,
              let inference = decode(InferenceSettings.self, fields[5]),
              let preprocessing = decode(PreprocessingSettings.self, fields[6]) else { return false }
        var previous = project
        previous.leftEar = fields[0]; previous.rightEar = fields[1]
        previous.settings.inference = inference
        previous.settings.preprocessing = preprocessing
        if fields[7].isEmpty { previous.settings.manualPPMFitting = ManualPPMFittingSettings() }
        else if let manual = decode(ManualPPMFittingSettings.self, fields[7]) { previous.settings.manualPPMFitting = manual }
        else { return false }
        previous.settings.scanPreparation = nil
        if fields.count == 11 {
            guard let scan = decode(ScanPreparationSettings.self, fields[10]) else { return false }
            previous.settings.scanPreparation = scan
        }
        guard encoded(configuration(previous)) == encoded(configuration(project)) else { return false }
        var relocations: [(String, String)] = []
        for (old, new) in [(previous.leftEar, project.leftEar), (previous.rightEar, project.rightEar)] {
            guard !old.isEmpty, !new.isEmpty else { continue }
            let a = URL(fileURLWithPath: old).pathComponents
            let b = URL(fileURLWithPath: new).pathComponents
            var count = 0
            while count < min(a.count, b.count), a[a.count - count - 1] == b[b.count - count - 1] { count += 1 }
            if count > 0 && count < min(a.count, b.count) {
                let from = NSString.path(withComponents: Array(a.dropLast(count)))
                let to = NSString.path(withComponents: Array(b.dropLast(count)))
                if from != "/", to != "/" { relocations.append((from, to)) }
            }
        }
        for (old, new, stamp) in [(fields[0], project.pipelineEar(for: .left, inspection: inspection), fields[3]),
                                   (fields[1], project.pipelineEar(for: .right, inspection: inspection), fields[4])] {
            guard legacyInputMatches(old, new, stamp: stamp, inspection: inspection) else { return false }
        }
        if project.settings.manualPPMFitting.useForPreprocessing {
            for (side, index) in [(EarSide.left, 8), (.right, 9)] {
                guard legacyInputMatches(previous.settings.manualPPMFitting.meshPath(for: side) ?? "",
                                         project.settings.manualPPMFitting.meshPath(for: side) ?? "",
                                         stamp: fields[index], inspection: inspection) else { return false }
            }
        } else if project.settings.inference.usePredictionsForPreprocessing {
            guard resourceMatches(inference.modelConfig, project.settings.inference.modelConfig, relocations: relocations, inspection: inspection),
                  resourceMatches(inference.modelCheckpoint, project.settings.inference.modelCheckpoint, relocations: relocations, inspection: inspection) else { return false }
        }
        if project.scanPreparation.enabled &&
            !resourceMatches(previous.scanPreparation.scanPath, project.scanPreparation.scanPath, relocations: relocations, inspection: inspection) { return false }
        return resourceMatches(gridPath(previous.settings.preprocessing.evaluationGrid), gridPath(project.settings.preprocessing.evaluationGrid),
                               relocations: relocations, directory: true, inspection: inspection)
    }

    private static func configuration(_ project: ProjectRecord) -> [String: Any] {
        var pre = object(project.settings.preprocessing)
        pre.removeValue(forKey: "evaluationGrid")
        pre["skipMeshGrading"] = project.settings.preprocessing.skipMeshGrading ?? false
        pre["sourceAssignmentFaceCount"] = project.settings.preprocessing.sourceAssignmentFaceCount ?? "6"
        for (name, position) in [("sourcePositionInputLeft", project.settings.preprocessing.sourcePositionInputLeft),
                                  ("sourcePositionInputRight", project.settings.preprocessing.sourcePositionInputRight)] {
            pre.removeValue(forKey: name)
            if let position { pre[name] = [position.x, position.y, position.z] }
        }
        let manual = project.settings.manualPPMFitting.useForPreprocessing
        var result: [String: Any] = ["preprocessing": pre,
            "inputMode": manual ? "manual" : project.settings.inference.usePredictionsForPreprocessing ? "inference" : "original"]
        // Imported physical/geometry overrides also affect results; GUI values are
        // represented above, and bookkeeping/export-only choices do not affect the solver.
        if let json = project.preservedConfigJSON?.data(using: .utf8),
           let document = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           var hidden = document["preprocessing"] as? [String: Any] {
            for key in ["title", "enabled", "write_intermediates", "pictures", "material_search_paths",
                        "min_frequency", "max_frequency", "frequency_step_count", "mesh_min_edge_length",
                        "mesh_max_edge_length", "mesh_max_error", "mesh_gamma", "mesh_gamma_opposite",
                        "head_radius", "skip_mesh_grading", "source_assignment_face_count", "source_position_input_left", "source_position_input_right"] {
                hidden.removeValue(forKey: key)
            }
            if !hidden.isEmpty { result["importedPreprocessing"] = hidden }
        }
        if project.scanPreparation.enabled {
            var scan = object(project.scanPreparation)
            for key in ["scanPath", "originalScanPath", "reviewedLeftPath", "reviewedRightPath", "requireManualReview"] { scan.removeValue(forKey: key) }
            result["scanPreparation"] = scan
        }
        return normalized(result) as? [String: Any] ?? result
    }

    private static func legacyInputMatches(_ old: String, _ new: String, stamp: String,
                                           inspection: ArtifactScanner.Inspection) -> Bool {
        if old.isEmpty || new.isEmpty { return old.isEmpty && new.isEmpty }
        let fields = stamp.components(separatedBy: "|")
        if fields.count >= 3, let size = Int64(fields[fields.count - 2]), let modified = Double(fields[fields.count - 1]),
           let attrs = inspection.attributes(URL(fileURLWithPath: new)),
           (attrs[.size] as? NSNumber)?.int64Value == size,
           let date = attrs[.modificationDate] as? Date,
           abs(date.timeIntervalSince1970 - modified) < 0.00001 { return true }
        if old == new { return stamp.isEmpty && ArtifactScanner.meshIdentity(URL(fileURLWithPath: new), inspection: inspection) == nil }
        let oldDigest = fingerprint(old, inspection: inspection)
        return oldDigest.hasPrefix("sha256:") && oldDigest == fingerprint(new, inspection: inspection)
    }

    private static func resourceMatches(_ old: String, _ new: String, relocations: [(String, String)],
                                        directory: Bool = false, inspection: ArtifactScanner.Inspection) -> Bool {
        if old == new { return true }
        // A legacy receipt has no resource hashes. A consistent project-root move
        // is accepted only after both ear stamps were verified above.
        if relocations.contains(where: { from, to in
            (old == from || old.hasPrefix(from + "/")) && to + String(old.dropFirst(from.count)) == new
        }) { return true }
        if directory {
            return ["Nodes.txt", "Elements.txt"].allSatisfy { name in
                resourceMatches(URL(fileURLWithPath: old).appendingPathComponent(name).path,
                                URL(fileURLWithPath: new).appendingPathComponent(name).path,
                                relocations: [], inspection: inspection)
            }
        }
        let digest = fingerprint(old, inspection: inspection)
        return digest.hasPrefix("sha256:") && digest == fingerprint(new, inspection: inspection)
    }

    private static func gridPath(_ value: String?) -> String {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value == "Default"
            ? Defaults.pipelineRoot.appendingPathComponent("HRTFCalculation/Preprocessing/Resources/ARIGrid").path : value
    }

    private static func fingerprint(_ path: String, inspection: ArtifactScanner.Inspection) -> String {
        if path.isEmpty { return "" }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let attrs = inspection.attributes(url), attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, let date = attrs[.modificationDate] as? Date else { return "unavailable" }
        let key = "\(url.path)|\(size.int64Value)|\(date.timeIntervalSince1970)"
        cacheLock.lock(); let cached = digests[key]; cacheLock.unlock()
        if let cached { return cached }
        guard let file = try? FileHandle(forReadingFrom: url) else { return "unavailable" }
        defer { try? file.close() }
        do {
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            let digest = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
            cacheLock.lock()
            if digests.count > 512 { digests.removeAll(keepingCapacity: true) }
            digests[key] = digest
            cacheLock.unlock()
            return digest
        } catch { return "unavailable" }
    }

    private static func object<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        text.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private static func normalized(_ value: Any) -> Any {
        if let values = value as? [String: Any] { return values.mapValues(normalized) }
        if let values = value as? [Any] { return values.map(normalized) }
        if let text = value as? String, let number = Double(text), number.isFinite { return number }
        return value
    }
    private static func encoded(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
