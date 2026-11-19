import Foundation

@MainActor
final class ProjectStatusController: ObservableObject {
    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isCheckingProjectFiles = false
    @Published private(set) var projectSummaries: [UUID: String] = [:]
    @Published private(set) var stageStates: [Stage: StageState] = ProjectStatusController.readyStates
    @Published private var projectStatus: ProjectStatusSnapshot?
    private var refreshID = UUID()
    private var refreshWorkItem: DispatchWorkItem?
    private var refreshProgress: Progress?
    private let refreshQueue = DispatchQueue(label: "Pinna2HRTF.ProjectStatusRefresh", qos: .userInitiated, attributes: .concurrent)
    private let solverRefreshQueue = DispatchQueue(label: "Pinna2HRTF.SolverStatusRefresh", qos: .utility)
    private let summaryQueue = DispatchQueue(label: "Pinna2HRTF.ProjectSummaries", qos: .utility)
    private var summaryProgress: Progress?
    private var summarizedProjects: [UUID: ProjectRecord] = [:]

    weak var store: AppStore?

    private static var readyStates: [Stage: StageState] { Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, .ready) }) }

    func status(for project: ProjectRecord?, environment: EnvironmentConfig) -> ProjectStatusSnapshot? {
        guard let status = projectStatus, status.project == project, status.environment == environment else { return nil }
        return status
    }

    func refreshSummaries(for projects: [ProjectRecord]) {
        summaryProgress?.cancel()
        let currentProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        summarizedProjects = summarizedProjects.filter { currentProjects[$0.key] == $0.value }
        let summaries = Dictionary(uniqueKeysWithValues: projects.map { project in
            (project.id, summarizedProjects[project.id] == project
                ? projectSummaries[project.id, default: ""]
                : ProjectStatusSnapshot.savedSummary(for: project))
        })
        if projectSummaries != summaries { projectSummaries = summaries }

        let pending = projects.filter { summarizedProjects[$0.id] != $0 }
        guard !pending.isEmpty else { return }
        let selectedID = store?.selectedProjectID
        let ordered = pending.filter { $0.id != selectedID } + pending.filter { $0.id == selectedID }
        let progress = Progress(totalUnitCount: Int64(ordered.count))
        summaryProgress = progress
        summaryQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            for project in ordered {
                guard !progress.isCancelled else { return }
                let inspection = ArtifactScanner.Inspection(isCancelled: { progress.isCancelled })
                let summary = ProjectStatusSnapshot.loadSummary(for: project, inspection: inspection)
                Task { @MainActor [weak self] in
                    guard let self, !progress.isCancelled,
                          self.store?.projects.first(where: { $0.id == project.id }) == project,
                          self.summarizedProjects[project.id] != project else { return }
                    self.applySummary(summary, for: project)
                }
            }
        }
    }

    func refresh(restoringViewer: Bool = false) {
        guard let store else { return }
        store.refreshGeometry()
        refreshWorkItem?.cancel()
        refreshProgress?.cancel()
        let progress = Progress(totalUnitCount: 1)
        refreshProgress = progress
        let refreshID = UUID()
        self.refreshID = refreshID
        let viewer = store.viewer
        guard let project = store.selectedProject else {
            artifacts = []
            projectStatus = nil
            isCheckingProjectFiles = false
            stageStates = Self.readyStates
            return
        }
        let changedProject = projectStatus?.project.id != project.id
        if changedProject {
            artifacts = ProjectStatusSnapshot.configuredPreviewArtifacts(for: project)
            projectStatus = nil
            viewer.resetViewer()
        }
        let initialViewerLoadID = viewer.meshLoadID
        let currentEnvironment = store.environment
        let currentProjects = store.projects
        isCheckingProjectFiles = true
        let solverQueue = solverRefreshQueue
        let workItem = DispatchWorkItem { [weak self] in
            guard !progress.isCancelled else { return }
            if project.saveLocation.hasPrefix(Defaults.appDataURL.appendingPathComponent("Projects", isDirectory: true).path + "/") {
                ProjectLibrary.migrateProjectDirectory(for: project)
            }
            let inspection = ArtifactScanner.Inspection(isCancelled: { progress.isCancelled })
            let status = ProjectStatusSnapshot.load(project: project, environment: currentEnvironment, projects: currentProjects,
                                                    inspection: inspection, includeSolverResults: false)
            guard !progress.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(refreshID, project: project, environment: currentEnvironment) else { return }
                self.apply(status)
                self.isCheckingProjectFiles = false
                self.refreshWorkItem = nil
                if (restoringViewer || changedProject) && viewer.meshLoadID == initialViewerLoadID && viewer.selectedMesh == nil {
                    viewer.restoreViewer(artifacts: self.artifacts)
                }
                let restorationLoadID = viewer.meshLoadID
                solverQueue.async { [weak self] in
                    guard !progress.isCancelled else { return }
                    let detailed = ProjectStatusSnapshot.load(project: project, environment: currentEnvironment, projects: currentProjects,
                                                              inspection: inspection)
                    Task { @MainActor [weak self] in
                        guard let self, !progress.isCancelled, self.isCurrent(refreshID, project: project, environment: currentEnvironment) else { return }
                        self.apply(detailed)
                        if (restoringViewer || changedProject) && viewer.meshLoadID == restorationLoadID && viewer.selectedMesh == nil {
                            viewer.restoreViewer(artifacts: self.artifacts)
                        }
                    }
                }
            }
        }
        refreshWorkItem = workItem
        refreshQueue.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
    }

    private func isCurrent(_ id: UUID, project: ProjectRecord, environment: EnvironmentConfig) -> Bool {
        refreshID == id && store?.selectedProject == project && store?.environment == environment
    }

    private func apply(_ status: ProjectStatusSnapshot) {
        guard let store else { return }
        projectStatus = status
        artifacts = status.artifacts
        if !status.checkingSolverResults { applySummary(status.summary, for: status.project) }
        var states = status.states
        for stage in Stage.allCases {
            if store.runner.failedStagesByProject[status.project.id]?.contains(stage) == true { states[stage] = .failed }
            if store.runner.runningStages[status.project.id] == stage { states[stage] = .running }
        }
        if status.preprocessingNeedsRerun, states[.preprocessing] == .done { states[.preprocessing] = .ready }
        stageStates = states
    }

    private func applySummary(_ summary: String, for project: ProjectRecord) {
        summarizedProjects[project.id] = project
        if projectSummaries[project.id] != summary { projectSummaries[project.id] = summary }
    }
}
