import Foundation
import CryptoKit

enum StageReceipt {
    static func url(_ stage: Stage, _ project: ProjectRecord) -> URL {
        URL(fileURLWithPath: project.saveLocation).appendingPathComponent(".pinna2hrtf-\(stage.rawValue)-receipt.json")
    }
    private static func legacySignature(_ stage: Stage, _ project: ProjectRecord) -> String {
        var value: [String: Any] = [:]
        func stamp(_ path: String) -> String {
            guard !path.isEmpty else { return "" }
            return PreprocessingSignature.fileFingerprint(path)
        }
        if stage == .inference {
            var settings = project.settings.inference
            settings.modelCheckpoint = PreprocessingSignature.sourceCheckpointPath(settings.modelCheckpoint)
            value["settings"] = try? JSONEncoder.pretty.encode(settings).base64EncodedString()
            for side in EarSide.allCases {
                value[side.rawValue] = stamp(project.pipelineEar(for: side))
                value["prediction_" + side.rawValue] = stamp(ArtifactScanner.preprocessingMesh(for: project, side: side)?.path ?? "")
            }
            value["model"] = stamp(project.settings.inference.modelConfig)
            value["checkpoint"] = PreprocessingSignature.checkpointFingerprint(project.settings.inference.modelCheckpoint)
        } else {
            value["settings"] = try? JSONEncoder.pretty.encode(project.settings.postprocessing ?? PostprocessingSettings()).base64EncodedString()
            value["preprocessing"] = ArtifactScanner.preprocessingSignature(for: project)
            let exported = ArtifactScanner.postprocessingDirectory(for: project)
            let exportFiles = (try? FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)) ?? []
            value["exports"] = Dictionary(uniqueKeysWithValues: exportFiles.filter { $0.pathExtension == "sofa" }.map { ($0.lastPathComponent, stamp($0.path)) })
            for side in EarSide.allCases where !project.pipelineEar(for: side).isEmpty {
                let source = URL(fileURLWithPath: project.saveLocation).appendingPathComponent("Projects/\(side.title)/Output2HRTF")
                let files = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
                value[side.rawValue] = Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "sofa" }.map { ($0.lastPathComponent, stamp($0.path)) })
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func request(_ action: String, _ stage: Stage, _ project: ProjectRecord) throws -> Data {
        let config = PipelineConfigWriter.mapping(project: project, environment: Defaults.environment(root: Defaults.runtimeRoot))
        return try ProjectConfigDocument.request(action, ["config": config, "stage": stage.rawValue], timeout: 600)
    }

    static func current(_ stage: Stage, _ project: ProjectRecord) -> Bool {
        let data = try? Data(contentsOf: url(stage, project))
        if stage == .preprocessing || data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) is [String: Any] {
            struct Reply: Decodable { let current: Bool }
            guard let response = try? request("stage-status", stage, project) else { return false }
            return (try? JSONDecoder().decode(Reply.self, from: response).current) == true
        }
        guard let data else { return false }
        return String(data: data, encoding: .utf8) == legacySignature(stage, project)
    }
}
