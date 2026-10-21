import AppKit
import SwiftUI

final class MeshWorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    let viewerHost = NSHostingView(rootView: AnyView(EmptyView()))
    let inspectorHost = NSHostingView(rootView: AnyView(EmptyView()))
    var displayedLogExpanded = false
    private var inspectorVisible = true
    private var inspectorWidth: CGFloat
    private let minimumViewerWidth: CGFloat
    private let minimumInspectorWidth: CGFloat
    private let maximumInspectorWidth: CGFloat
    private var arranging = false
    private var applyingSize = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var fittingSize: NSSize { .zero }

    init(inspectorWidth: CGFloat = 320, minimumViewerWidth: CGFloat = 340,
         minimumInspectorWidth: CGFloat = 260, maximumInspectorWidth: CGFloat = 720) {
        self.inspectorWidth = inspectorWidth
        self.minimumViewerWidth = minimumViewerWidth
        self.minimumInspectorWidth = minimumInspectorWidth
        self.maximumInspectorWidth = maximumInspectorWidth
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        // Pane minimums belong to the split view, not its hosted content's current size.
        viewerHost.sizingOptions = []
        inspectorHost.sizingOptions = []
        applyingSize = true
        addArrangedSubview(viewerHost)
        addArrangedSubview(inspectorHost)
        applyingSize = false
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func setInspectorVisible(_ visible: Bool) {
        guard visible != inspectorVisible else { return }
        if inspectorVisible { inspectorWidth = max(minimumInspectorWidth, inspectorHost.frame.width) }
        inspectorVisible = visible
        applyingSize = true
        if visible {
            inspectorHost.isHidden = false
            addArrangedSubview(inspectorHost)
        } else {
            // A hidden zero-width pane can leave NSSplitView's old divider painted
            // over the expanded Metal viewer. Remove the pane from the split entirely.
            removeArrangedSubview(inspectorHost)
            inspectorHost.removeFromSuperview()
            inspectorHost.isHidden = true
        }
        applyingSize = false
        arrangePanes()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasApplyingSize = applyingSize
        applyingSize = true
        super.setFrameSize(newSize)
        applyingSize = wasApplyingSize
        arrangePanes()
    }

    private func arrangePanes() {
        guard !arranging else { return }
        arranging = true
        defer { arranging = false }
        let divider = inspectorVisible ? min(dividerThickness, max(0, bounds.width)) : 0
        let available = max(0, bounds.width - divider)
        let width = inspectorVisible ? min(max(minimumInspectorWidth, inspectorWidth), maximumInspectorWidth,
                                          max(0, available - minimumViewerWidth)) : 0
        viewerHost.frame = NSRect(x: 0, y: 0, width: available - width, height: bounds.height)
        inspectorHost.frame = NSRect(x: available - width + divider, y: 0, width: width, height: bounds.height)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrangePanes() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(max(minimumViewerWidth, bounds.width - dividerThickness - maximumInspectorWidth), max(0, bounds.width - dividerThickness))
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(minimumViewerWidth, bounds.width - dividerThickness - minimumInspectorWidth)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, !applyingSize, inspectorVisible,
              bounds.width >= minimumViewerWidth + minimumInspectorWidth + dividerThickness,
              inspectorHost.frame.width >= minimumInspectorWidth, viewerHost.frame.width >= minimumViewerWidth else { return }
        inspectorWidth = min(maximumInspectorWidth, max(minimumInspectorWidth, inspectorHost.frame.width))
    }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { !inspectorVisible }
}
