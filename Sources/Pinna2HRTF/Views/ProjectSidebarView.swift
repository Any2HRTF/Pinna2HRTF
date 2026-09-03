import SwiftUI

struct ProjectSidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        List(selection: $store.selectedProjectID) {
            Section("Projects") {
                if store.projects.isEmpty {
                    Text("No Projects")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project, runningStage: store.runningStages[project.id])
                            .tag(project.id)
                            .contextMenu {
                                Button("Duplicate Project") {
                                    store.selectedProjectID = project.id
                                    store.duplicateSelectedProject()
                                }
                                Button("Remove Project") {
                                    store.selectedProjectID = project.id
                                    store.forgetSelectedProject()
                                }
                            }
                    }
                    .onMove { source, destination in
                        store.projects.move(fromOffsets: source, toOffset: destination)
                        store.persist()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
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
                    store.forgetSelectedProject()
                } label: {
                    Label("Remove Project", systemImage: "minus")
                        .frame(width: 28, height: 28)
                }
                .help("Remove the selected project from Pinna2HRTF")
                .disabled(store.selectedProject == nil)
                Button {
                    store.importProject()
                } label: {
                    Label("Import Project", systemImage: "folder.badge.plus")
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
                Spacer()
                Text(projectCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .modifier(WorkspaceScrollEdges())
    }

    var projectCountText: String {
        store.projects.count == 1 ? "1 project" : "\(store.projects.count) projects"
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
