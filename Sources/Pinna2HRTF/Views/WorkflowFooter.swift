import SwiftUI

struct WorkflowFooter: View {
    @ObservedObject var store: AppStore
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
            Button("Reset outputs…", role: .destructive) { store.confirmResetSelectedProjectOutputs() }
                .disabled(store.selectedProject == nil || store.selectedProjectIsRunning)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: store.selectedProjectID) {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                if runningNow && !store.isCheckingProjectFiles && store.selectedProjectStatus?.checkingSolverResults != true {
                    store.refreshArtifacts()
                }
            }
        }
    }
}
