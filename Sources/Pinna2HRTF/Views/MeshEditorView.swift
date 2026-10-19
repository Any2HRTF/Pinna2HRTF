import SwiftUI
import SceneKit
import AppKit

struct MeshEditorView: View {
    @StateObject private var model: MeshEditorModel
    @Environment(\.dismiss) private var dismiss
    var closeWindow: (() -> Void)?
    var busyChanged: (Bool) -> Void = { _ in }
    let saved: (MeshEditorRequest) -> Void

    init(request: MeshEditorRequest, closeWindow: (() -> Void)? = nil, busyChanged: @escaping (Bool) -> Void = { _ in }, saved: @escaping (MeshEditorRequest) -> Void) {
        _model = StateObject(wrappedValue: MeshEditorModel(request: request))
        self.closeWindow = closeWindow
        self.busyChanged = busyChanged
        self.saved = saved
    }

    private func closeEditor() {
        if let closeWindow { closeWindow() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.request.title).font(.headline)
                    Text("\(model.request.source.lastPathComponent) · Original mesh is preserved").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }.padding(16)
            Divider()
            HSplitView {
                ZStack(alignment: .topTrailing) {
                    EditorSceneView(model: model)
                        HStack {
                            Button("Fit") { model.resetCamera() }
                            ForEach(["Front", "Left", "Right"], id: \.self) { direction in
                                Button(direction) { model.setCameraView(direction) }
                            }
                        }
                        .controlSize(.small)
                        .padding(8)
                        .modifier(ViewportControlsMaterial())
                        .padding(12)

                }
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.request.isAlignment {
                            alignmentControls

                        } else {
                            Picker("Tool", selection: $model.tool) {
                                ForEach(model.tools) { tool in Text(tool.rawValue).tag(tool) }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: model.tool) { _ in model.refreshOverlays() }
                        }
                        if model.tool == .navigate { navigationControls }
                        if !model.request.isAlignment && model.tool == .landmarks { alignmentControls }
                        if model.tool == .selection { selectionControls }
                        if model.tool == .plane { planeControls }
                        Divider()
                        HStack {
                            Button("Undo") { Task { await model.moveHistory(-1) } }.disabled(!model.canUndo)
                            Button("Redo") { Task { await model.moveHistory(1) } }.disabled(!model.canRedo)
                        }
                        if !model.request.isAlignment {
                            Menu("Mesh Cleanup") {
                            Button("Keep Largest Component") { Task { await model.edit("largest") } }
                                .help("Remove disconnected fragments from this working copy. Undo is available.")
                            }
                        }
                        Text(model.message).font(.caption).foregroundStyle(.secondary)
                        if let error = model.error {
                            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }.padding(16)
                }.frame(minWidth: 290, idealWidth: 320, maxWidth: 440)
                .disabled(model.busy)
            }
            Divider()
            HStack {
                Text(model.request.isAlignment ? "Preview a rigid alignment before saving." : "Cuts remain open. Saving checks the attachment boundary and ear-canal opening.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { closeEditor() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(model.request.isAlignment ? "Save Aligned Scan" : "Save Ear") {
                    Task {
                        if await model.save() { saved(model.request); closeEditor() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 640, idealHeight: 740)
        .interactiveDismissDisabled(model.busy)
        .onChange(of: model.busy) { busyChanged($0) }
        .task { await model.open() }
    }

    var alignmentControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nose and ear landmarks").font(.subheadline.weight(.semibold))
            Text(model.landmarks.count == 3 ? "All landmarks placed. Preview the alignment, or select a row to replace a point." : "\(model.landmarks.count + 1) of 3 — Select \(["the nose tip", "the left ear-canal entrance", "the right ear-canal entrance"][min(model.landmarkSlot, 2)]).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(["Nose tip", "Left ear-canal entrance", "Right ear-canal entrance"].enumerated()), id: \.offset) { index, name in
                Button {
                    model.landmarkSlot = min(index, model.landmarks.count)
                } label: {
                    HStack {
                        Image(systemName: index < model.landmarks.count ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle([Color.red, .blue, .green][index])
                        Text(name)
                        Spacer()
                        Text(index < model.landmarks.count ? "Placed" : (model.landmarkSlot == index ? "Current" : "Pending"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(index > model.landmarks.count)
            }
            DisclosureGroup("Alignment Details") {
            Text("Pick the tip of the nose and the center of each ear-canal entrance. Their plane becomes horizontal, with the ear midpoint at the origin, X toward the nose, Y left, and Z up. Left and right refer to the person being scanned.")
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.landmarks.count != 3 {
                Text("Place all three landmarks to preview.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Preview Alignment") {
                let points = model.landmarks.map { [Double($0.x), Double($0.y), Double($0.z)] }
                Task { await model.edit("align", arguments: ["points": points]) }
            }
            .disabled(model.landmarks.count != 3)
        }
    }

    var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Draw a closed lasso around the faces to remove. A click toggles one face. Red faces are selected.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Select through mesh", isOn: $model.throughSelection)
                .help("Include occluded and back-facing faces. With this off, select only the visible front surface.")
            Toggle("Add to current selection", isOn: $model.addToSelection)
            Text("\(model.selectedFaces.count) faces selected").font(.caption.monospacedDigit())
            Button("Delete Selected Faces") {
                Task { await model.edit("delete", arguments: ["faces": model.selectedFaces.sorted()]) }
            }.disabled(model.selectedFaces.isEmpty)
            HStack {
            Button("Invert Selection") { model.invertSelection() }
                .disabled(model.faces.isEmpty)
            Button("Clear Selection") { model.selectedFaces.removeAll(); model.refreshOverlays() }
                .disabled(model.selectedFaces.isEmpty)
            }
        }
    }

    var navigationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to rotate and scroll to zoom. Choose Select Faces or Cutting Plane to edit.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    var planeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move or angle the cyan plane. Choose automatic fitting or set a smaller preview size below. The cut extends through the mesh; red marks the side to remove. Apply to preview the open boundary before saving.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(["X", "Y", "Z"], id: \.self) { axis in
                    Button(axis) {
                        model.planeX = axis == "X" ? "1" : "0"
                        model.planeY = axis == "Y" ? "1" : "0"
                        model.planeZ = axis == "Z" ? "1" : "0"
                        model.refreshOverlays()
                    }
                }
            }
            HStack {
                Text("Normal")
                TextField("X", text: $model.planeX).accessibilityLabel("Plane normal X")
                TextField("Y", text: $model.planeY).accessibilityLabel("Plane normal Y")
                TextField("Z", text: $model.planeZ).accessibilityLabel("Plane normal Z")
            }.textFieldStyle(.roundedBorder)
            HStack {
                Text("Offset (mm)")
                TextField("Offset", value: $model.planeOffset, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
            }
            Slider(value: $model.planeOffset, in: -model.span/2...model.span/2)
                .accessibilityLabel("Cutting plane offset")
            Toggle("Fit plane preview to mesh", isOn: $model.fitPlanePreview)
                .help("Resize the cyan preview automatically to fit the mesh at the cut. Turn off to set its width and height.")
            if !model.fitPlanePreview {
                VStack(spacing: 6) {
                    HStack {
                        Text("Width (mm)")
                        TextField("Width", value: $model.planePreviewWidth, format: .number.precision(.fractionLength(2)))
                            .accessibilityLabel("Plane preview width (mm)")
                    }
                    HStack {
                        Text("Height (mm)")
                        TextField("Height", value: $model.planePreviewHeight, format: .number.precision(.fractionLength(2)))
                            .accessibilityLabel("Plane preview height (mm)")
                    }
                }.textFieldStyle(.roundedBorder)
                if !model.validPlanePreviewSize {
                    Text("Enter positive dimensions. Showing the fitted preview until both values are valid.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Flip kept side", isOn: $model.flipPlane)
            Button("Apply Open Cut") {
                guard let normal = model.normal else { return }
                let origin = model.planeOrigin
                Task { await model.edit("cut", arguments: ["normal": [normal.x, normal.y, normal.z], "origin": [origin.x, origin.y, origin.z]]) }
            }.disabled(model.normal == nil || !model.planeOffset.isFinite)
        }
        .onChange(of: model.planeX) { _ in model.refreshOverlays() }
        .onChange(of: model.planeY) { _ in model.refreshOverlays() }
        .onChange(of: model.planeZ) { _ in model.refreshOverlays() }
        .onChange(of: model.planeOffset) { _ in model.refreshOverlays() }
        .onChange(of: model.flipPlane) { _ in model.refreshOverlays() }
        .onChange(of: model.fitPlanePreview) { _ in model.updatePlanePreviewSizing() }
        .onChange(of: model.planePreviewWidth) { _ in model.refreshOverlays() }
        .onChange(of: model.planePreviewHeight) { _ in model.refreshOverlays() }
    }
}

private struct EditorSceneView: NSViewRepresentable {
    @ObservedObject var model: MeshEditorModel
    func makeNSView(context: Context) -> EditorSCNView {
        let view = EditorSCNView()
        view.model = model
        view.scene = model.scene
        view.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        return view
    }
    func updateNSView(_ view: EditorSCNView, context: Context) {
        view.model = model
        if view.lastCameraRevision != model.cameraRevision || view.pointOfView == nil {
            view.pointOfView = model.pointOfView
            view.lastCameraRevision = model.cameraRevision
        }
        view.allowsCameraControl = model.tool != .selection && !model.busy
        view.needsDisplay = true
    }
}

private final class EditorSCNView: SCNView {
    weak var model: MeshEditorModel?
    var lastCameraRevision = -1
    private var start: CGPoint = .zero
    private var points: [CGPoint] = []
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

    override func mouseDown(with event: NSEvent) {
        guard let model, !model.busy else { return }
        start = convert(event.locationInWindow, from: nil)
        if model.tool == .selection {
            points = [start]
            return
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let model, !model.busy else { return }
        if model.tool == .selection {
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
            if points.count >= 3 && hypot(start.x-point.x, start.y-point.y) > 3 {
                // Closed lassos commonly end near their starting point; point
                // count, rather than endpoint distance, determines a region.
                model.selectPolygon(points, in: self)
            } else if points.count >= 3 {
                model.selectPolygon(points, in: self)
            } else {
                let hits = hitTest(point, options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
                if let face = hits.first?.faceIndex {
                    if model.selectedFaces.contains(face) { model.selectedFaces.remove(face) }
                    else { model.selectedFaces.insert(face) }
                    model.refreshOverlays()
                }
            }
            points.removeAll(); lasso.path = nil
            return
        }
        if model.tool == .landmarks && hypot(start.x-point.x, start.y-point.y) < 4 {
            let hits = hitTest(point, options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.closest.rawValue, .backFaceCulling: false])
            if let hit = hits.first { model.pickLandmark(hit.worldCoordinates) }
        }
        super.mouseUp(with: event)
    }
}
