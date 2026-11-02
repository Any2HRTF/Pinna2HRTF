import Foundation

/// Reads and writes `projects.json`.
///
/// Writes run on a private serial queue and are atomic. The bytes last known to be
/// on disk are kept in memory, so a save only needs to decode the file on disk when
/// someone else changed it. Status properties are safe to read from any thread.
final class ProjectRegistryStore: @unchecked Sendable {
    let url: URL
    let rootURL: URL
    let packageURL: URL
    private let ioQueue = DispatchQueue(label: "Pinna2HRTF.ProjectRegistry", qos: .utility)
    private let stateLock = NSLock()
    private var _recoveryMessage: String?
    private var _savingBlocked = false
    private var _lastError: String?
    /// Bytes most recently read from or written to `url` (ioQueue only, or before first save).
    private var lastGoodData: Data?

    private(set) var recoveryMessage: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _recoveryMessage }
        set { stateLock.lock(); _recoveryMessage = newValue; stateLock.unlock() }
    }
    private(set) var savingBlocked: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _savingBlocked }
        set { stateLock.lock(); _savingBlocked = newValue; stateLock.unlock() }
    }
    private(set) var lastError: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastError }
        set { stateLock.lock(); _lastError = newValue; stateLock.unlock() }
    }
    var backupURL: URL { url.deletingPathExtension().appendingPathExtension("backup.json") }


    init(rootURL: URL, packageURL: URL, url: URL = Defaults.appDataURL.appendingPathComponent("projects.json")) {
        self.rootURL = rootURL
        self.packageURL = packageURL
        self.url = url
    }

    private func decode(_ data: Data) -> ProjectRegistry? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let geometry = try? HeadGeometrySettings.migrateRegistry(object),
              let migrated = Self.migrateLegacyMeshSettings(geometry),
              let data = try? JSONSerialization.data(withJSONObject: migrated) else { return nil }
        return try? JSONDecoder().decode(ProjectRegistry.self, from: data)
    }

    func load() -> ProjectRegistry {
        if let data = try? Data(contentsOf: url), let registry = decode(data) {
            lastGoodData = data
            // Preserve the exact original before geometry migration is persisted.
            if let object = try? JSONSerialization.jsonObject(with: data),
               let geometry = try? HeadGeometrySettings.migrateRegistry(object),
               let before = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
               let after = try? JSONSerialization.data(withJSONObject: geometry, options: .sortedKeys),
               before != after {
                do {
                    try data.write(to: url.appendingPathExtension("pre-1.1.1-\(UUID().uuidString).bak"), options: .withoutOverwriting)
                } catch {
                    savingBlocked = true
                    recoveryMessage = "Could not preserve the project list before migration: \(error.localizedDescription)"
                }
            }
            return registry
        }
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
        ioQueue.sync { recoverOnQueue(using: registry) }
    }

    private func recoverOnQueue(using registry: ProjectRegistry) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let preserved = url.deletingLastPathComponent().appendingPathComponent("projects-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: preserved)
            }
            if let backupData = try? Data(contentsOf: backupURL), decode(backupData) == nil {
                let preserved = url.deletingLastPathComponent().appendingPathComponent("projects-backup-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: backupURL, to: preserved)
            }
            let data = try JSONEncoder.pretty.encode(registry)
            try data.write(to: url, options: .atomic)
            lastGoodData = data
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

    /// Saves synchronously (start-up and quit).
    @discardableResult
    func save(_ registry: ProjectRegistry) -> Bool {
        ioQueue.sync { write(registry) }
    }

    /// Saves on the background queue; `completion` runs on the main queue.
    func saveInBackground(_ registry: ProjectRegistry, completion: @escaping @Sendable (Bool) -> Void) {
        ioQueue.async { [self] in
            let saved = write(registry)
            DispatchQueue.main.async { completion(saved) }
        }
    }

    /// Waits for queued background saves to finish.
    func waitForPendingSaves() { ioQueue.sync {} }

    private func write(_ registry: ProjectRegistry) -> Bool {
        guard !savingBlocked else { lastError = recoveryMessage; return false }

        do {
            let data = try JSONEncoder.pretty.encode(registry)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the last readable version before replacing the primary file.
            if FileManager.default.fileExists(atPath: url.path) {
                guard let previous = try? Data(contentsOf: url) else {
                    savingBlocked = true
                    recoveryMessage = "The project list on disk cannot be read. It has been preserved. Restore the in-memory project list to continue saving changes."
                    lastError = recoveryMessage
                    return false
                }
                if previous == data { lastGoodData = data; lastError = nil; return true }
                // Only a file someone else changed needs a full decode.
                guard previous == lastGoodData || decode(previous) != nil else {
                    savingBlocked = true
                    recoveryMessage = "The project list on disk became unreadable. It has been preserved. Restore the in-memory project list to continue saving changes."
                    lastError = recoveryMessage
                    return false
                }
                try previous.write(to: backupURL, options: .atomic)
            }
            try data.write(to: url, options: .atomic)
            lastGoodData = data
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
