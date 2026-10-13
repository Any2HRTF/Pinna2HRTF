import Foundation

final class ProjectRegistryStore {
    let url: URL
    let rootURL: URL
    let packageURL: URL
    private(set) var recoveryMessage: String?
    private(set) var savingBlocked = false
    private(set) var lastError: String?
    var backupURL: URL { url.deletingPathExtension().appendingPathExtension("backup.json") }

    init(rootURL: URL, packageURL: URL, url: URL = Defaults.appDataURL.appendingPathComponent("projects.json")) {
        self.rootURL = rootURL
        self.packageURL = packageURL
        self.url = url
    }

    private func decode(_ data: Data) -> ProjectRegistry? {
        if let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data) { return registry }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let migrated = Self.migrateLegacyMeshSettings(object),
              let data = try? JSONSerialization.data(withJSONObject: migrated) else { return nil }
        return try? JSONDecoder().decode(ProjectRegistry.self, from: data)
    }

    func load() -> ProjectRegistry {
        if let data = try? Data(contentsOf: url), let registry = decode(data) { return registry }
        let originalExists = FileManager.default.fileExists(atPath: url.path)
        let backup = (try? Data(contentsOf: backupURL)).flatMap(decode)
        if originalExists || FileManager.default.fileExists(atPath: backupURL.path) {
            savingBlocked = true
            recoveryMessage = backup != nil
                ? "The project list could not be read. A saved backup is available. Restore it to continue saving changes; the original file will be preserved."
                : "The project list could not be read. The original file is protected. You can start an empty list while preserving that file for recovery. Project files will remain in their current locations."
        }
        return backup ?? ProjectRegistry(projects: [], selectedProjectID: nil, environment: Defaults.environment(root: rootURL))
    }

    @discardableResult
    func recover(using registry: ProjectRegistry) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let preserved = url.deletingLastPathComponent().appendingPathComponent("projects-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: preserved)
            }
            if let backupData = try? Data(contentsOf: backupURL), decode(backupData) == nil {
                let preserved = url.deletingLastPathComponent().appendingPathComponent("projects-backup-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: backupURL, to: preserved)
            }
            try JSONEncoder.pretty.encode(registry).write(to: url, options: .atomic)
            savingBlocked = false
            recoveryMessage = nil
            lastError = nil
            return true
        } catch {
            lastError = "Could not recover the project list: \(error.localizedDescription)"
            return false
        }
    }

    static func migrateLegacyMeshSettings(_ value: Any) -> Any? {
        if var dictionary = value as? [String: Any] {
            if dictionary["meshGammaLeft"] != nil || dictionary["meshGammaRight"] != nil {
                if dictionary["meshGamma"] == nil { dictionary["meshGamma"] = "0.2" }
                if dictionary["meshGammaOpposite"] == nil { dictionary["meshGammaOpposite"] = "0.1" }
                dictionary.removeValue(forKey: "meshGammaLeft")
                dictionary.removeValue(forKey: "meshGammaRight")
            }
            for key in dictionary.keys {
                if let nested = dictionary[key], let migrated = migrateLegacyMeshSettings(nested) {
                    dictionary[key] = migrated
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.compactMap(migrateLegacyMeshSettings)
        }
        return value
    }

    @discardableResult
    func save(_ registry: ProjectRegistry) -> Bool {
        guard !savingBlocked else { lastError = recoveryMessage; return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the last readable version before replacing the primary file.
            if FileManager.default.fileExists(atPath: url.path) {
                guard let previous = try? Data(contentsOf: url) else {
                    savingBlocked = true
                    recoveryMessage = "The project list on disk cannot be read. It has been preserved. Restore the in-memory project list to continue saving changes."
                    lastError = recoveryMessage
                    return false
                }
                guard decode(previous) != nil else {
                    savingBlocked = true
                    recoveryMessage = "The project list on disk became unreadable. It has been preserved. Restore the in-memory project list to continue saving changes."
                    lastError = recoveryMessage
                    return false
                }
                try previous.write(to: backupURL, options: .atomic)
            }
            try JSONEncoder.pretty.encode(registry).write(to: url, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "Could not save the project list: \(error.localizedDescription)"
            return false
        }
    }

}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
