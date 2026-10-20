import Foundation

struct ProjectDuplicationRequest: Identifiable {
    let id = UUID()
    let project: ProjectRecord
    let suggestedName: String
    let parentFolder: String
}

/// Copy into a private staging folder and publish only a complete project.
/// Internal paths and source fingerprints move together; external inputs stay referenced.
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
        let fm = FileManager.default
        var destination = try destination(name: name, parentFolder: parentFolder)
        let resolved = destination.resolvingSymlinksInPath().path
        for path in projectRoots where !path.isEmpty {
            let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved != root, !resolved.hasPrefix(root + "/") else {
                throw ProjectValidation.Failure(message: "Choose a location outside existing project folders.")
            }
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw ProjectValidation.Failure(message: "A folder named \(destination.lastPathComponent) already exists here. Choose another name or save location.")
        }
        let source = URL(fileURLWithPath: original.saveLocation, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        let sourceExists = !original.saveLocation.isEmpty && fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let manual = original.settings.manualPPMFitting
        let hasStoredInputs = !original.leftEar.isEmpty || !original.rightEar.isEmpty || !original.scanPreparation.scanPath.isEmpty
            || [manual.leftMeshPath, manual.rightMeshPath, manual.leftParametersPath, manual.rightParametersPath,
                manual.leftBlendPath, manual.rightBlendPath].contains { !($0 ?? "").isEmpty }
        guard (sourceExists && isDirectory.boolValue) || (!sourceExists && !hasStoredInputs) else {
            throw ProjectValidation.Failure(message: "The original project folder is missing. Locate it before duplicating this project.")
        }
        let requestedParent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: requestedParent, withIntermediateDirectories: true)
        // Standardization can resolve aliases only once their parent exists.
        // Use the spelling meshIdentity will see after publishing the copy.
        let parent = requestedParent.standardizedFileURL
        destination = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        let staging = parent.appendingPathComponent(".pinna-duplicate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        if !sourceExists {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        } else {
            try fm.copyItem(at: source.resolvingSymlinksInPath(), to: staging)
        }

        func relocated(_ value: Any) throws -> Any {
            if let text = value as? String {
                if !original.saveLocation.isEmpty {
                    for oldPath in [original.saveLocation, source.path, source.resolvingSymlinksInPath().path] {
                        if text == oldPath || text.hasPrefix(oldPath + "/") {
                            return destination.path + String(text.dropFirst(oldPath.count))
                        }
                    }
                }
                // Imported projects preserve a JSON configuration snapshot as a string.
                if text.hasPrefix("{"), let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    let updated = try relocated(object)
                    return String(decoding: try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]), as: UTF8.self)
                }
                return text
            }
            if let values = value as? [String: Any] { return try values.mapValues { try relocated($0) } }
            if let values = value as? [Any] { return try values.map { try relocated($0) } }
            return value
        }
        let encoded = try JSONEncoder().encode(original)
        let object = try relocated(JSONSerialization.jsonObject(with: encoded))
        var duplicate = try JSONDecoder().decode(ProjectRecord.self, from: JSONSerialization.data(withJSONObject: object))
        duplicate.id = UUID()
        duplicate.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        duplicate.saveLocation = destination.path
        duplicate.stageOutcomes = nil
        duplicate.settings.preprocessing.sourcePositionInputLeft = nil
        duplicate.settings.preprocessing.sourcePositionInputRight = nil

        // Rebase structured metadata, including wrapped YAML paths, fitting templates,
        // prepared-ear provenance and output ownership. Never edit geometry or logs.
        var metadata: [URL] = []
        var enumerationError: Error?
        if let entries = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                       options: [], errorHandler: { _, error in enumerationError = error; return false }) {
            for case let url as URL in entries {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { entries.skipDescendants(); continue }
                if values.isRegularFile == true, ["json", "yaml", "yml"].contains(url.pathExtension.lowercased()) {
                    metadata.append(url)
                }
            }
        }
        if let enumerationError { throw enumerationError }
        for url in metadata {
            let isJSON = url.pathExtension.lowercased() == "json"
            let data = try Data(contentsOf: url)
            // Files with non-JSON diagnostic contents are copied without rewriting.
            if isJSON {
                guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
                let updated = try relocated(object)
                try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]).write(to: url, options: .atomic)
            } else {
                var object = try ProjectConfigDocument.parse(String(decoding: data, as: UTF8.self))
                if let updated = try relocated(object) as? [String: Any] {
                    object = updated
                    if url.lastPathComponent == "Project Settings.yaml" || url.lastPathComponent == "pipeline.yaml" || url.lastPathComponent == ".pinna2hrtf_native_run.yaml" {
                        var pre = object["preprocessing"] as? [String: Any] ?? [:]
                        pre["title"] = duplicate.name
                        pre.removeValue(forKey: "source_position_input_left")
                        pre.removeValue(forKey: "source_position_input_right")
                        object["preprocessing"] = pre
                    }
                    try ProjectConfigDocument.encode(object).write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
        // moveItem refuses an existing destination, including a folder created
        // during the copy. An unsuccessful copy never appears in the project list.
        try fm.moveItem(at: staging, to: destination)
        return duplicate
    }
}
