import SwiftUI

struct WorkflowFooter: View {
    @ObservedObject var store: AppStore
    private var runningNow: Bool { store.selectedProjectID.flatMap { store.runningProcesses[$0] } != nil }

    private func runTitle(_ stage: Stage) -> String {
        switch stage {
        case .scanPreparation: "Prepare ears"
        case .inference: "Run inference"
        case .preprocessing: "Run preprocessing"
        case .numcalc: "Run NumCalc"
        case .postprocessing: "Run postprocessing"
        }
    }

    var body: some View {
        let stage = store.workflowStep.stage
        let reason = stage.flatMap { store.runUnavailableReason(stage: $0) }
        VStack(alignment: .leading, spacing: 8) {
            if store.selectedProjectIsRunning {
                ProgressView()
                Text("Processing…").font(.caption)
            } else if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if runningNow {
                    Button("Stop") { store.stopRunningProcess() }
                }
                if let stage {
                    Button(runTitle(stage)) { store.run(stage: stage) }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!store.canRun(stage: stage))
                }
                Spacer(minLength: 0)
                if !runningNow {
                    Button("Reset outputs…", role: .destructive) { store.confirmResetSelectedProjectOutputs() }
                        .disabled(store.selectedProject == nil || store.selectedProjectIsRunning)
                }
            }
            .controlSize(.small)
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
