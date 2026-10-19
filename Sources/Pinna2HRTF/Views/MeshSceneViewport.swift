import AppKit
import SceneKit

// Keep SceneKit's drawable size out of SwiftUI's split-view sizing calculations.
final class MeshSceneViewport: NSView {
    let sceneView = NavigableSCNView()
    private var resizeEndWork: DispatchWorkItem?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize { .zero }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.width, .height]
        sceneView.preferredFramesPerSecond = 60
        addSubview(sceneView)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        resizeEndWork?.cancel()
        resizeEndWork = nil
        let visibleSize = newSize.width > 0 && newSize.height > 0
        sceneView.rendersContinuously = visibleSize
        guard visibleSize else { return }
        // Split-divider drags do not always deliver AppKit's live-resize notifications.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.inLiveResize else { return }
            self.finishResizing()
        }
        resizeEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func finishResizing() {
        resizeEndWork?.cancel()
        resizeEndWork = nil
        sceneView.rendersContinuously = false
        sceneView.needsDisplay = true
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        sceneView.rendersContinuously = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        finishResizing()
    }
}
