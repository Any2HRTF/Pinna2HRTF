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
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate Project").font(.headline)
            Text("Create a copy of \(request.project.name), including its saved meshes and fits.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Project name").font(.subheadline.weight(.medium))
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("duplicate.projectName")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Save location").font(.subheadline.weight(.medium))
                HStack {
                    TextField("Parent folder", text: $parentFolder)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Save location")
                        .accessibilityIdentifier("duplicate.parentFolder")
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Choose"
                        panel.message = "Choose the parent folder for the duplicate project."
                        panel.directoryURL = URL(fileURLWithPath: (parentFolder as NSString).expandingTildeInPath)
                        if panel.runModal() == .OK, let url = panel.url { parentFolder = url.path }
                    }
                    .accessibilityLabel("Choose save location")
                }
                Text("A project folder will be created here. Missing parent folders will also be created.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("New project folder").font(.caption.weight(.semibold))
                Text(destination?.path ?? "Enter a valid project name and save location.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Copying project…").font(.caption) }
                Spacer()
                Button("Cancel") { store.projectDuplicationRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Duplicate") {
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil)
            }
        }
        .padding(20).frame(width: 520)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
    }
}
