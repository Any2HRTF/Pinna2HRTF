import Foundation

final class GeneratedOutputManifest {
    enum OutputStage: String, Codable, CaseIterable {
        case scanPreparation = "Scan-Preparation"
        case inference = "Inference", preprocessing = "Preprocessing"
        case numcalc = "Numcalc", postprocessing = "Postprocessing"
        var order: Int { Self.allCases.firstIndex(of: self)! }
    }
    struct ResetResult: Decodable {
        var fromStage: OutputStage? = nil
        var deleted = 0, modified = 0, protectedInputs = 0, nonEmpty = 0, errors = 0

        var success: Bool { errors == 0 }
        var summary: String {
            "Outputs reset (\(fromStage?.rawValue ?? "all")): deleted \(deleted), kept modified \(modified), kept input files \(protectedInputs), kept non-empty directories \(nonEmpty), errors \(errors)."

        }
    }
    enum Failure: LocalizedError {
        case invalidRoot, unsafePath, busy, invalidManifest, changingFile
        var errorDescription: String? {
            switch self {
            case .invalidRoot: "Choose a separate project output folder."
            case .unsafePath: "Linked or protected output paths cannot be managed automatically."
            case .busy: "Project outputs are busy."
            case .invalidManifest: "The generated-output manifest is invalid or unsupported."
            case .changingFile: "An output file is still changing."
            }
        }
    }
    private let request: [String: Any]
    let protectedInputs: [String]
    private let root: URL
    private let gate = NSLock()
    private var worker: CLIWorker?
    private(set) var token = ""

    init(projectRoot: String, inputs: [String], outputFolder: String? = nil) throws {
        guard !projectRoot.isEmpty, projectRoot != "/" else { throw Failure.invalidRoot }
        root = URL(fileURLWithPath: projectRoot)
        protectedInputs = inputs
        request = ["root": projectRoot, "inputs": inputs, "output_folder": outputFolder ?? ""]
    }

    func begin(_ stage: OutputStage) throws {
        gate.lock()
        defer { gate.unlock() }
        guard worker == nil else { throw Failure.busy }
        guard let python = ProjectConfigDocument.pythonURL else { throw Failure.invalidRoot }
        let session = try CLIWorker(pythonURL: python, workingDirectory: Defaults.pipelineRoot,
                                    command: "output-worker", timeout: 3600)
        var payload = request
        payload["stage"] = stage.rawValue
        let data = try session.execute(JSONSerialization.data(withJSONObject: payload))
        struct Ready: Decodable { let ready: Bool; let token: String }
        let ready = try JSONDecoder().decode(Ready.self, from: data)
        guard ready.ready else { throw Failure.invalidManifest }
        token = ready.token
        worker = session
    }

    func complete() throws {
        gate.lock()
        defer { gate.unlock() }
        guard let session = worker else { return }
        defer { worker = nil }
        let data = try session.execute(JSONSerialization.data(withJSONObject: ["action": "complete"]))
        guard (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["complete"] == true else { throw Failure.invalidManifest }
    }

    private func perform(_ fields: [String: Any]) throws -> Data {
        let payload = request.merging(fields) { _, new in new }
        return try ProjectConfigDocument.run(["-m", "HRTFCalculation", "outputs"],
            input: JSONSerialization.data(withJSONObject: payload), timeout: 3600, operation: "Project outputs")
    }

    func recordGeneratedFiles(_ urls: [URL]) throws {
        _ = try perform(["action": "record", "paths": urls.map(\.path)])
    }

    func reset(from stage: OutputStage? = nil) -> ResetResult {
        guard FileManager.default.fileExists(atPath: root.path) else { return ResetResult(fromStage: stage) }
        do {
            let data = try perform(["action": "reset", "stage": stage?.rawValue ?? ""])
            var result = try JSONDecoder().decode(ResetResult.self, from: data)
            result.fromStage = stage
            return result
        } catch { return ResetResult(fromStage: stage, errors: 1) }
    }
}
