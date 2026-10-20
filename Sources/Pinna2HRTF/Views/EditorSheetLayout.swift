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
            HSplitView {
                viewport.frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                inspector.frame(minWidth: 290, idealWidth: 320, maxWidth: 440)
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 640, idealHeight: 740)
    }
}

struct EditorCameraControls: View {
    let fit: () -> Void
    let direction: (String) -> Void

    var body: some View {
        HStack {
            Button("Fit", action: fit).accessibilityLabel("Fit mesh in view")
            ForEach(["Front", "Left", "Right"], id: \.self) { name in
                Button(name) { direction(name) }.accessibilityLabel("\(name) view")
            }
        }
        .controlSize(.small)
        .padding(8)
        .modifier(ViewportControlsMaterial())
    }
}
