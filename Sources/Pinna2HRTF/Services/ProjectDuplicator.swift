import Foundation

struct ProjectDuplicationRequest: Identifiable {
    let id = UUID()
    let project: ProjectRecord
    let suggestedName: String
    let parentFolder: String
}

enum ProjectDuplicator {
    static func destination(name: String, parentFolder: String) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, ![".", ".."].contains(name),
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw ProjectValidation.Failure(message: "Enter a project name without / or :.")
        }
        let parent = (parentFolder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard parent.hasPrefix("/") else {
            throw ProjectValidation.Failure(message: "Enter an absolute save location or choose a folder.")
        }
        return URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name, isDirectory: true).standardizedFileURL
    }

    static func duplicate(_ original: ProjectRecord, name: String, parentFolder: String,
                          projectRoots: [String]) throws -> ProjectRecord {
        let destination = try destination(name: name, parentFolder: parentFolder)
        let manual = original.settings.manualPPMFitting
        let inputs = [original.leftEar, original.rightEar, original.scanPreparation.scanPath,
                      manual.leftMeshPath, manual.rightMeshPath, manual.leftParametersPath,
                      manual.rightParametersPath, manual.leftBlendPath, manual.rightBlendPath]
        let command: [String: Any] = [
            "source": original.saveLocation,
            "parent": destination.deletingLastPathComponent().path,
            "name": destination.lastPathComponent,
            "project_roots": projectRoots,
            "empty_project": inputs.allSatisfy { ($0 ?? "").isEmpty },
            "mac_record": try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        ]
        struct Reply: Decodable { let project: ProjectRecord }
        let response = try ProjectConfigDocument.run(["-m", "HRTFCalculation", "project", "duplicate"],
            input: JSONSerialization.data(withJSONObject: command), timeout: 600, operation: "Project duplication")
        return try JSONDecoder().decode(Reply.self, from: response).project
    }
}
