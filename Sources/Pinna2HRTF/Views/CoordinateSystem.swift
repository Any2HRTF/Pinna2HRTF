import AppKit
import SceneKit
import simd

// Display-only geometry: excluded from mesh hit testing and saved output.
enum CoordinateSystem {
    static let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]
    static let directions: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)]

    static func axes(span: Float) -> SCNNode {
        let root = SCNNode()
        root.name = "Coordinate axes"
        for (index, direction) in directions.enumerated() {
            let axis = SCNNode()
            axis.simdOrientation = simd_quatf(from: SIMD3(0,1,0), to: direction)
            // Extend well past the scan in both directions, with thickness
            // based on the mesh size rather than the length of the axis.
            let shaft = SCNCylinder(radius: CGFloat(span * 0.0015), height: CGFloat(span * 10))
            shaft.radialSegmentCount = 8
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = colors[index]
            shaft.materials = [material]
            axis.addChildNode(SCNNode(geometry: shaft))
            root.addChildNode(axis)
        }
        root.enumerateChildNodes { node, _ in node.categoryBitMask = 32 }
        root.categoryBitMask = 32
        return root
    }
}

// A camera-linked orientation reference stays visible even when the scan's
// original origin lies outside the viewport. It never intercepts mesh clicks.
final class CoordinateOrientationView: NSView {
    var cameraOrientation = simd_quatf(angle: 0, axis: SIMD3(0,0,1)) {
        didSet { if cameraOrientation.vector != oldValue.vector { needsDisplay = true } }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let origin = CGPoint(x: bounds.midX, y: bounds.midY - 2)
        let axes = CoordinateSystem.directions.enumerated().map { index, direction in
            (index, cameraOrientation.inverse.act(direction))
        }.sorted { $0.1.z < $1.1.z }
        for (index, direction) in axes {
            let end = CGPoint(x: origin.x + CGFloat(direction.x) * 32, y: origin.y + CGFloat(direction.y) * 32)
            let line = NSBezierPath()
            line.move(to: origin); line.line(to: end)
            line.lineWidth = 2
            CoordinateSystem.colors[index].setStroke(); line.stroke()
            let label = ["X", "Y", "Z"][index] as NSString
            label.draw(at: CGPoint(x: end.x - 4, y: end.y - 5), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: CoordinateSystem.colors[index],
                .backgroundColor: NSColor(calibratedWhite: 0.12, alpha: 0.85)])
        }
    }
}
