import SwiftUI

struct WorkflowFooter: View {
    @ObservedObject var store: AppStore
    private var runningNow: Bool { store.selectedProjectID.flatMap { store.runningProcesses[$0] } != nil }

    var body: some View {
        let stages: [Stage] = store.workflowStep == .prepare
            ? (store.selectedProject?.scanPreparation.enabled == true ? [.scanPreparation] : [])
                + (store.earModelMethod == .mesh2ppm ? [.inference] : [])
            : store.workflowStep.stage.map { [$0] } ?? []
        let reason = stages.compactMap { store.runUnavailableReason(stage: $0) }.first
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedProjectIsRunning {
                Text("Processing…").font(.caption)
            } else if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if runningNow {
                    Button("Stop") { store.stopRunningProcess() }
                }
                ForEach(stages) { stage in
                    Button(stage.workflowRunTitle) {
                        store.run(stage: stage)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!store.canRun(stage: stage))
                    .help(stage.workflowRunTitle)
                }
                Spacer(minLength: 0)
                if !runningNow {
                    Button("Reset outputs…", role: .destructive) { store.confirmResetSelectedProjectOutputs() }
                        .disabled(store.selectedProject == nil || store.selectedProjectIsRunning)
                }
            }
            .controlSize(.regular)
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
