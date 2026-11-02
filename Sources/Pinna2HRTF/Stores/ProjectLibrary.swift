import Foundation
import AppKit

/// The project list: projects, folders, selection, environment settings and their persistence,
/// plus import, duplication and the safety rules for removing a project.
@MainActor
final class ProjectLibrary: ObservableObject {
    @Published var folders: [ProjectFolder]
    @Published var projects: [ProjectRecord] {
        didSet { store?.projectsDidChange() }
    }
    @Published var selectedProjectID: UUID? {
        didSet { if oldValue != selectedProjectID { store?.selectionDidChange() } }
    }
    @Published var environment: EnvironmentConfig
    @Published var persistenceMessage: String?
    @Published var registryRecoveryPresented = false
    @Published var projectRevealToken = UUID()
    @Published private(set) var projectsBeingRemoved = Set<UUID>()

    let rootURL: URL
    let packageURL: URL
    let registryStore: ProjectRegistryStore
    weak var store: AppStore?
    private var persistWork: DispatchWorkItem?

    init() {
        rootURL = Defaults.runtimeRoot
        packageURL = Defaults.pipelineRoot
        registryStore = ProjectRegistryStore(rootURL: rootURL, packageURL: packageURL)
        if Defaults.isPackagedApp {
            for obsolete in [Defaults.runtimeProjectURL, Defaults.appDataURL.appendingPathComponent("Cache/uv", isDirectory: true)] {
                try? FileManager.default.removeItem(at: obsolete)
            }
        }
        var registry = Self.migrated(registryStore.load(), rootURL: rootURL, packageURL: packageURL)
        if Defaults.isPackagedApp {
            registry.environment = Defaults.environment(root: rootURL)
        }
        for index in registry.projects.indices {
            for (stage, outcome) in registry.projects[index].stageOutcomes ?? [:] where outcome == .running {
                registry.projects[index].stageOutcomes?[stage] = .stopped
            }
        }
        folders = registry.folders
        projects = registry.projects
        selectedProjectID = registry.selectedProjectID ?? registry.projects.first?.id
        environment = registry.environment
        registryStore.save(registry)
        persistenceMessage = registryStore.lastError ?? registryStore.recoveryMessage
        registryRecoveryPresented = registryStore.savingBlocked
    }

    var selectedProject: ProjectRecord? { projects.first { $0.id == selectedProjectID } }
    var selectedProjectIndex: Int? { projects.firstIndex { $0.id == selectedProjectID } }

    // MARK: Persistence

    var registry: ProjectRegistry {
        ProjectRegistry(projects: projects, selectedProjectID: selectedProjectID, environment: environment, folders: folders)
    }

    /// Coalesces bursts of edits (typing in a settings field) into one background write.
    func persist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistNow() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func persistNow() {
        persistWork?.cancel()
        persistWork = nil
        let wasBlocked = registryStore.savingBlocked
        registryStore.saveInBackground(registry) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistenceMessage = self.registryStore.lastError
                if !wasBlocked && self.registryStore.savingBlocked { self.registryRecoveryPresented = true }
            }
        }
    }

    /// Writes pending changes synchronously (quit).
    func flushPersistence() {
        persistWork?.cancel()
        persistWork = nil
        registryStore.waitForPendingSaves()
        registryStore.save(registry)
    }

    func recoverProjectRegistry() {
        registryStore.waitForPendingSaves()
        if registryStore.recover(using: registry) { persistenceMessage = nil }
        else { persistenceMessage = registryStore.lastError }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String) -> UUID {
        let folder = ProjectFolder(name: name)
        folders.append(folder)
        persist()
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        persist()
    }

    func removeFolder(_ id: UUID) {
        var updated = projects
        for index in updated.indices where updated[index].folderID == id {
            updated[index].folderID = nil
        }
        projects = updated
        folders.removeAll { $0.id == id }
        persist()
    }

    func moveProject(_ id: UUID, toFolder folderID: UUID?, before destinationID: UUID? = nil) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }),
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var updated = projects
        updated[index].folderID = folderID
        if let destinationID, destinationID != id,
           updated.contains(where: { $0.id == destinationID && $0.folderID == folderID }) {
            let project = updated.remove(at: index)
            if let destinationIndex = updated.firstIndex(where: { $0.id == destinationID }) {
                updated.insert(project, at: destinationIndex)
            }
        }
        projects = updated
        if let folderIndex = folders.firstIndex(where: { $0.id == folderID }) {
            folders[folderIndex].isExpanded = true
        }
        persist()
    }

    func revealSelectedProject() {
        guard let project = selectedProject else { return }
        if let index = folders.firstIndex(where: { $0.id == project.folderID }) {
            folders[index].isExpanded = true
            persist()
        }
        projectRevealToken = UUID()
    }

    // MARK: Adding projects

    func newProject() -> ProjectRecord {
        Defaults.newProject(packageRoot: packageURL, index: projects.count + 1)
    }

    /// The listed project stored at `folder` (links resolved), if any.
    func existingProject(at folder: URL) -> ProjectRecord? {
        let target = Self.realPath(folder.path)
        return projects.first { !$0.saveLocation.isEmpty && Self.realPath($0.saveLocation) == target }
    }

    /// Appends and selects `project`.
    func add(_ project: ProjectRecord) {
        projects.append(project)
        selectedProjectID = project.id
        persist()
    }

    func duplicateSuggestion(for project: ProjectRecord) -> ProjectDuplicationRequest {
        let parent = project.saveLocation.isEmpty
            ? Defaults.appDataURL.appendingPathComponent("Projects", isDirectory: true)
            : URL(fileURLWithPath: project.saveLocation).deletingLastPathComponent()
        let baseName = "\(project.name) Copy"
        var name = baseName
        var suffix = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        return ProjectDuplicationRequest(project: project, suggestedName: name, parentFolder: parent.path)
    }

    func duplicate(_ request: ProjectDuplicationRequest, name: String, parentFolder: String) async throws -> ProjectRecord {
        guard !registryStore.savingBlocked else {
            throw ProjectValidation.Failure(message: "Restore the project list before adding a duplicate.")
        }
        let roots = projects.map(\.saveLocation)
        let duplicate = try await Task.detached(priority: .userInitiated) {
            try ProjectDuplicator.duplicate(request.project, name: name, parentFolder: parentFolder, projectRoots: roots)
        }.value
        add(duplicate)
        return duplicate
    }

    /// Reads an existing project folder off the main thread. Never changes files in it.
    nonisolated static func importedRecord(from folder: URL, index: Int, packageRoot root: URL) throws -> (project: ProjectRecord, note: String?) {
        var project = Defaults.newProject(packageRoot: root, index: index)
        project.name = folder.lastPathComponent
        project.leftEar = importedMesh(in: folder, side: "Left")
        project.rightEar = importedMesh(in: folder, side: "Right")
        project.saveLocation = folder.path
        project.inputHandling = .reference
        let configURL = ["Project Settings.yaml", ".pinna2hrtf_native_run.yaml", "pipeline.yaml"]
            .map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let configURL {
            // ProjectConfigDocument restores legacy geometry fields.
            let document = try ProjectConfigDocument.parse(String(contentsOf: configURL, encoding: .utf8))
            project = try ProjectConfigDocument.restore(document, into: project, folder: folder, packageRoot: root)
        }
        // The user's folder is left as it is. On case-sensitive volumes a legacy
        // lowercase folder is not found under its current name, so say so.
        var note: String?
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if entries.contains("intermediates"), !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Intermediates").path) {
            note = "This project has a legacy “intermediates” folder, which was left unchanged. Rename it to “Intermediates” to use its files."
        }
        return (project, note)
    }

    nonisolated static func importedMesh(in folder: URL, side: String) -> String {
        let candidates = ["Input/\(side)", "Intermediates/\(side)", "Intermediates/Prediction STL \(side)", "Intermediates/ICP STL \(side)",
                          "Target STL \(side)", "ICP STL \(side)", "Prediction STL \(side)"].map { folder.appendingPathComponent($0) }
        for candidate in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil) else { continue }
            if let exact = files.first(where: { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(side) == .orderedSame && ["stl", "ply"].contains($0.pathExtension.lowercased()) }) {
                return exact.path
            }
            if let mesh = files.first(where: { ["stl", "ply"].contains($0.pathExtension.lowercased()) }) {
                return mesh.path
            }
        }
        for name in [side, side.lowercased(), side.uppercased()] {
            for suffix in ["stl", "ply"] {
                let candidate = folder.appendingPathComponent("\(name).\(suffix)")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            }
        }
        return ""
    }

    // MARK: Removing projects

    enum RemovalPlan {
        /// Remove only the list entry; `reason` explains why the folder stays (nil when there is no folder).
        case listOnly(reason: String?)
        case trash(URL)
    }

    /// Decides whether removing `project` may move its folder to Trash.
    /// A folder is trashed only when the app created it (or it carries the app's
    /// project marker), it is not a protected location, and it neither contains
    /// nor lies inside another listed project. Links are resolved first.
    func removalPlan(for project: ProjectRecord) -> RemovalPlan {
        let location = project.saveLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return .listOnly(reason: nil) }
        let folder = Self.realPath(location)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) else { return .listOnly(reason: nil) }
        let kept = "The folder stays at \(folder)."
        if project.inputHandling == .reference {
            return .listOnly(reason: "This project was imported from an existing folder, so only the list entry is removed. \(kept)")
        }
        guard isDirectory.boolValue else {
            return .listOnly(reason: "The saved project location is not a folder. \(kept)")
        }
        guard !isProtected(folder) else {
            return .listOnly(reason: "The project is saved in a protected location. \(kept)")
        }
        guard Self.isAppManaged(folder) || Self.hasProjectMarker(folder) else {
            return .listOnly(reason: "The folder has no Pinna2HRTF project data, so it is not moved to Trash. \(kept)")
        }
        for other in projects where other.id != project.id && !other.saveLocation.isEmpty {
            let otherPath = Self.realPath(other.saveLocation)
            if Self.path(folder, contains: otherPath) || Self.path(otherPath, contains: folder) {
                return .listOnly(reason: "The folder contains or is inside the project “\(other.name)”. \(kept)")
            }
        }
        return .trash(URL(fileURLWithPath: folder, isDirectory: true))
    }

    private func isProtected(_ folder: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var protected = ["/", "/Users", "/Volumes", "/Applications", "/System", "/Library", "/private", "/tmp", "/var"].map(Self.realPath)
        protected += ["", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications", "Library/Mobile Documents"]
            .map { Self.realPath(home.appendingPathComponent($0).path) }
        protected += [rootURL, packageURL, Defaults.appDataURL, Defaults.appDataURL.appendingPathComponent("Projects")].map { Self.realPath($0.path) }
        // Never trash a folder that is, or contains, a protected location.
        if protected.contains(where: { Self.path(folder, contains: $0) }) { return true }
        // Volume roots (for example /Volumes/Data).
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        if let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
           Self.realPath(volume.path) == folder { return true }
        return false
    }

    nonisolated static func isAppManaged(_ folder: String) -> Bool {
        path(realPath(Defaults.appDataURL.appendingPathComponent("Projects").path), contains: folder)
            && realPath(Defaults.appDataURL.appendingPathComponent("Projects").path) != folder
    }

    /// Files the app writes into every project it has run or tracked.
    nonisolated static func hasProjectMarker(_ folder: String) -> Bool {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".pinna2hrtf").path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        return ["Project Settings.yaml", ".pinna2hrtf_native_run.yaml", ".pinna2hrtf-preprocessing-signature"]
            .contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    func beginRemoving(_ id: UUID) { projectsBeingRemoved.insert(id) }
    func endRemoving(_ id: UUID) { projectsBeingRemoved.remove(id) }

    func removeRecord(_ id: UUID) {
        projects.removeAll { $0.id == id }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        persist()
    }

    // MARK: Paths

    nonisolated static func realPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else {
            return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Component-aware containment: `/a/b` contains `/a/b` and `/a/b/c`, not `/a/bc`.
    nonisolated static func path(_ parent: String, contains child: String) -> Bool {
        if parent == "/" { return child.hasPrefix("/") }
        return child == parent || child.hasPrefix(parent + "/")
    }

    // MARK: Migration

    nonisolated static func migrateProjectDirectory(for project: ProjectRecord) {
        let projectFolder = URL(fileURLWithPath: project.saveLocation, isDirectory: true)
        let entries = try? FileManager.default.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: nil)
        let legacyIntermediates = entries?.first(where: { $0.lastPathComponent == "intermediates" })
        let currentIntermediates = entries?.first(where: { $0.lastPathComponent == "Intermediates" })
        if let legacyIntermediates, currentIntermediates == nil {
            let migrationPath = projectFolder.appendingPathComponent(".pinna2hrtf-intermediates-migration")
            try? FileManager.default.moveItem(at: legacyIntermediates, to: migrationPath)
            try? FileManager.default.moveItem(at: migrationPath, to: projectFolder.appendingPathComponent("Intermediates"))
        }
    }

    static func migrated(_ registry: ProjectRegistry, rootURL: URL, packageURL: URL) -> ProjectRegistry {
        var next = registry
        let defaultEnvironment = Defaults.environment(root: rootURL)
        if Defaults.isPackagedApp { next.environment = defaultEnvironment }
        let replacements: [(String, String)] = [
            (packageURL.appendingPathComponent("External").path, rootURL.appendingPathComponent("External").path),
            (packageURL.appendingPathComponent("Paper").path, rootURL.appendingPathComponent("Paper").path),
            (packageURL.appendingPathComponent("Sources/HRTFCalculation").path, packageURL.appendingPathComponent("HRTFCalculation").path)
        ]
        next.environment.uvExecutable = migratedPath(next.environment.uvExecutable, replacements: replacements)
        next.environment.numcalcExecutable = migratedPath(next.environment.numcalcExecutable, replacements: replacements)
        next.environment.meshGradingExecutable = migratedPath(next.environment.meshGradingExecutable, replacements: replacements)
        next.environment.externalDir = migratedPath(next.environment.externalDir, replacements: replacements)
        if !FileManager.default.isExecutableFile(atPath: next.environment.uvExecutable) {
            next.environment.uvExecutable = defaultEnvironment.uvExecutable
        }
        if !FileManager.default.isExecutableFile(atPath: next.environment.numcalcExecutable) {
            next.environment.numcalcExecutable = defaultEnvironment.numcalcExecutable
        }
        if !FileManager.default.isExecutableFile(atPath: next.environment.meshGradingExecutable) {
            next.environment.meshGradingExecutable = defaultEnvironment.meshGradingExecutable
        }
        if !FileManager.default.fileExists(atPath: next.environment.externalDir) {
            next.environment.externalDir = defaultEnvironment.externalDir
        }
        next.projects = next.projects.map { project in
            var updated = project
            updated.leftEar = migratedPath(updated.leftEar, replacements: replacements)
            updated.rightEar = migratedPath(updated.rightEar, replacements: replacements)
            updated.saveLocation = migratedPath(updated.saveLocation, replacements: replacements)
            if updated.saveLocation.isEmpty {
                let folderName = updated.name.replacingOccurrences(of: "/", with: "-")
                updated.saveLocation = Defaults.appDataURL.appendingPathComponent("Projects/\(folderName)").path
            }
            updated.settings.inference.modelConfig = migratedPath(updated.settings.inference.modelConfig, replacements: replacements)
            updated.settings.inference.modelCheckpoint = migratedPath(updated.settings.inference.modelCheckpoint, replacements: replacements)
            if updated.settings.inference.targetLeftFolder == "Target STL Left" { updated.settings.inference.targetLeftFolder = "Input/Left" }
            if updated.settings.inference.targetRightFolder == "Target STL Right" { updated.settings.inference.targetRightFolder = "Input/Right" }
            if updated.settings.inference.predictionLeftFolder == "Prediction STL Left" { updated.settings.inference.predictionLeftFolder = "Intermediates/Prediction STL Left" }
            if updated.settings.inference.predictionRightFolder == "Prediction STL Right" { updated.settings.inference.predictionRightFolder = "Intermediates/Prediction STL Right" }
            if updated.settings.inference.predictionLeftFolder == "Intermediates/Prediction STL Left" { updated.settings.inference.predictionLeftFolder = "Intermediates/Left" }
            if updated.settings.inference.predictionRightFolder == "Intermediates/Prediction STL Right" { updated.settings.inference.predictionRightFolder = "Intermediates/Right" }
            updated.settings.preprocessing.frequencyStepCount = "\(max(Int(updated.settings.preprocessing.frequencyStepCount) ?? 129, 2))"
            if Defaults.isPackagedApp {
                let resources = packageURL.appendingPathComponent("HRTFCalculation/Inference/resources", isDirectory: true)
                let bundledConfig = resources.appendingPathComponent(URL(fileURLWithPath: updated.settings.inference.modelConfig).lastPathComponent)
                let bundledCheckpoint = resources.appendingPathComponent(URL(fileURLWithPath: updated.settings.inference.modelCheckpoint).lastPathComponent)
                if updated.settings.inference.modelConfig.contains("HRTFCalculation/Inference/resources/"), FileManager.default.fileExists(atPath: bundledConfig.path) {
                    updated.settings.inference.modelConfig = bundledConfig.path
                }
                if updated.settings.inference.modelCheckpoint.contains("HRTFCalculation/Inference/resources/"), FileManager.default.fileExists(atPath: bundledCheckpoint.path) {
                    updated.settings.inference.modelCheckpoint = bundledCheckpoint.path
                }
            }
            return updated
        }
        return next
    }

    /// Replaces a leading path prefix only on a component boundary
    /// (`…/External` matches `…/External/bin`, never `…/ExternalData`).
    nonisolated static func migratedPath(_ path: String, replacements: [(String, String)]) -> String {
        for (old, new) in replacements where !old.isEmpty {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
        }
        return path
    }
}
