import SwiftUI

struct ProjectSidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        List(selection: $store.selectedProjectID) {
            Section("Projects") {
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
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "ear")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pinna2HRTF")
                            .font(.headline)
                        Text("Project workspace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    Button {
                        store.createProject()
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    Button(role: .destructive) {
                        store.forgetSelectedProject()
                    } label: {
                        Label("Remove Project", systemImage: "minus")
                    }
                    .disabled(store.selectedProject == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            EnvironmentPanelView(store: store)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.bar)
        }
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
