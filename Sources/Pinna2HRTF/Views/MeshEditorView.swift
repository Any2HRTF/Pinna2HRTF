import SwiftUI
import SceneKit
import AppKit

struct MeshEditorView: View {
    @ObservedObject var model: MeshEditorModel
    let actions: EditorWindowActions
    @Environment(\.colorScheme) private var colorScheme

    static func present(_ request: MeshEditorRequest, store: AppStore) {
        EditorWindowController.present(
            requestID: request.id,
            title: request.title,
            subtitle: request.source.lastPathComponent,
            autosaveName: "MeshEditorWindow",
            document: MeshEditorModel(request: request, saved: store.finishMeshEditing),
            content: { model, actions in
                MeshEditorView(model: model, actions: actions)
                    .onChange(of: model.canSave) { value in
                        if request.isAlignment, store.meshEditorRequest?.id == request.id { store.alignmentCanSave = value }
                    }
            },
            closed: { [weak store] in
                if store?.meshEditorRequest?.id == request.id {
                    store?.meshEditorRequest = nil
                    if request.isAlignment { store?.alignmentCanSave = false }
                }
            })
    }

    var body: some View {
        EditorWindowLayout(saveTitle: model.request.isAlignment ? "Save Alignment" : "Save Ear",
                           canSave: model.canSave, isSaving: model.isSaving, actions: actions) {
            EditorSceneView(model: model, darkMode: colorScheme == .dark)
                .overlay(alignment: .bottomTrailing) { NavigationHelpButton().padding(12) }
                .overlay(alignment: .topTrailing) {
                    EditorCameraControls(reset: model.resetCamera, direction: model.setCameraView)
                        .padding(12)
                }
        } inspector: {
            Form {
                if model.request.isAlignment {
                    alignmentSection
                } else {
                    Section {
                        Picker("Tool", selection: $model.tool) {
                            ForEach(model.tools) { tool in Text(tool.rawValue).tag(tool) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: model.tool) { _ in model.refreshOverlays() }
                    }
                    if model.tool == .selection { selectionSection }
                    if model.tool == .plane { planeSection }
                    Section("Cleanup") {
                        Button("Keep Largest Component") {
                            Task { await model.edit("largest", actionName: "Keep Largest Component") }
                        }
                        .help("Remove loose fragments")
                    }
                }
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)
        } status: {
            if model.busy { ProgressView().controlSize(.small) }
            if model.faceCount > 0 {
                Text("\(model.faceCount.formatted()) faces")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.open() }
    }

    private var alignmentSection: some View {
        Section("Landmarks") {
            ForEach(Array(["Nose tip", "Left ear-canal entrance", "Right ear-canal entrance"].enumerated()), id: \.offset) { index, name in
                let placed = model.hasAlignment || index < model.landmarks.count
                let current = !model.hasAlignment && model.landmarkSlot == index
                Button {
                    model.landmarkSlot = min(index, model.landmarks.count)
                } label: {
                    HStack {
                        Image(systemName: placed ? "checkmark.circle.fill" : (current ? "smallcircle.filled.circle" : "circle"))
                            .foregroundStyle([Color.red, .blue, .green][index])
                        Text(name)
                        Spacer()
                        Text(placed ? "Placed" : (current ? "Next" : ""))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index > model.landmarks.count || model.hasAlignment)
            }
            Toggle("Show axes", isOn: $model.showCoordinateSystem)
                .help("Origin at the midpoint between the ear canals; X forward, Y left, Z up")
            Button("Restart Picks") { Task { await model.restartLandmarks() } }
                .disabled(model.landmarks.isEmpty && !model.hasAlignment)
        }
    }

    private var selectionSection: some View {
        Section("Selection") {
            LabeledContent("Selected faces") {
                Text(model.selectedFaces.count.formatted()).monospacedDigit()
            }
            .help("Drag to select faces. Shift-drag to add to the selection. Click a face to select or deselect it.")
            Toggle("Select through mesh", isOn: $model.throughSelection)
            HStack {
                Button("Invert Selection") { model.invertSelection() }
                    .disabled(model.faces.isEmpty)
                Button("Clear Selection") { model.selectedFaces.removeAll(); model.refreshOverlays() }
                    .disabled(model.selectedFaces.isEmpty)
            }
            Button(role: .destructive) {
                Task { await model.edit("delete", actionName: "Delete Faces", arguments: ["faces": model.selectedFaces.sorted()]) }
            } label: {
                Label("Delete Selected Faces", systemImage: "trash")
                    .foregroundStyle(model.selectedFaces.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
            }
            .disabled(model.selectedFaces.isEmpty)
        }
    }

    private var planeSection: some View {
        Section("Cutting Plane") {
            LabeledContent("Normal") {
                HStack(spacing: 6) {
                    TextField("X", value: $model.planeNormalX, format: .number.grouping(.never).locale(.posix)).accessibilityLabel("Plane normal X")
                    TextField("Y", value: $model.planeNormalY, format: .number.grouping(.never).locale(.posix)).accessibilityLabel("Plane normal Y")
                    TextField("Z", value: $model.planeNormalZ, format: .number.grouping(.never).locale(.posix)).accessibilityLabel("Plane normal Z")
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 180)
            }
            LabeledContent("Align to axis") {
                HStack(spacing: 6) {
                    ForEach(["X", "Y", "Z"], id: \.self) { axis in
                        Button(axis) {
                            model.planeNormalX = axis == "X" ? 1 : 0
                            model.planeNormalY = axis == "Y" ? 1 : 0
                            model.planeNormalZ = axis == "Z" ? 1 : 0
                        }
                        .accessibilityLabel("Align plane normal to \(axis)")
                    }
                }
            }
            LabeledContent("Offset (mm)") {
                TextField("Offset (mm)", value: $model.planeOffset, format: .number.precision(.fractionLength(2)).grouping(.never).locale(.posix))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            Slider(value: $model.planeOffset, in: -model.span/2...model.span/2)
                .labelsHidden()
                .accessibilityLabel("Cutting plane offset")
            Toggle("Fit preview to mesh", isOn: $model.fitPlanePreview)
            if !model.fitPlanePreview {
                LabeledContent("Preview width (mm)") {
                    TextField("Preview width (mm)", value: $model.planePreviewWidth, format: .number.precision(.fractionLength(2)).grouping(.never).locale(.posix))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                LabeledContent("Preview height (mm)") {
                    TextField("Preview height (mm)", value: $model.planePreviewHeight, format: .number.precision(.fractionLength(2)).grouping(.never).locale(.posix))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
            Toggle("Flip kept side", isOn: $model.flipPlane)
            Button("Apply Cut") {
                guard let normal = model.normal else { return }
                let origin = model.planeOrigin
                Task {
                    await model.edit("cut", actionName: "Cut", arguments: ["normal": [normal.x, normal.y, normal.z],
                                                                         "origin": [origin.x, origin.y, origin.z]])
                }
            }
            .help("Removes the faces on the red side")
            .disabled(model.normal == nil || !model.planeOffset.isFinite)
        }
        .onChange(of: model.planeNormalX) { _ in model.refreshOverlays() }
        .onChange(of: model.planeNormalY) { _ in model.refreshOverlays() }
        .onChange(of: model.planeNormalZ) { _ in model.refreshOverlays() }
        .onChange(of: model.planeOffset) { _ in model.refreshOverlays() }
        .onChange(of: model.flipPlane) { _ in model.refreshOverlays() }
        .onChange(of: model.fitPlanePreview) { _ in model.updatePlanePreviewSizing() }
        .onChange(of: model.planePreviewWidth) { _ in model.refreshOverlays() }
        .onChange(of: model.planePreviewHeight) { _ in model.refreshOverlays() }
    }
}

private struct EditorSceneView: NSViewRepresentable {
    @ObservedObject var model: MeshEditorModel
    let darkMode: Bool

    func makeNSView(context: Context) -> EditorSCNView {
        let view = EditorSCNView()
        view.model = model
        view.scene = model.scene
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateNSView(_ view: EditorSCNView, context: Context) {
        view.model = model
        view.backgroundColor = .viewportBackground(darkMode: darkMode)
        view.resetView = model.resetCamera
        view.showsCoordinateSystem = model.request.isAlignment && model.showCoordinateSystem
        if view.lastCameraRevision != model.cameraRevision || view.pointOfView == nil {
            view.configureNavigation(camera: model.pointOfView, target: SCNVector3(model.center), span: model.span)
            view.lastCameraRevision = model.cameraRevision
        }
        view.allowsCameraControl = !model.busy
        view.needsDisplay = true
    }
}
