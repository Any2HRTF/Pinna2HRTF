import SwiftUI

struct WorkflowFooter: View {
    @ObservedObject var store: AppStore
    private var runningNow: Bool { store.selectedProjectID.flatMap { store.runningProcesses[$0] } != nil }

    private var stages: [Stage] {
        switch store.workflowStep {
        case .prepare:
            return store.selectedProject?.scanPreparation.enabled == true ? [.scanPreparation] : []
        case .earModel:
            return store.earModelMethod == .mesh2ppm ? [.inference] : []
        default:
            return store.workflowStep.stage.map { [$0] } ?? []
        }
    }

    private var primaryStage: Stage? {
        let completed = store.selectedProjectStatus?.completed ?? []
        return stages.first { store.canRun(stage: $0) && !completed.contains($0) }
            ?? stages.first { store.canRun(stage: $0) }
            ?? stages.first
    }

    var body: some View {
        HStack(spacing: 8) {
            if store.selectedProjectIsRunning {
                ProgressView().controlSize(.small)
                Text("Processing…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if runningNow {
                    Button("Stop") { store.stopRunningProcess() }
                        .fixedSize()
                }
            } else {
                ForEach(stages) { stage in
                    stageButton(stage, prominent: stage == primaryStage)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Reset Outputs…", role: .destructive) { store.confirmResetSelectedProjectOutputs() }
                        .disabled(store.selectedProject == nil)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("More")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .modifier(FooterBackground())
        .task(id: store.selectedProjectID) {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                if runningNow && !store.isCheckingProjectFiles && store.selectedProjectStatus?.checkingSolverResults != true {
                    store.refreshArtifacts()
                }
            }
        }
    }

    @ViewBuilder private func stageButton(_ stage: Stage, prominent: Bool) -> some View {
        let reason = store.runUnavailableReason(stage: stage)
        let button = Button(stage.workflowRunTitle) { store.run(stage: stage) }
            .fixedSize()
            .disabled(reason != nil)
            .help(reason ?? stage.workflowRunTitle)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

private struct FooterBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(.bar)
        }
    }
}
