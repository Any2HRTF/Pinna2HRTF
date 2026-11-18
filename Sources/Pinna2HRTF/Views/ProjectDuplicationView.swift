import SwiftUI
import AppKit

struct ProjectDuplicationView: View {
    @ObservedObject var store: AppStore
    let request: ProjectDuplicationRequest
    @State private var name: String
    @State private var parentFolder: String
    @State private var busy = false
    @State private var error: String?

    init(store: AppStore, request: ProjectDuplicationRequest) {
        self.store = store
        self.request = request
        _name = State(initialValue: request.suggestedName)
        _parentFolder = State(initialValue: request.parentFolder)
    }

    private var destination: URL? {
        try? ProjectDuplicator.destination(name: name, parentFolder: parentFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Duplicate “\(request.project.name)”")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("duplicate.projectName")
                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        Text(URL(fileURLWithPath: (parentFolder as NSString).expandingTildeInPath, isDirectory: true).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destination?.path ?? parentFolder)
                        Button("Choose…", action: chooseParentFolder)
                            .fixedSize()
                            .accessibilityLabel("Choose Location")
                    }
                }
                if let error {
                    FieldWarning(error)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Copying…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { store.projectDuplicationRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Duplicate", action: duplicate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (parentFolder as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { parentFolder = url.path }
    }

    private func duplicate() {
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await store.duplicateProject(request, name: name, parentFolder: parentFolder)
                store.projectDuplicationRequest = nil
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
