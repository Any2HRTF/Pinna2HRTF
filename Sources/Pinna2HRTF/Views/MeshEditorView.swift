import SwiftUI
import SceneKit
import AppKit

struct MeshEditorView: View {
    @StateObject private var model: MeshEditorModel
    @Environment(\.dismiss) private var dismiss
    let saved: (MeshEditorRequest) -> Void

    init(request: MeshEditorRequest, saved: @escaping (MeshEditorRequest) -> Void) {
        _model = StateObject(wrappedValue: MeshEditorModel(request: request))
        self.saved = saved
    }

    private func closeEditor() {
        if model.canUndo || !model.landmarks.isEmpty || !model.selectedFaces.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved mesh changes?"
            alert.addButton(withTitle: "Keep editing")
            alert.addButton(withTitle: "Discard")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        dismiss()
    }

    var body: some View {
        EditorSheetLayout {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.request.title).font(.headline)
                    Text(model.request.source.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
        } viewport: {
            EditorSceneView(model: model)
                .overlay(alignment: .bottomTrailing) { NavigationHelpButton().padding(12) }
                .overlay(alignment: .topTrailing) {
                    EditorCameraControls(fit: model.resetCamera, direction: model.setCameraView)
                        .padding(12)
                }
        } inspector: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.request.isAlignment {
                        alignmentControls
                    } else {
                        EditorInspectorSection("Tool", systemImage: "wrench.and.screwdriver") {
                            Picker("Tool", selection: $model.tool) {
                                ForEach(model.tools) { tool in Text(tool.rawValue).tag(tool) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: model.tool) { _ in model.refreshOverlays() }
                        }
                        if model.tool == .landmarks { alignmentControls }
                        if model.tool == .selection { selectionControls }
                        if model.tool == .plane { planeControls }
                        EditorInspectorSection("Cleanup", systemImage: "sparkles") {
                            Button { Task { await model.edit("largest") } } label: {
                                Label("Keep Largest Component", systemImage: "square.3.layers.3d.down.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .help("Remove loose fragments.")
                        }
                    }
                    EditorInspectorSection("History", systemImage: "clock.arrow.circlepath") {
                        HStack {
                            Button { Task { await model.moveHistory(-1) } } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                            }
                            .disabled(!model.canUndo)
                            Button { Task { await model.moveHistory(1) } } label: {
                                Label("Redo", systemImage: "arrow.uturn.forward").frame(maxWidth: .infinity)
                            }
                            .disabled(!model.canRedo)
                        }
                        .buttonStyle(.bordered)
                    }
                    if !model.message.isEmpty || model.error != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if !model.message.isEmpty {
                                Text(model.message).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = model.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(16)
            }
            .disabled(model.busy)
        } footer: {
            HStack {
                Text(model.request.isAlignment ? "Preview the alignment, then save." : "The original mesh is kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { closeEditor() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(model.request.isAlignment ? "Save Aligned Scan" : "Save Ear") {
                    Task {
                        if await model.save() { saved(model.request); dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!model.canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(true)
        .task { await model.open() }
    }

    var alignmentControls: some View {
        EditorInspectorSection("Nose and Ear Landmarks", systemImage: "mappin.and.ellipse") {
            Toggle("Show coordinate system", isOn: $model.showCoordinateSystem)
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
            Text("Origin: midpoint between the ear canals. X forward, Y left, Z up.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                let points = model.landmarks.map { [Double($0.x), Double($0.y), Double($0.z)] }
                Task { await model.edit("align", arguments: ["points": points]) }
            } label: {
                Label("Preview Alignment", systemImage: "move.3d").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.landmarks.count != 3)
        }
    }

    var selectionControls: some View {
        EditorInspectorSection("Select Faces", systemImage: "lasso") {
            Text("Drag to select, click to toggle a face.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Select through mesh", isOn: $model.throughSelection)
                .help("Also select hidden and back-facing faces.")
            Toggle("Add to current selection", isOn: $model.addToSelection)
            HStack {
                Text("\(model.selectedFaces.count) faces selected").font(.caption.monospacedDigit())
                    .foregroundStyle(model.selectedFaces.isEmpty ? Color.secondary : Color.red)
                Spacer()
                Button("Invert") { model.invertSelection() }
                    .disabled(model.faces.isEmpty)
                    .help("Invert selection")
                Button("Clear") { model.selectedFaces.removeAll(); model.refreshOverlays() }
                    .disabled(model.selectedFaces.isEmpty)
                    .help("Clear selection")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(role: .destructive) {
                Task { await model.edit("delete", arguments: ["faces": model.selectedFaces.sorted()]) }
            } label: {
                Label("Delete Selected Faces", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.selectedFaces.isEmpty)
        }
    }

    var planeControls: some View {
        EditorInspectorSection("Cutting Plane", systemImage: "scissors") {
            Text("The red side is removed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Align normal to")
                Spacer()
                ForEach(["X", "Y", "Z"], id: \.self) { axis in
                    Button(axis) {
                        model.planeX = axis == "X" ? "1" : "0"
                        model.planeY = axis == "Y" ? "1" : "0"
                        model.planeZ = axis == "Z" ? "1" : "0"
                        model.refreshOverlays()
                    }
                    .accessibilityLabel("Set cutting plane normal to \(axis)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                    .accessibilityLabel("Cutting plane offset (mm)")
                    .textFieldStyle(.roundedBorder)
            }
            Slider(value: $model.planeOffset, in: -model.span/2...model.span/2)
                .accessibilityLabel("Cutting plane offset")
            Toggle("Fit plane preview to mesh", isOn: $model.fitPlanePreview)
                .help("Turn off to set the preview size by hand.")
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
                    Text("Enter values above zero.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Flip kept side", isOn: $model.flipPlane)
            Button {
                guard let normal = model.normal else { return }
                let origin = model.planeOrigin
                Task { await model.edit("cut", arguments: ["normal": [normal.x, normal.y, normal.z], "origin": [origin.x, origin.y, origin.z]]) }
            } label: {
                Label("Apply Cut", systemImage: "scissors").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(model.normal == nil || !model.planeOffset.isFinite)
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

private struct EditorInspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
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
        view.showsCoordinateSystem = model.request.isAlignment && model.showCoordinateSystem
        if view.lastCameraRevision != model.cameraRevision || view.pointOfView == nil {
            view.configureNavigation(camera: model.pointOfView, target: SCNVector3(model.center), span: model.span)
            view.lastCameraRevision = model.cameraRevision
        }
        view.allowsCameraControl = !model.busy
        view.needsDisplay = true
    }
}
