import AppKit
import SceneKit

enum PPMTargetAppearance {
    static func apply(to root: SCNNode, opacity: Double, visible: Bool) {
        let opacity = min(1, max(0, opacity))
        root.isHidden = !visible || opacity == 0
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedWhite: 0.62, alpha: 1)
            material.lightingModel = .blinn
            material.isDoubleSided = true
            material.transparency = 1
            material.transparent.contents = NSColor(white: 1, alpha: CGFloat(opacity))
            material.transparencyMode = .singleLayer
            material.blendMode = .alpha
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = true
            geometry.materials = [material]
            node.renderingOrder = opacity < 1 ? 10 : 0
        }
    }
}
