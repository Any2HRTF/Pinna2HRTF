import AppKit
import SwiftUI

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
