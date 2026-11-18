import AppKit
import SceneKit
import simd

extension NSColor {
    static func viewportBackground(darkMode: Bool) -> NSColor {
        NSColor(calibratedWhite: darkMode ? 0.12 : 0.93, alpha: 1)
    }
}

class NavigableSCNView: SCNView {
    var navigationEnabled: Bool { allowsCameraControl }
    var resetView: (() -> Void)?
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
    }

    func navigationWillBegin() {}

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginCameraDrag(event)
    }
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

    override func scrollWheel(with event: NSEvent) {
        guard navigationEnabled else { return }
        navigationWillBegin()
        if event.modifierFlags.contains(.command) {
            zoomCamera(by: Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))
        } else if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.shift) {
                panCamera(x: Float(event.scrollingDeltaX), y: Float(event.scrollingDeltaY))
            } else {
                orbitCamera(x: -Float(event.scrollingDeltaX) * 0.5, y: -Float(event.scrollingDeltaY) * 0.5)
            }
            needsDisplay = true
        } else {
            zoomCamera(by: Double(event.scrollingDeltaY) * 0.08)
        }
    }

    override func magnify(with event: NSEvent) {
        guard navigationEnabled else { return }
        navigationWillBegin()
        zoomCamera(by: Double(event.magnification))
    }

    override func smartMagnify(with event: NSEvent) {
        guard navigationEnabled, let resetView else { return super.smartMagnify(with: event) }
        navigationWillBegin()
        resetView()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard navigationEnabled, !modifiers.contains(.command), !modifiers.contains(.control) else {
            return super.keyDown(with: event)
        }
        let step: Float = 20
        let panning = modifiers.contains(.shift)
        let movement: (x: Float, y: Float)?
        switch event.specialKey {
        case .leftArrow?: movement = (-step, 0)
        case .rightArrow?: movement = (step, 0)
        case .upArrow?: movement = (0, step)
        case .downArrow?: movement = (0, -step)
        default: movement = nil
        }
        if let movement {
            navigationWillBegin()
            if panning {
                panCamera(x: -movement.x, y: movement.y)
            } else {
                orbitCamera(x: -movement.x * 0.5, y: movement.y * 0.5)
            }
            return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=":
            navigationWillBegin()
            zoomCamera(by: 0.2)
        case "-", "_":
            navigationWillBegin()
            zoomCamera(by: -0.2)
        default:
            super.keyDown(with: event)
        }
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
