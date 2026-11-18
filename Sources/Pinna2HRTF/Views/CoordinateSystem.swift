import AppKit
import SceneKit
import simd

enum CoordinateSystem {
    static let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]
    static let directions: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)]

    static func axes(span: Float) -> SCNNode {
        let root = SCNNode()
        root.name = "Coordinate axes"
        for (index, direction) in directions.enumerated() {
            let axis = SCNNode()
            axis.simdOrientation = simd_quatf(from: SIMD3(0,1,0), to: direction)
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

final class CoordinateOrientationView: NSView {
    private let axesView = CoordinateAxesView()

    var cameraOrientation: simd_quatf {
        get { axesView.cameraOrientation }
        set { axesView.cameraOrientation = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        axesView.frame = bounds
        axesView.autoresizingMask = [.width, .height]
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = 12
            glass.contentView = axesView
            surface = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.addSubview(axesView)
            surface = effect
        }
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CoordinateAxesView: NSView {
    var cameraOrientation = simd_quatf(angle: 0, axis: SIMD3(0,0,1)) {
        didSet { if cameraOrientation.vector != oldValue.vector { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let origin = CGPoint(x: bounds.midX, y: bounds.midY - 2)
        let length = min(bounds.width, bounds.height) * 0.32
        let axes = CoordinateSystem.directions.enumerated().map { index, direction in
            (index, cameraOrientation.inverse.act(direction))
        }.sorted { $0.1.z < $1.1.z }
        for (index, direction) in axes {
            let end = CGPoint(x: origin.x + CGFloat(direction.x) * length, y: origin.y + CGFloat(direction.y) * length)
            let line = NSBezierPath()
            line.move(to: origin)
            line.line(to: end)
            line.lineWidth = 2
            line.lineCapStyle = .round
            CoordinateSystem.colors[index].setStroke()
            line.stroke()
            let label = ["X", "Y", "Z"][index] as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CoordinateSystem.colors[index]]
            let size = label.size(withAttributes: attributes)
            let labelCenter = CGPoint(x: origin.x + CGFloat(direction.x) * (length + 9), y: origin.y + CGFloat(direction.y) * (length + 9))
            label.draw(at: CGPoint(x: labelCenter.x - size.width / 2, y: labelCenter.y - size.height / 2), withAttributes: attributes)
        }
    }
}
