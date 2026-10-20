import AppKit
import SceneKit
import simd

// Shared by mesh previews, fitting, pressure fields, and the ear editor.
class NavigableSCNView: SCNView {
    static let navigationHelp = "Trackpad: two-finger scroll to rotate, pinch to zoom, Shift-scroll to pan. Mouse: right-drag to rotate, Shift-right-drag or middle-drag to pan, wheel to zoom. Command-scroll also zooms."
    var navigationEnabled: Bool { allowsCameraControl }
    private(set) var navigationSpan = 1.0
    private var dragButton: Int?
    private var lastDragPoint = CGPoint.zero

    func configureNavigation(camera: SCNNode?, target: SCNVector3? = nil, span: Double? = nil) {
        pointOfView = camera
        guard let camera else { return }
        let aim = camera.constraints?.compactMap { $0 as? SCNLookAtConstraint }.first
        let target = target ?? aim?.target?.worldPosition
            ?? scene?.rootNode.childNode(withName: "cameraTarget", recursively: false)?.worldPosition ?? SCNVector3Zero
        camera.constraints = nil
        camera.look(at: target, up: SCNVector3(0,0,1), localFront: SCNVector3(0,0,-1))
        let controller = defaultCameraController
        controller.stopInertia()
        controller.pointOfView = camera
        controller.target = target
        controller.worldUp = SCNVector3(0,0,1)
        controller.interactionMode = .orbitTurntable
        navigationSpan = span ?? max(Double(simd_distance(camera.simdWorldPosition,
            SIMD3(Float(target.x), Float(target.y), Float(target.z)))) / 1.4, 0.001)
        toolTip = Self.navigationHelp
    }

    func navigationWillBegin() {}

    override func rightMouseDown(with event: NSEvent) { beginCameraDrag(event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { beginCameraDrag(event) } else { super.otherMouseDown(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) { dragCamera(event) }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2 { dragCamera(event) } else { super.otherMouseDragged(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) { dragButton = nil }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { dragButton = nil } else { super.otherMouseUp(with: event) }
    }

    private func beginCameraDrag(_ event: NSEvent) {
        guard navigationEnabled else { return }
        navigationWillBegin()
        dragButton = event.buttonNumber
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    private func dragCamera(_ event: NSEvent) {
        guard navigationEnabled, dragButton == event.buttonNumber else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = Float(point.x - lastDragPoint.x), y = Float(lastDragPoint.y - point.y)
        lastDragPoint = point
        if event.buttonNumber == 2 || event.modifierFlags.contains(.shift) {
            panCamera(x: -x, y: -y)
        } else {
            orbitCamera(x: -x * 0.5, y: -y * 0.5)
        }
    }

    // Precise scroll events are two-finger trackpad gestures. They never enter
    // the primary-button path used for face clicks and lassos.
    override func scrollWheel(with event: NSEvent) {
        guard navigationEnabled else { return }
        navigationWillBegin()
        if event.modifierFlags.contains(.command) {
            zoomCamera(by: Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))
        } else if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.shift) {
                panCamera(x: Float(event.scrollingDeltaX), y: Float(event.scrollingDeltaY))
            } else {
                orbitCamera(x: Float(event.scrollingDeltaX) * 0.5, y: Float(event.scrollingDeltaY) * 0.5)
            }
            needsDisplay = true
        } else {
            // A conventional mouse wheel retains zooming.
            zoomCamera(by: Double(event.scrollingDeltaY) * 0.08)
        }
    }

    override func magnify(with event: NSEvent) {
        guard navigationEnabled else { return }
        navigationWillBegin()
        zoomCamera(by: Double(event.magnification))
    }

    func orbitCamera(x: Float, y: Float) {
        guard navigationEnabled else { return }
        defaultCameraController.rotateBy(x: x, y: y)
        needsDisplay = true
    }

    func panCamera(x: Float, y: Float) {
        guard navigationEnabled, let camera = pointOfView, bounds.height > 0 else { return }
        let controller = defaultCameraController
        let target = controller.target
        let position = camera.simdWorldPosition
        let distance = simd_length(position - SIMD3(Float(target.x), Float(target.y), Float(target.z)))
        let scale = distance * 2 * tan(Float(camera.camera?.fieldOfView ?? 38) * .pi / 360) / Float(bounds.height)
        controller.translateInCameraSpaceBy(x: -x * scale, y: y * scale, z: 0)
        let shift = camera.simdWorldPosition - position
        controller.target = SCNVector3(SIMD3(Float(target.x), Float(target.y), Float(target.z)) + shift)
        needsDisplay = true
    }

    func zoomCamera(by amount: Double) {
        guard navigationEnabled, let camera = pointOfView, amount.isFinite else { return }
        let target = defaultCameraController.target
        let distance = simd_length(camera.simdWorldPosition - SIMD3(Float(target.x), Float(target.y), Float(target.z)))
        let next = min(Float(navigationSpan * 100), max(Float(navigationSpan * 0.01), distance * Float(exp(-min(2, max(-2, amount))))))
        defaultCameraController.dolly(toTarget: next - distance)
        needsDisplay = true
    }

}
