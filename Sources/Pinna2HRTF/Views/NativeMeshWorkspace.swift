import AppKit
import SwiftUI

// Own the pane sizes directly instead of letting SwiftUI's inspector repeatedly
// change NSHostingView minimum constraints during the window's constraint pass.
struct NativeMeshWorkspace: NSViewRepresentable {
    @ObservedObject var store: AppStore
    @Binding var logExpanded: Bool
    let inspectorPresented: Bool

    func makeNSView(context: Context) -> MeshWorkspaceSplitView {
        let split = MeshWorkspaceSplitView()
        split.viewerHost.rootView = AnyView(MeshViewerView(store: store, logExpanded: $logExpanded))
        split.inspectorHost.rootView = AnyView(ProjectInspectorView(store: store))
        split.displayedLogExpanded = logExpanded
        split.setInspectorVisible(inspectorPresented)
        return split
    }

    func updateNSView(_ split: MeshWorkspaceSplitView, context: Context) {
        // The hosted views observe the store themselves; keep their identity through resizes.
        if split.displayedLogExpanded != logExpanded {
            split.viewerHost.rootView = AnyView(MeshViewerView(store: store, logExpanded: $logExpanded))
            split.displayedLogExpanded = logExpanded
        }
        split.setInspectorVisible(inspectorPresented)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeshWorkspaceSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0)
    }
}

final class MeshWorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    let viewerHost = NSHostingView(rootView: AnyView(EmptyView()))
    let inspectorHost = NSHostingView(rootView: AnyView(EmptyView()))
    var displayedLogExpanded = false
    private var inspectorVisible = true
    private var inspectorWidth: CGFloat = 360
    private var arranging = false
    private var applyingSize = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var fittingSize: NSSize { .zero }

    init() {
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
        if inspectorVisible { inspectorWidth = max(260, inspectorHost.frame.width) }
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
        let width = inspectorVisible ? min(max(260, inspectorWidth), 720, max(0, available - 280)) : 0
        viewerHost.frame = NSRect(x: 0, y: 0, width: available - width, height: bounds.height)
        inspectorHost.frame = NSRect(x: available - width + divider, y: 0, width: width, height: bounds.height)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrangePanes() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(max(280, bounds.width - dividerThickness - 720), max(0, bounds.width - dividerThickness))
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(280, bounds.width - dividerThickness - 260)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, !applyingSize, inspectorVisible, bounds.width >= 540,
              inspectorHost.frame.width >= 260, viewerHost.frame.width >= 280 else { return }
        inspectorWidth = min(720, max(260, inspectorHost.frame.width))
    }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { !inspectorVisible }
}
