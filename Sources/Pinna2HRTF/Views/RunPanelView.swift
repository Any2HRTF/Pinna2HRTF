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
            }
            VStack(spacing: 6) {
                ForEach(Stage.allCases) { stage in
                    StageRunButton(stage: stage, state: store.stageStates[stage] ?? .ready) {
                        store.run(stage: stage)
                    }
                    .disabled(!store.canRun(stage: stage))
                }
            }
            Button {
                store.stopRunningProcess()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(!selectedProjectIsRunning)
            Button(role: .destructive) {
                store.resetSelectedProjectOutputs()
            } label: {
                Label("Reset", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .disabled(selectedProjectIsRunning)
        }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.top, 2)
    }

    var summary: String {
        if selectedProjectIsRunning { return "Running" }
        if let project = store.selectedProject { return ArtifactScanner.summary(for: project) }
        return "No project"
    }

    var selectedProjectIsRunning: Bool {
        guard let project = store.selectedProject else { return false }
        return store.runningProcesses[project.id] != nil
    }
}

struct StageRunButton: View {
    let stage: Stage
    let state: StageState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: stage.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .lineLimit(1)
                    Text(state.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    var stateColor: Color {
        switch state {
        case .ready: .secondary
        case .running: .orange
        case .failed: .red
        case .done: .green
        }
    }
}
