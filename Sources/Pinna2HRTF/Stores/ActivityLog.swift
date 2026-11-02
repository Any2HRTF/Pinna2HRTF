import Foundation

private struct ActivityLogEntry {
    var date: Date
    var message: String
    var key: String?
}

/// Per-project activity messages, live status lines and technical log locations.
@MainActor
final class ActivityLog: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var technicalLogURLs: [UUID: URL] = [:]
    @Published private(set) var environmentTechnicalLogURL: URL?
    @Published var liveStatusByProject: [UUID: String] = [:]
    private var entriesByProject: [UUID: [ActivityLogEntry]] = [:]
    private(set) var selectedProjectID: UUID?

    var selectedTechnicalLogURL: URL? {
        selectedProjectID.flatMap { technicalLogURLs[$0] } ?? environmentTechnicalLogURL
    }

    /// Looks up existing technical logs in the background at start-up.
    func discoverExistingLogs(for projects: [ProjectRecord]) {
        Task.detached(priority: .utility) { [weak self] in
            let environmentLog = Self.latestEnvironmentTechnicalLogURL()
            await self?.setEnvironmentLogIfMissing(environmentLog)
            for project in projects {
                let log = Self.latestTechnicalLogURL(for: project)
                await self?.setTechnicalLogIfMissing(log, for: project.id)
            }
        }
    }

    private func setEnvironmentLogIfMissing(_ url: URL?) {
        if environmentTechnicalLogURL == nil { environmentTechnicalLogURL = url }
    }

    private func setTechnicalLogIfMissing(_ url: URL?, for id: UUID) {
        guard let url, technicalLogURLs[id] == nil else { return }
        technicalLogURLs[id] = url
    }

    /// Shows the activity of `project`; its latest log file is found off the main thread.
    func select(_ project: ProjectRecord?) {
        selectedProjectID = project?.id
        guard let project else { text = ""; return }
        text = render(entriesByProject[project.id] ?? [])
        if technicalLogURLs[project.id] == nil {
            Task.detached(priority: .utility) { [weak self] in
                let url = Self.latestTechnicalLogURL(for: project)
                await self?.setTechnicalLogIfMissing(url, for: project.id)
            }
        }
    }

    func setTechnicalLog(_ url: URL, for projectID: UUID?) {
        if let projectID { technicalLogURLs[projectID] = url }
    }

    func setEnvironmentLog(_ url: URL) { environmentTechnicalLogURL = url }

    func clearSelected() {
        guard let selectedProjectID else { return }
        entriesByProject[selectedProjectID] = []
        text = ""
    }

    func forget(_ projectID: UUID) {
        entriesByProject[projectID] = nil
        liveStatusByProject[projectID] = nil
        technicalLogURLs[projectID] = nil
    }

    func append(_ text: String, for projectID: UUID? = nil) {
        for line in text.components(separatedBy: .newlines) {
            let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { continue }
            appendEntry(message, for: projectID)
        }
    }

    func record(_ event: PipelineLogEvent, stage: Stage, projectID: UUID, runID: UUID) {
        let message: String
        switch event.level?.lowercased() {
        case "warning": message = "Warning · \(stage.title) · \(event.message)"
        case "error": message = "Error · \(stage.title) · \(event.message)"
        default: message = "\(stage.title) · \(event.message)"
        }
        let key = event.key.map { "\(runID.uuidString):\($0)" }
        appendEntry(message, for: projectID, key: key)
    }

    private func appendEntry(_ message: String, for projectID: UUID?, key: String? = nil) {
        guard let projectID = projectID ?? selectedProjectID else { return }
        var entries = entriesByProject[projectID, default: []]
        if let key, let existing = entries.lastIndex(where: { $0.key == key }) {
            entries.remove(at: existing)
        }
        entries.append(ActivityLogEntry(date: Date(), message: message, key: key))
        if entries.count > 400 { entries.removeFirst(entries.count - 400) }
        entriesByProject[projectID] = entries
        if projectID == selectedProjectID { text = render(entries) }
    }

    private func render(_ entries: [ActivityLogEntry]) -> String {
        entries.map { "[\($0.date.formatted(date: .omitted, time: .standard))] \($0.message)" }.joined(separator: "\n")
    }

    // MARK: Log files

    nonisolated static func technicalLogURL(project: ProjectRecord, stage: Stage, runID: UUID, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "\(formatter.string(from: date))-\(stage.rawValue)-\(runID.uuidString.prefix(8)).log"
        return projectLogDirectory(for: project)?.appendingPathComponent(filename)
            ?? Defaults.appDataURL.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(project.id.uuidString, isDirectory: true)
                .appendingPathComponent(filename)
    }

    nonisolated static func latestTechnicalLogURL(for project: ProjectRecord) -> URL? {
        guard let directory = projectLogDirectory(for: project) else { return nil }
        migrateLegacyTechnicalLogs(for: project, to: directory)
        return latestLog(in: directory)
            ?? latestLog(in: Defaults.appDataURL.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(project.id.uuidString, isDirectory: true))
    }

    nonisolated static func projectLogDirectory(for project: ProjectRecord) -> URL? {
        let location = project.saveLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return nil }
        return URL(fileURLWithPath: location, isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private nonisolated static func migrateLegacyTechnicalLogs(for project: ProjectRecord, to directory: URL) {
        let legacyDirectory = Defaults.appDataURL.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
        guard legacyDirectory.standardizedFileURL != directory.standardizedFileURL,
              let files = try? FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for source in files where source.pathExtension == "log" {
                var destination = directory.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let suffix = UUID().uuidString.prefix(8)
                    destination = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(suffix).log")
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: legacyDirectory.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: legacyDirectory)
            }
        } catch {
            // Keep any logs that could not be moved in their legacy location; lookup falls back to it.
        }
    }

    private nonisolated static func latestLog(in directory: URL, matching include: (URL) -> Bool = { $0.pathExtension == "log" }) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return urls.filter(include).max {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first < second
        }
    }

    private nonisolated static func latestEnvironmentTechnicalLogURL() -> URL? {
        latestLog(in: Defaults.appDataURL.appendingPathComponent("Logs", isDirectory: true)) {
            $0.lastPathComponent.hasPrefix("Environment-") && $0.pathExtension == "log"
        }
    }
}
