import SwiftUI

struct RunPanelView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pipeline")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let project = store.selectedProject {
                Text(store.selectedProjectStatus?.numcalcStatus ?? "Checking project files…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if store.preprocessingNeedsRerun(for: project) {
                    Text("Inputs or settings changed · rerun preprocessing")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            VStack(spacing: 2) {
                ForEach(Stage.allCases.filter { $0 != .scanPreparation || store.selectedProject?.scanPreparation.enabled == true }) { stage in
                    StageRunButton(stage: stage, state: store.stageStates[stage] ?? .ready, available: store.canRun(stage: stage), unavailableReason: store.runUnavailableReason(stage: stage), previousResults: store.selectedProjectStatus?.completed.contains(stage) ?? false) {
                        store.run(stage: stage)
                    }
                }
            }
            HStack(spacing: 8) {
                if store.selectedProjectIsRunning {
                Button {
                    store.stopRunningProcess()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(store.selectedProject.map { store.runningProcesses[$0.id] == nil } ?? true)
                } else {
                    Button(store.isCheckingProjectFiles ? "Checking project files…" : store.nextStage.map { "Run \($0.title)" } ?? "All steps complete", systemImage: "play.fill") { store.runNextStage() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canRunNextStage())
                }
                Spacer()
                Menu {
                Button("Reset outputs…", role: .destructive) {
                    store.confirmResetSelectedProjectOutputs()
                }
                .disabled(store.selectedProjectIsRunning)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Project actions")
            }
        }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.top, 2)
        .task(id: store.selectedProjectID) {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                if store.selectedProjectIsRunning && !store.isCheckingProjectFiles && store.selectedProjectStatus?.checkingSolverResults != true { store.refreshArtifacts() }
            }
        }
    }

    var summary: String {
        if store.isCheckingProjectFiles { return "Checking files" }
        if store.selectedProjectIsManagingOutputs { return "Updating outputs" }
        if let id = store.selectedProjectID, store.runningProcesses[id] != nil { return "Running" }
        if store.selectedProjectIsRunning { return "Updating project" }
        if let stage = store.nextStage { return store.canRun(stage: stage) ? "Ready" : "Action needed" }
        if store.selectedProject != nil { return "All steps complete" }
        return "No project"
    }
}

struct StageRunButton: View {
    let stage: Stage
    let state: StageState
    let available: Bool
    let unavailableReason: String?
    let previousResults: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: stage.systemImage)
                    .foregroundStyle(available ? .secondary : .tertiary)
                    .frame(width: 16, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .foregroundStyle(available ? .primary : .secondary)
                        .lineLimit(1)
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)

        }
        .buttonStyle(.plain)
        .help(unavailableReason ?? stateLabel)
        .disabled(!available)
    }

    var stateColor: Color {
        switch state {
        case .ready: .secondary
        case .running: .orange
        case .failed: .red
        case .done: .green
        case .skipped, .stopped: .secondary
        }
    }

    var stateLabel: String {
        if [.failed, .stopped].contains(state) && previousResults { return "\(state.rawValue.capitalized) · previous results available" }
        if state == .done { return "Complete" }
        if state == .skipped { return "Not used" }
        if state == .ready { return available ? "Ready to run" : (unavailableReason ?? "Check requirements") }
        return state.rawValue.capitalized
    }
}
