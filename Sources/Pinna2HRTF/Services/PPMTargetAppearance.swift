import AppKit
import SceneKit

// Apply explicit alpha to every geometry, including nested ModelIO nodes.
// The fitted PPM keeps its opaque distance colors underneath.
enum PPMTargetAppearance {
    static func apply(to root: SCNNode, opacity: Double, visible: Bool) {
        let opacity = min(1, max(0, opacity))
        root.isHidden = !visible || opacity == 0
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedWhite: 0.62, alpha: 1)
            material.lightingModel = .physicallyBased
            material.isDoubleSided = true
            material.transparency = 1
            material.transparent.contents = NSColor(white: 1, alpha: CGFloat(opacity))
            material.transparencyMode = .singleLayer
            material.blendMode = .alpha
            material.readsFromDepthBuffer = true
            // The single-layer pass needs depth writes to discard rear surfaces;
            // renderingOrder draws it after the opaque PPM has already rendered.
            material.writesToDepthBuffer = true
            geometry.materials = [material]
            node.renderingOrder = opacity < 1 ? 10 : 0
        }
    }
}
