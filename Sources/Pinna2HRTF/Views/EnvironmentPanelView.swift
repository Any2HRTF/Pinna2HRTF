import SwiftUI

struct EnvironmentPanelView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment")
                    .font(.headline)
                Spacer()
                Text(allToolsReady ? "Ready" : "Missing")
                    .font(.caption)
                    .foregroundStyle(allToolsReady ? .green : .red)
            }
            ToolStatusRow("UV", path: store.environment.uvExecutable)
            ToolStatusRow("NumCalc", path: store.environment.numcalcExecutable)
            ToolStatusRow("Mesh grading", path: store.environment.meshGradingExecutable)
            Button {
                store.setupEnvironment()
            } label: {
                Label("Set Up", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.environmentProcess != nil || !FileManager.default.isExecutableFile(atPath: store.environment.uvExecutable))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    var allToolsReady: Bool {
        FileManager.default.isExecutableFile(atPath: store.environment.uvExecutable) &&
        FileManager.default.isExecutableFile(atPath: store.environment.numcalcExecutable) &&
        FileManager.default.isExecutableFile(atPath: store.environment.meshGradingExecutable)
    }
}

struct ToolStatusRow: View {
    let title: String
    let path: String

    init(_ title: String, path: String) {
        self.title = title
        self.path = path
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isInstalled ? .green : .red)
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(isInstalled ? "Installed" : "Missing")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isInstalled ? .green : .red)
        }
    }
}
