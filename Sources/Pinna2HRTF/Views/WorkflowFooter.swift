import SwiftUI

struct WorkflowFooter: View {
    @ObservedObject var store: AppStore
<<<<<<< Updated upstream
    private var runningNow: Bool { store.selectedProjectID.flatMap { store.runningProcesses[$0] } != nil }
    var body: some View {
        let action = store.workflowNextAction
        let running = runningNow
        let reason = action.stage.flatMap { store.runUnavailableReason(stage: $0) }
        let failed = action.stage.map { store.stageStates[$0] == .failed } ?? false
        let title = reason != nil ? "Review " + action.step.title.lowercased()
            : failed ? "Retry " + (action.stage?.title ?? action.title) : action.title
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedProjectIsRunning { ProgressView(); Text("Processing…").font(.caption) }
            if failed && reason == nil { Text("The previous run failed. Review the stage inputs before retrying.").font(.caption) }
            if let reason, !store.selectedProjectIsRunning {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Button(running ? "Stop" : title) { store.performWorkflowAction() }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedProject == nil || (!running && (store.selectedProjectIsRunning || !action.enabled)))
=======
    var body: some View {
        let action = store.workflowNextAction
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedProjectIsRunning { ProgressView(); Text("Processing…").font(.caption) }
            if let stage = action.stage, let reason = store.runUnavailableReason(stage: stage), !store.selectedProjectIsRunning {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Button(store.selectedProjectIsRunning ? "Stop" : action.title) { store.performWorkflowAction() }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedProject == nil || (!action.enabled && !store.selectedProjectIsRunning))
>>>>>>> Stashed changes
            Menu("Project actions") {
                Button("Reset outputs…", role: .destructive) { store.confirmResetSelectedProjectOutputs() }
                    .disabled(store.selectedProjectIsRunning)
            }.menuStyle(.borderlessButton)
        }.frame(maxWidth: .infinity, alignment: .leading)
<<<<<<< Updated upstream
        .task(id: store.selectedProjectID) {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                if runningNow && !store.isCheckingProjectFiles && store.selectedProjectStatus?.checkingSolverResults != true {
                    store.refreshArtifacts()
                }
            }
        }
=======
>>>>>>> Stashed changes
    }
}
