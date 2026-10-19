import Foundation
import AppKit
import SceneKit
import simd

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
        precondition(model.tools == [.selection, .plane])
        let view = EditorSCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.model = model
        view.scene = model.scene
        view.configureNavigation(camera: model.pointOfView, target: SCNVector3(model.center), span: model.span)
        view.allowsCameraControl = true
        let camera = view.pointOfView!
        func target() -> SIMD3<Float> {
            let point = view.defaultCameraController.target
            return SIMD3(Float(point.x), Float(point.y), Float(point.z))
        }
        let beforeZoom = simd_distance(camera.simdWorldPosition, target())
        view.zoomCamera(by: 0.2)
        let afterZoom = simd_distance(camera.simdWorldPosition, target())
        precondition(afterZoom < beforeZoom && afterZoom > 0)
        let beforePan = camera.simdWorldPosition
        let targetBeforePan = target()
        view.panCamera(x: 20, y: 10)
        let movement = camera.simdWorldPosition - beforePan
        precondition(simd_length(movement) > 0)
        precondition(simd_length(target() - targetBeforePan - movement) < 0.001)
        let beforeOrbit = camera.simdWorldPosition
        let orbitDistance = simd_distance(beforeOrbit, target())
        view.orbitCamera(x: 15, y: 10)
        precondition(simd_distance(camera.simdWorldPosition, beforeOrbit) > 0.1)
        precondition(abs(simd_distance(camera.simdWorldPosition, target()) - orbitDistance) < 0.001)
        precondition(model.selectedFaces == [1] && model.tool == .selection)
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat,
                   modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            if [.otherMouseDown, .otherMouseDragged, .otherMouseUp].contains(type) {
                let cgType: CGEventType = type == .otherMouseDown ? .otherMouseDown : type == .otherMouseUp ? .otherMouseUp : .otherMouseDragged
                return NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: cgType,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .center)!)!
            }
            return NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        let beforeMouseOrbit = camera.simdWorldPosition
        view.rightMouseDown(with: mouse(.rightMouseDown, 200, 200))
        view.rightMouseDragged(with: mouse(.rightMouseDragged, 250, 220))
        view.rightMouseUp(with: mouse(.rightMouseUp, 250, 220))
        precondition(simd_distance(camera.simdWorldPosition, beforeMouseOrbit) > 0.1)
        let beforeMousePan = target()
        view.rightMouseDown(with: mouse(.rightMouseDown, 200, 200, modifiers: .shift))
        view.rightMouseDragged(with: mouse(.rightMouseDragged, 220, 210, modifiers: .shift))
        view.rightMouseUp(with: mouse(.rightMouseUp, 220, 210, modifiers: .shift))
        precondition(simd_distance(target(), beforeMousePan) > 0.1)
        let middleDown = mouse(.otherMouseDown, 200, 200)
        precondition(middleDown.buttonNumber == 2)
        let beforeMiddlePan = target()
        view.otherMouseDown(with: middleDown)
        view.otherMouseDragged(with: mouse(.otherMouseDragged, 220, 210))
        view.otherMouseUp(with: mouse(.otherMouseUp, 220, 210))
        precondition(simd_distance(target(), beforeMiddlePan) > 0.1)
        precondition(model.selectedFaces == [1] && model.tool == .selection)
        let afterMouseUp = camera.simdWorldPosition
        view.rightMouseDragged(with: mouse(.rightMouseDragged, 300, 250))
        precondition(camera.simdWorldPosition == afterMouseUp)
        // A recreated viewer must recover the scene's off-origin orbit target.
        let previewScene = SCNScene()
        let previewTarget = SCNNode()
        previewTarget.name = "cameraTarget"
        previewTarget.position = SCNVector3(12, 34, 56)
        previewScene.rootNode.addChildNode(previewTarget)
        let previewCamera = SCNNode()
        previewCamera.camera = SCNCamera()
        previewCamera.position = SCNVector3(12, 134, 56)
        previewCamera.constraints = [SCNLookAtConstraint(target: previewTarget)]
        previewScene.rootNode.addChildNode(previewCamera)
        for _ in 0..<2 {
            let preview = NavigableSCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            preview.scene = previewScene
            preview.configureNavigation(camera: previewCamera)
            preview.allowsCameraControl = true
            precondition(preview.defaultCameraController.target.x == 12)
            precondition(preview.defaultCameraController.target.y == 34)
            precondition(preview.defaultCameraController.target.z == 56)
            let position = previewCamera.simdPosition
            preview.rightMouseDown(with: mouse(.rightMouseDown, 200, 200))
            preview.rightMouseDragged(with: mouse(.rightMouseDragged, 250, 220))
            preview.rightMouseUp(with: mouse(.rightMouseUp, 250, 220))
            precondition(simd_distance(position, previewCamera.simdPosition) > 0.1)
        }
        print("Shared viewer mouse rotation, two-button/middle-button panning and target restoration passed.")
        model.busy = true
        let busyPosition = camera.simdWorldPosition
        view.zoomCamera(by: 0.5)
        view.panCamera(x: 20, y: 10)
        view.orbitCamera(x: 15, y: 10)
        precondition(camera.simdWorldPosition == busyPosition)
        model.busy = false
        model.setCameraView("Left")
        precondition(model.pointOfView!.simdPosition.y > model.center.y)
        model.selectedFaces.removeAll()
        await model.edit("largest")
        precondition(model.error == nil, model.error ?? "")
        model.tool = .plane
        await model.moveHistory(-1)
        precondition(model.tool == .selection)
        await model.moveHistory(1)
        precondition(model.tool == .selection)
        print("Editor orbit, zoom, pan, selection preservation and history tool checks passed.")
        let unchanged = try String(contentsOf: source, encoding: .utf8)
        precondition(unchanged == mesh)
        print("Mesh selection inversion, busy guard, camera directions and source preservation passed.")
    }
}
