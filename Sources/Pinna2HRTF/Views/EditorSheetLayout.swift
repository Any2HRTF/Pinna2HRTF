import SwiftUI

/// Shared chrome for alignment, ear editing, and parametric fitting sheets.
/// Keep controls as ordinary labelled children; do not combine the inspector's accessibility tree.
struct EditorSheetLayout<Header: View, Viewport: View, Inspector: View, Footer: View>: View {
    let header: Header
    let viewport: Viewport
    let inspector: Inspector
    let footer: Footer

    init(@ViewBuilder header: () -> Header, @ViewBuilder viewport: () -> Viewport,
         @ViewBuilder inspector: () -> Inspector, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.viewport = viewport()
        self.inspector = inspector()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            EditorPaneSplit(viewport: viewport, inspector: inspector)
                .frame(minWidth: 961, minHeight: 480, maxHeight: .infinity)
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 640, idealHeight: 740)
    }
}

private struct EditorPaneSplit<Viewport: View, Inspector: View>: NSViewRepresentable {
    let viewport: Viewport
    let inspector: Inspector

    func makeNSView(context: Context) -> MeshWorkspaceSplitView {
        let split = MeshWorkspaceSplitView(inspectorWidth: 340, minimumViewerWidth: 640,
                                          minimumInspectorWidth: 320, maximumInspectorWidth: 440)
        updateNSView(split, context: context)
        return split
    }

    func updateNSView(_ split: MeshWorkspaceSplitView, context: Context) {
        split.viewerHost.rootView = AnyView(viewport)
        split.inspectorHost.rootView = AnyView(inspector)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeshWorkspaceSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0)
    }
}

struct EditorCameraControls: View {
    let fit: () -> Void
    let direction: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: fit) { Text("Fit").frame(width: 42, height: 20) }
                .accessibilityLabel("Fit mesh in view")
            ForEach(["Front", "Left", "Right"], id: \.self) { name in
                Button { direction(name) } label: { Text(name).frame(width: 42, height: 20) }
                    .accessibilityLabel("\(name) view")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .padding(8)
        .modifier(ViewportControlsMaterial())
    }
}

struct NavigationHelpButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Navigation", systemImage: "questionmark.circle")
        }
        .modifier(ViewerGlassButtonStyle())
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Navigation").font(.headline)
                Text("Trackpad: Two-finger scroll to rotate, pinch to zoom, Shift-scroll to pan.")
                Text("Mouse: Right-drag to rotate, Shift-right-drag or middle-drag to pan, wheel to zoom.")
                Text("Command-scroll also zooms.")
            }
            .font(.callout)
            .frame(width: 290, alignment: .leading)
            .padding(16)
        }
    }
}
