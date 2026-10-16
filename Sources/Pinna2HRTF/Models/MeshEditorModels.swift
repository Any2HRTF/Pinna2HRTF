import Foundation

struct MeshEditorRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let source: URL
    let originalSource: URL
    let destination: URL
    let side: EarSide?
    let preparedGeneration: String?
    let preparedReport: URL?
    var isAlignment: Bool { side == nil }
    var title: String { side.map { "Edit \($0.title) Ear" } ?? "Nose and Ear Alignment" }
}
