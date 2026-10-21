import AppKit
import SceneKit

final class PPMFittingSceneView: NavigableSCNView {
    private var cameraRevision = -1

    func update(scene: SCNScene, camera: SCNNode?, target: SCNVector3, span: Double,
                cameraRevision: Int, busy: Bool) {
        let sceneChanged = self.scene !== scene
        if sceneChanged { self.scene = scene }
        // SceneKit may use its own camera after navigation. Preview changes must
        // preserve that camera and its pan target until an explicit view command.
        if sceneChanged || pointOfView == nil || self.cameraRevision != cameraRevision {
            configureNavigation(camera: camera, target: target, span: span)
            self.cameraRevision = cameraRevision
        }
        allowsCameraControl = !busy
        needsDisplay = true
    }
}
