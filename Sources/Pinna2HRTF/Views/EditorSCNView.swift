import AppKit
import SceneKit
import simd

final class EditorSCNView: NavigableSCNView {
    weak var model: MeshEditorModel?
    var lastCameraRevision = -1
    private var start: CGPoint = .zero
    private var points: [CGPoint] = []
    private var selecting = false
    private let lasso = CAShapeLayer()

    override init(frame: NSRect = .zero, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        wantsLayer = true
        lasso.strokeColor = NSColor.systemRed.cgColor
        lasso.fillColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
        lasso.lineWidth = 2
        lasso.zPosition = 100
        layer?.addSublayer(lasso)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:options:)") }

    override var navigationEnabled: Bool { model != nil && model?.busy == false }
    override func navigationWillBegin() { cancelSelection() }

    private func cancelSelection() {
        selecting = false
        points.removeAll()
        lasso.path = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, !model.busy else { return }
        start = convert(event.locationInWindow, from: nil)
        if model.tool == .selection {
            selecting = true
            points = [start]
            return
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let model, !model.busy else { return }
        if model.tool == .selection {
            guard selecting else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let last = points.last, hypot(last.x-point.x, last.y-point.y) < 3 { return }
            points.append(point)
            let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
            lasso.path = path
            return
        }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        guard let model, !model.busy else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.tool == .selection {
            guard selecting else { return }
            if points.count >= 3 {
                model.selectPolygon(points, in: self)
            } else {
                let hits = hitTest(point, options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
                if let face = hits.first?.faceIndex {
                    if model.selectedFaces.contains(face) { model.selectedFaces.remove(face) }
                    else { model.selectedFaces.insert(face) }
                    model.refreshOverlays()
                }
            }
            cancelSelection()
            return
        }
        if model.tool == .landmarks && hypot(start.x-point.x, start.y-point.y) < 4 {
            let hits = hitTest(point, options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
            if let hit = hits.first { model.pickLandmark(hit.worldCoordinates) }
        }
        super.mouseUp(with: event)
    }
}
