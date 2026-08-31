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
                    Image(systemName: "plus")
                }
                .help("New Project")
                Button(role: .destructive) {
                    store.forgetSelectedProject()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove Project")
                .disabled(store.selectedProject == nil)
                Button {
                    store.importProject()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Import Project Folder")
                Button {
                    store.duplicateSelectedProject()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate Project")
                .disabled(store.selectedProject == nil)
                Spacer()
                Text(projectCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
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
