import Foundation

final class ProjectRegistryStore {
    let url: URL
    let rootURL: URL
    let packageURL: URL

    init(rootURL: URL, packageURL: URL, url: URL = Defaults.appDataURL.appendingPathComponent("projects.json")) {
        self.rootURL = rootURL
        self.packageURL = packageURL
        self.url = url
    }

    func load() -> ProjectRegistry {
        if let data = try? Data(contentsOf: url) {
            if let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data) {
                return registry
            }
            if let object = try? JSONSerialization.jsonObject(with: data), let migratedObject = Self.migrateLegacyMeshSettings(object), let migratedData = try? JSONSerialization.data(withJSONObject: migratedObject), let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: migratedData) {
                return registry
            }
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
