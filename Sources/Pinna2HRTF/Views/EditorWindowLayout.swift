import SwiftUI

struct EditorWindowLayout<Viewport: View, Inspector: View, Status: View>: View {
    let saveTitle: String
    let canSave: Bool
    let isSaving: Bool
    let actions: EditorWindowActions
    let viewport: Viewport
    let inspector: Inspector
    let status: Status

    init(saveTitle: String, canSave: Bool, isSaving: Bool, actions: EditorWindowActions,
         @ViewBuilder viewport: () -> Viewport, @ViewBuilder inspector: () -> Inspector,
         @ViewBuilder status: () -> Status) {
        self.saveTitle = saveTitle
        self.canSave = canSave
        self.isSaving = isSaving
        self.actions = actions
        self.viewport = viewport()
        self.inspector = inspector()
        self.status = status()
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorPaneSplit(viewport: viewport, inspector: inspector)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                status
                Spacer()
                Button("Cancel", action: actions.close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(saveTitle, action: actions.save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSave)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct EditorPaneSplit<Viewport: View, Inspector: View>: NSViewRepresentable {
    let viewport: Viewport
    let inspector: Inspector

    func makeNSView(context: Context) -> MeshWorkspaceSplitView {
        let split = MeshWorkspaceSplitView(inspectorWidth: 340, minimumViewerWidth: 560,
                                          minimumInspectorWidth: 320, maximumInspectorWidth: 480)
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
    let reset: () -> Void
    let direction: (String) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 8) {
                buttons.buttonStyle(.glass)
            }
        } else {
            buttons
                .buttonStyle(.bordered)
                .padding(6)
                .modifier(ViewportControlsMaterial())
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: reset) { Label("Reset View", systemImage: "arrow.counterclockwise") }
                .labelStyle(.iconOnly)
                .keyboardShortcut("0", modifiers: .command)
                .help("Reset View (⌘0)")
            ForEach(Array(["Front", "Left", "Right"].enumerated()), id: \.offset) { index, name in
                Button(name) { direction(name) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("\(name) View (⌘\(index + 1))")
                    .accessibilityLabel("\(name) View")
            }
        }
        .controlSize(.regular)
        .fixedSize()
    }
}

struct NavigationHelpButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Navigation", systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
        }
        .modifier(ViewerGlassButtonStyle())
        .help("Navigation")
        .popover(isPresented: $showing) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Rotate").foregroundStyle(.secondary)
                    Text("Two-finger scroll, right-drag, or arrow keys")
                }
                GridRow {
                    Text("Pan").foregroundStyle(.secondary)
                    Text("Shift-scroll, Shift-right-drag, middle-drag, or Shift-arrow keys")
                }
                GridRow {
                    Text("Zoom").foregroundStyle(.secondary)
                    Text("Pinch, scroll wheel, Command-scroll, or + and −")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 340, alignment: .leading)
            .padding(16)
        }
    }
}
