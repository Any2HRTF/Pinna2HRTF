import Foundation
import SceneKit
import ModelIO

/// Immutable preview input; mesh discovery and coordinate conversion run off the UI thread.
struct MicrophonePreview {
    let project: ProjectRecord
    let microphonePlacementMeshURL: URL?
    let pendingMicrophonePosition: ManualMicrophonePosition?
    let automaticMicrophonePositionsByMesh: [String: ManualMicrophonePosition]
    func microphonePosition(for meshURL: URL) -> SCNVector3? {
        let project = self.project
        guard let side = meshSide(for: meshURL, project: project) else { return nil }
        let meshPath = meshURL.standardizedFileURL.path
        let preprocessingPath = ArtifactScanner.preprocessingMesh(for: project, side: side)?.standardizedFileURL.path
        let simulationPath = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Intermediates/\(side.title)/graded_head.ply").standardizedFileURL.path
        guard meshPath == preprocessingPath || meshPath == simulationPath else { return nil }
        if let microphonePlacementMeshURL, microphonePlacementMeshURL.standardizedFileURL.path == meshURL.standardizedFileURL.path, let pendingMicrophonePosition {
            return microphoneDisplayPosition(SCNVector3(Float(pendingMicrophonePosition.x), Float(pendingMicrophonePosition.y), Float(pendingMicrophonePosition.z)), meshURL: meshURL, project: project, side: side, positionIsInput: true)
        }
        if let position = ArtifactScanner.validManualMicrophonePosition(for: project, side: side) ?? ArtifactScanner.manualMicrophonePosition(for: project, side: side) {
            return microphoneDisplayPosition(SCNVector3(Float(position.x), Float(position.y), Float(position.z)), meshURL: meshURL, project: project, side: side, positionIsInput: true)
        }
        if let identity = ArtifactScanner.meshIdentity(meshURL) {
            for position in automaticMicrophonePositionsByMesh.values where position.meshPath == meshURL.standardizedFileURL.path && position.meshIdentity == identity {
                return microphoneDisplayPosition(SCNVector3(Float(position.x), Float(position.y), Float(position.z)), meshURL: meshURL, project: project, side: side, positionIsInput: true)
            }
        }
        let parametersURL = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Projects/\(side.title)/parameters.json")
        guard let data = try? Data(contentsOf: parametersURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = object["sourceCenter"] as? [NSNumber], values.count == 3 else { return nil }
        return microphoneDisplayPosition(SCNVector3(Float(values[0].doubleValue * 1000), Float(values[1].doubleValue * 1000), Float(values[2].doubleValue * 1000)), meshURL: meshURL, project: project, side: side, positionIsInput: false)
    }

    func microphoneDisplayPosition(_ position: SCNVector3, meshURL: URL, project: ProjectRecord, side: EarSide, positionIsInput: Bool) -> SCNVector3 {
        guard project.settings.preprocessing.earDistance != nil else { return position }
        let sourceMesh = ArtifactScanner.preprocessingMesh(for: project, side: side)
        let translatedMesh = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Intermediates/\(side.title)/input_ear.stl")
        guard let sourceMesh, FileManager.default.fileExists(atPath: translatedMesh.path), let sourceCenterY = meshCenterY(sourceMesh), let translatedCenterY = meshCenterY(translatedMesh) else { return position }
        let translation = translatedCenterY - sourceCenterY
        let simulationPath = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Intermediates/\(side.title)/graded_head.ply").standardizedFileURL.path
        if meshURL.standardizedFileURL.path == simulationPath {
            return positionIsInput ? SCNVector3(CGFloat(position.x), CGFloat(position.y) + CGFloat(translation), CGFloat(position.z)) : position
        }
        return positionIsInput ? position : SCNVector3(CGFloat(position.x), CGFloat(position.y) - CGFloat(translation), CGFloat(position.z))
    }

    func meshCenterY(_ url: URL) -> Float? {
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        let bounds = asset.boundingBox
        return (bounds.minBounds.y + bounds.maxBounds.y) / 2
    }

    func meshSide(for meshURL: URL, project: ProjectRecord) -> EarSide? {
        let path = meshURL.standardizedFileURL.path
        if !project.pipelineLeftEar.isEmpty && path == URL(fileURLWithPath: project.pipelineLeftEar).standardizedFileURL.path { return .left }
        if !project.pipelineRightEar.isEmpty && path == URL(fileURLWithPath: project.pipelineRightEar).standardizedFileURL.path { return .right }
        let output = URL(fileURLWithPath: project.saveLocation).standardizedFileURL
        let leftPrefixes = [
            output.appendingPathComponent("Intermediates/Left").path,
            output.appendingPathComponent(project.settings.inference.predictionLeftFolder).path,
            output.appendingPathComponent("Projects/Left").path
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let rightPrefixes = [
            output.appendingPathComponent("Intermediates/Right").path,
            output.appendingPathComponent(project.settings.inference.predictionRightFolder).path,
            output.appendingPathComponent("Projects/Right").path
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if leftPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .left }
        if rightPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .right }
        let projectPath = output.path
        guard path == projectPath || path.hasPrefix(projectPath + "/") else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        if components.contains(where: { $0 == "left" || $0.contains("left") }) { return .left }
        if components.contains(where: { $0 == "right" || $0.contains("right") }) { return .right }
        return nil
    }

}
