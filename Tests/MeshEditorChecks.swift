import Foundation

@main
struct MeshEditorChecks {
    @MainActor static func main() async throws {
        pressureQuantityChecks()
        try await pressureFrameChecks()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pinna-selection-check-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tetrahedron.ply")
        let mesh = """
        ply
        format ascii 1.0
        element vertex 4
        property float x
        property float y
        property float z
        element face 4
        property list uchar int vertex_indices
        end_header
        0 0 0
        10 0 0
        0 10 0
        0 0 10
        3 0 2 1
        3 0 1 3
        3 0 3 2
        3 1 2 3
        """
        try mesh.write(to: source, atomically: true, encoding: .utf8)
        let model = MeshEditorModel(request: MeshEditorRequest(projectID: UUID(), source: source,
            originalSource: source, destination: folder.appendingPathComponent("edited.ply"),
            side: .left, preparedGeneration: nil, preparedReport: nil))
        await model.open()
        precondition(model.error == nil, model.error ?? "")
        precondition(model.faces.count == 12)
        model.invertSelection()
        precondition(model.selectedFaces == Set(0..<4))
        model.invertSelection()
        precondition(model.selectedFaces.isEmpty)
        model.selectedFaces = [1]
        model.invertSelection()
        precondition(model.selectedFaces == [0, 2, 3])
        model.invertSelection()
        precondition(model.selectedFaces == [1])
        model.busy = true
        model.invertSelection()
        precondition(model.selectedFaces == [1])
        model.busy = false
        model.setCameraView("Front")
        precondition(model.pointOfView!.simdPosition.x > model.center.x)
        model.setCameraView("Right")
        precondition(model.pointOfView!.simdPosition.y < model.center.y)
        let unchanged = try String(contentsOf: source, encoding: .utf8)
        precondition(unchanged == mesh)
        print("Mesh selection inversion, busy guard, camera directions and source preservation passed.")
    }
}
