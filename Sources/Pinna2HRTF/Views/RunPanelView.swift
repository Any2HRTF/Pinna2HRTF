import SwiftUI

struct RunPanelView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Run")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let project = store.selectedProject {
                Text(ArtifactScanner.numcalcStatus(for: project))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if store.preprocessingNeedsRerun(for: project) {
                    Text("Settings changed · rerun preprocessing before NumCalc")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            VStack(spacing: 6) {
                ForEach(Stage.allCases) { stage in
                    StageRunButton(stage: stage, state: store.stageStates[stage] ?? .ready, available: store.canRun(stage: stage)) {
                        store.run(stage: stage)
                    }
                }
            }
            Button {
                store.stopRunningProcess()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(!store.selectedProjectIsRunning)
            Button(role: .destructive) {
                store.confirmResetSelectedProjectOutputs()
            } label: {
                Label("Reset Outputs…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.selectedProjectIsRunning)
        }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.top, 2)
    }

    var summary: String {
        if store.selectedProjectIsRunning { return "Running" }
        if let project = store.selectedProject { return ArtifactScanner.summary(for: project) }
        return "No project"
    }
}

struct StageRunButton: View {
    let stage: Stage
    let state: StageState
    let available: Bool
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
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!available)
    }

    var stateColor: Color {
        switch state {
        case .ready: .secondary
        case .running: .orange
        case .failed: .red
        case .done: .green
        case .skipped: .secondary
        }
    }

    var stateLabel: String {
        state == .skipped && stage == .inference ? "Skipped · not run" : state.rawValue.capitalized
    }
}
