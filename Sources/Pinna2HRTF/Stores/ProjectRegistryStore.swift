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
        if let data = try? Data(contentsOf: url), let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data) {
            return registry
        }
        let environment = Defaults.environment(root: rootURL)
        let project = Defaults.sampleProject(root: rootURL, packageRoot: packageURL, index: 1)
        return ProjectRegistry(projects: [project], selectedProjectID: project.id, environment: environment)
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
