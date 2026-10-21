import AppKit
import SwiftUI

@MainActor
func meshWorkspaceLayoutChecks() {
    let split = MeshWorkspaceSplitView(inspectorWidth: 340, minimumViewerWidth: 640,
                                      minimumInspectorWidth: 320, maximumInspectorWidth: 440)
    split.setFrameSize(NSSize(width: 1200, height: 640))
    let previewFrame = split.viewerHost.frame
    let inspectorFrame = split.inspectorHost.frame
    precondition(previewFrame.width > 850 && inspectorFrame.width == 340)
    for message in ["Updating…", "Preview is up to date. Continue fitting or save this side."] {
        split.viewerHost.rootView = AnyView(Text(message).frame(minWidth: 2000))
        split.inspectorHost.rootView = AnyView(Text(message).frame(minWidth: 1000))
        split.layoutSubtreeIfNeeded()
        precondition(split.viewerHost.frame == previewFrame && split.inspectorHost.frame == inspectorFrame,
                     "Changing hosted content moved the editor split")
    }
    split.setFrameSize(NSSize(width: 1000, height: 640))
    precondition(split.inspectorHost.frame.width == 340 && split.viewerHost.frame.width >= 640)
    split.setInspectorVisible(false)
    precondition(split.viewerHost.frame.width == 1000)
    split.setInspectorVisible(true)
    precondition(split.inspectorHost.frame.width == 340)
    let workspace = MeshWorkspaceSplitView()
    workspace.setFrameSize(NSSize(width: 1040, height: 640))
    precondition(workspace.inspectorHost.frame.width == 320 && workspace.viewerHost.frame.width > 700)
    print("Mesh workspace and editor split sizes stay stable through content updates and window resizing.")
}
