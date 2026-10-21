import AppKit
import SceneKit
import simd

@MainActor
func ppmFittingCameraChecks() {
    let scene = SCNScene()
    let mesh = SCNNode(geometry: SCNSphere(radius: 10))
    scene.rootNode.addChildNode(mesh)
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.position = SCNVector3(12, 134, 56)
    scene.rootNode.addChildNode(camera)
    let target = SCNVector3(12, 34, 56)
    let view = PPMFittingSceneView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    func update(revision: Int = 1, busy: Bool = false) {
        view.update(scene: scene, camera: camera, target: target, span: 100,
                    cameraRevision: revision, busy: busy)
    }
    update()
    precondition(view.pointOfView === camera)

    // Reproduce SceneKit's interactive camera replacing the model's camera.
    let interactiveCamera = camera.clone()
    scene.rootNode.addChildNode(interactiveCamera)
    view.configureNavigation(camera: interactiveCamera, target: target, span: 100)
    view.orbitCamera(x: 25, y: 15)
    view.panCamera(x: 40, y: 20)
    view.zoomCamera(by: 0.3)
    let transform = interactiveCamera.simdWorldTransform
    let orbitTarget = view.defaultCameraController.target
    func checkPreserved() {
        precondition(view.pointOfView === interactiveCamera, "PPM update replaced the interactive camera")
        precondition(interactiveCamera.simdWorldTransform == transform, "PPM update moved the camera")
        let current = view.defaultCameraController.target
        precondition(current.x == orbitTarget.x && current.y == orbitTarget.y && current.z == orbitTarget.z,
                     "PPM update recentered the orbit target")
    }
    for radius in [12.0, 18.0, 7.0] {
        mesh.geometry = SCNSphere(radius: radius)
        update()
        checkPreserved()
    }
    update(busy: true)
    checkPreserved()
    precondition(!view.allowsCameraControl)
    update()
    checkPreserved()
    precondition(view.allowsCameraControl)

    // Fit/direction commands still reset the camera and restore the original target.
    camera.position = SCNVector3(200, 34, 56)
    update(revision: 2)
    precondition(view.pointOfView === camera)
    precondition(view.defaultCameraController.target.x == target.x)
    precondition(view.defaultCameraController.target.y == target.y)
    precondition(view.defaultCameraController.target.z == target.z)
    view.pointOfView = nil
    update(revision: 2)
    precondition(view.pointOfView === camera)

    let replacementScene = SCNScene()
    let replacementCamera = SCNNode()
    replacementCamera.camera = SCNCamera()
    replacementCamera.position = SCNVector3(0, 100, 0)
    replacementScene.rootNode.addChildNode(replacementCamera)
    view.update(scene: replacementScene, camera: replacementCamera, target: SCNVector3Zero,
                span: 50, cameraRevision: 2, busy: false)
    precondition(view.scene === replacementScene && view.pointOfView === replacementCamera)
    print("PPM preview updates preserve camera rotation, pan and zoom; explicit camera commands still reset the view.")
}
