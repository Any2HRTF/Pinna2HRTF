import Foundation

enum StageReceipt {
    static func current(_ stage: Stage, _ project: ProjectRecord) -> Bool {
        struct Verdict: Decodable { let current: Bool }
        let config = PipelineConfigWriter.mapping(project: project, environment: Defaults.environment(root: Defaults.runtimeRoot))
        guard let record = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(project)),
              let response = try? ProjectConfigDocument.request("stage-status", ["config": config, "stage": stage.rawValue, "app": "mac", "project": record], timeout: 600)
        else { return false }
        return (try? JSONDecoder().decode(Verdict.self, from: response).current) == true
    }
}
