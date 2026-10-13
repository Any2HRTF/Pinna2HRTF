import SwiftUI

struct ProjectSidebarView: View {
    @ObservedObject var store: AppStore
    @State private var showingFolderEditor = false
    @State private var folderName = ""
    @State private var editingFolderID: UUID?
    @State private var movingProjectID: UUID?
    @State private var selectedFolderID: UUID?


    var body: some View {
        VStack(spacing: 0) {
            if let message = store.persistenceMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    if store.registryStore.savingBlocked {
                        Button("Review recovery options") { store.registryRecoveryPresented = true }
                    }
                }
                .padding(10)
            }
            NativeProjectSidebar(store: store, selectedFolderID: $selectedFolderID) { folder, projectID in
                editFolder(folder, moving: projectID)
            }
        }
        .navigationTitle("Projects")
        .onChange(of: store.selectedProjectID) { _ in selectedFolderID = nil }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    store.createProject()
                } label: {
                    Label("New Project", systemImage: "plus")
                        .frame(width: 28, height: 28)
                }
                .help("Create a new empty project")
                Button(role: .destructive) {
                    if let id = selectedFolderID {
                        selectedFolderID = nil
                        store.removeFolder(id)
                    } else {
                        store.forgetSelectedProject()
                    }
                } label: {
                    Label(selectedFolderID == nil ? "Remove Project" : "Remove Folder", systemImage: "minus")
                        .frame(width: 28, height: 28)
                }
                .help(selectedFolderID == nil ? "Remove the selected project from Pinna2HRTF" : "Remove the selected folder and keep its projects")
                .disabled(selectedFolderID == nil && !store.canRemoveSelectedProject)
                Button { editFolder() } label: {
                    Label("New Folder", systemImage: "folder.badge.plus").frame(width: 28, height: 28)
                }
                .help("Create a folder to organize projects")
                Button {
                    store.importProject()
                } label: {
                    Label("Import Project", systemImage: "square.and.arrow.down")
                        .frame(width: 28, height: 28)
                }
                .help("Import an existing project folder")
                Button {
                    store.duplicateSelectedProject()
                } label: {
                    Label("Duplicate Project", systemImage: "plus.square.on.square")
                        .frame(width: 28, height: 28)
                }
                .help("Duplicate the selected project, including its results")
                .disabled(store.selectedProject == nil)
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showingFolderEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editingFolderID == nil ? "New Folder" : "Rename Folder")
                    .font(.headline)
                TextField("Folder name", text: $folderName)
                    .onSubmit { saveFolder() }
                HStack {
                    Spacer()
                    Button("Cancel") { showingFolderEditor = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { saveFolder() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 300)
        }
        .modifier(WorkspaceScrollEdges())
    }

    private func editFolder(_ folder: ProjectFolder? = nil, moving projectID: UUID? = nil) {
        editingFolderID = folder?.id
        movingProjectID = projectID
        folderName = folder?.name ?? ""
        showingFolderEditor = true
    }

    private func saveFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let id = editingFolderID {
            store.renameFolder(id, to: name)
        } else {
            let id = store.createFolder(named: name)
            if let projectID = movingProjectID { store.moveProject(projectID, toFolder: id) }
        }
        showingFolderEditor = false
    }

}

struct ProjectRow: View {
    let project: ProjectRecord
    let runningStage: Stage?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(ArtifactScanner.summary(for: project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let runningStage {
                ProgressView()
                    .controlSize(.small)
                    .help("\(runningStage.title) running")
            }
        }
    }
}
