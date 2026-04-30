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
                        ProjectRow(project: project)
                            .tag(project.id)
                            .contextMenu {
                                Button("Remove Project") {
                                    store.selectedProjectID = project.id
                                    store.forgetSelectedProject()
                                }
                            }
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
        }
    }
}
