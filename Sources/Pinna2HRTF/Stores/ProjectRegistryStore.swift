import Foundation

final class ProjectRegistryStore {
    let url: URL
    let rootURL: URL
    let packageURL: URL
    private(set) var savingBlocked = false
    private(set) var migrationError: String?

    init(rootURL: URL, packageURL: URL, url: URL = Defaults.appDataURL.appendingPathComponent("projects.json")) {
        self.rootURL = rootURL
        self.packageURL = packageURL
        self.url = url
    }

    func load() -> ProjectRegistry {
        if let data = try? Data(contentsOf: url) {
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                let geometry = try HeadGeometrySettings.migrateRegistry(object)
                let migrated = Self.migrateLegacyMeshSettings(geometry) ?? geometry
                let converted = try JSONSerialization.data(withJSONObject: migrated)
                let registry = try JSONDecoder().decode(ProjectRegistry.self, from: converted)
                if try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) != JSONSerialization.data(withJSONObject: geometry, options: .sortedKeys) {
                    let backup = url.appendingPathExtension("pre-1.2.0-\(UUID().uuidString).bak")
                    try data.write(to: backup, options: .withoutOverwriting)
                    try JSONEncoder.pretty.encode(registry).write(to: url, options: .atomic)
                }
                return registry
            } catch {
                savingBlocked = true
                migrationError = "Project list could not be migrated. The original file is protected: \(error.localizedDescription)"
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            savingBlocked = true
            migrationError = "The project list is unreadable and has been preserved."
        }
        let environment = Defaults.environment(root: rootURL)
        return ProjectRegistry(projects: [], selectedProjectID: nil, environment: environment)
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

    func save(_ registry: ProjectRegistry) {
        guard !savingBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(registry)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Could not save registry: \(error)")
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
