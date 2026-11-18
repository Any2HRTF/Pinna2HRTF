import SwiftUI

struct FolderEditorRequest: Identifiable {
    let id = UUID()
    var folder: ProjectFolder?
    var movingProjectID: UUID?
}

struct ProjectSidebarView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedFolderID: UUID?
    @Binding var folderEditor: FolderEditorRequest?

    var body: some View {
        NativeProjectSidebar(store: store, selectedFolderID: $selectedFolderID) { folder, projectID in
            folderEditor = FolderEditorRequest(folder: folder, movingProjectID: projectID)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = store.persistenceMessage {
                VStack(alignment: .leading, spacing: 6) {
                    FieldWarning(message)
                    if store.registryStore.savingBlocked {
                        Button("Recovery Options…") { store.registryRecoveryPresented = true }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    Button("New Project", action: store.createProject)
                    Button("New Folder…") { folderEditor = FolderEditorRequest() }
                    Divider()
                    Button("Import Project…", action: store.importProject)
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    store.createProject()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New Project")
                Button(action: removeSelection) {
                    Label(selectedFolderID == nil ? "Remove Project" : "Remove Folder", systemImage: "minus")
                }
                .buttonStyle(.borderless)
                .help(selectedFolderID == nil ? "Remove Project" : "Remove Folder")
                .disabled(selectedFolderID == nil && !store.canRemoveSelectedProject)
                Spacer(minLength: 0)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: store.selectedProjectID) { _ in selectedFolderID = nil }
        .sheet(item: $folderEditor) { request in
            FolderEditorSheet(request: request) { name in
                if let folder = request.folder {
                    store.renameFolder(folder.id, to: name)
                } else {
                    let id = store.createFolder(named: name)
                    if let projectID = request.movingProjectID { store.moveProject(projectID, toFolder: id) }
                }
            }
        }
    }

    private func removeSelection() {
        if let id = selectedFolderID {
            selectedFolderID = nil
            store.removeFolder(id)
        } else {
            store.removeSelectedProject()
        }
    }
}

private struct FolderEditorSheet: View {
    let request: FolderEditorRequest
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(request: FolderEditorRequest, save: @escaping (String) -> Void) {
        self.request = request
        self.save = save
        _name = State(initialValue: request.folder?.name ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.folder == nil ? "New Folder" : "Rename Folder")
                .font(.headline)
            TextField("Name", text: $name)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.folder == nil ? "Create" : "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        save(trimmedName)
        dismiss()
    }
}

struct ProjectRow: View {
    let project: ProjectRecord
    let runningStage: Stage?
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .lineLimit(1)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "ear")
            }
            Spacer(minLength: 6)
            if let runningStage {
                ProgressView()
                    .controlSize(.small)
                    .help("\(runningStage.title) running")
            }
        }
        .padding(.vertical, 3)
    }
}
