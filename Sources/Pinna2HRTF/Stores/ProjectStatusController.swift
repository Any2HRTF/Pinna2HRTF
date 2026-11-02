import Foundation

/// Inspects the selected project's files off the main thread and publishes its
/// artifacts, stage states and validation issues.
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

    weak var store: AppStore?

    private static var readyStates: [Stage: StageState] { Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, .ready) }) }

    func status(for project: ProjectRecord?, environment: EnvironmentConfig) -> ProjectStatusSnapshot? {
        guard let status = projectStatus, status.project == project, status.environment == environment else { return nil }
        return status
    }

    func refreshSummaries(for projects: [ProjectRecord]) {
        projectSummaries = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, ProjectStatusSnapshot.savedSummary(for: $0)) })
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
            // Imported projects keep their folder layout. Only migrate app-managed
            // local projects here; listing a server root can stall.
            if project.saveLocation.hasPrefix(Defaults.appDataURL.appendingPathComponent("Projects", isDirectory: true).path + "/") {
                ProjectLibrary.migrateProjectDirectory(for: project)
            }
            let status = ProjectStatusSnapshot.load(project: project, environment: currentEnvironment, projects: currentProjects,
                                                    includeSolverResults: false, isCancelled: { progress.isCancelled })
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
                                                              isCancelled: { progress.isCancelled })
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
        projectSummaries[status.project.id] = status.summary
        var states = status.states
        for stage in Stage.allCases {
            if store.runner.failedStagesByProject[status.project.id]?.contains(stage) == true { states[stage] = .failed }
            if store.runner.runningStages[status.project.id] == stage { states[stage] = .running }
        }
        if status.preprocessingNeedsRerun, states[.preprocessing] == .done { states[.preprocessing] = .ready }
        stageStates = states
    }
}
