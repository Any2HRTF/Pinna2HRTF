import SwiftUI
import SceneKit
import AppKit

struct PPMFittingView: View {
    @ObservedObject var model: PPMFittingModel
    let actions: EditorWindowActions
    @State private var selectedSection = "Global"
    @State private var displayMode = "Overlay"
    @Environment(\.colorScheme) private var colorScheme

    static func present(_ request: PPMFittingRequest, store: AppStore) {
        EditorWindowController.present(
            requestID: request.id,
            title: "Manual PPM Fit",
            subtitle: "\(request.side.title) Ear – \(request.targetMesh.lastPathComponent)",
            autosaveName: "PPMFittingWindow",
            document: PPMFittingModel(request: request) { request, templateBlendPath in
                store.finishManualPPMFitting(request, templateBlendPath: templateBlendPath)
            },
            content: { model, actions in PPMFittingView(model: model, actions: actions) },
            closed: { [weak store] in
                if store?.ppmFittingRequest?.id == request.id { store?.ppmFittingRequest = nil }
            })
    }

    var body: some View {
        EditorWindowLayout(saveTitle: "Save Fit", canSave: model.canSaveDocument, isSaving: model.isSaving, actions: actions) {
            PPMFittingSceneViewport(model: model, darkMode: colorScheme == .dark)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Target ear and fitted PPM 3D preview")
                .accessibilityAddTraits(.isImage)
                .overlay(alignment: .bottomLeading) { legend.padding(12) }
                .overlay(alignment: .bottomTrailing) { NavigationHelpButton().padding(12) }
                .overlay(alignment: .topTrailing) {
                    EditorCameraControls(reset: model.resetCamera, direction: model.setCameraView).padding(12)
                }
        } inspector: {
            controlsPanel
        } status: {
            if model.busy || model.isUpdatingPreview { ProgressView().controlSize(.small) }
        }
        .task { await model.open() }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Target ear", systemImage: "circle.fill")
                .foregroundStyle(Color.gray)
            Label("PPM distance to target", systemImage: "circle.fill")
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text("0")
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.32, blue: 0.72),
                        Color(red: 0.16, green: 0.72, blue: 0.76),
                        Color(red: 0.94, green: 0.88, blue: 0.25),
                        Color(red: 0.94, green: 0.43, blue: 0.12),
                        Color(red: 0.72, green: 0.12, blue: 0.16)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 105, height: 9)
                .clipShape(Capsule())
                Text("3+ mm")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 1)
            if model.showSkeleton {
                Label("Skeleton", systemImage: "line.diagonal")
                    .foregroundStyle(.cyan)
            }
        }
        .font(.caption)
        .padding(10)
        .modifier(ViewportControlsMaterial())
    }

    private var controlsPanel: some View {
        Form {
            Section("Distance") {
                LabeledContent("Symmetric RMSE") {
                    if let metric = model.metrics.first(where: { $0.label == "Symmetric RMSE" }) {
                        Text(metric.value, format: .number.precision(.fractionLength(3))) + Text(" mm")
                    } else {
                        Text("—")
                    }
                }
                .monospacedDigit()
                .help("Nearest-vertex RMSE in both directions")
                DisclosureGroup("Details") {
                    ForEach(model.metrics) { metric in
                        LabeledContent(metric.label) {
                            Text(metric.value, format: .number.precision(.fractionLength(3))) + Text(" mm")
                        }
                        .monospacedDigit()
                    }
                }
            }
            Section("Display") {
                Picker("Show", selection: $displayMode) {
                    ForEach(["Overlay", "Target", "Error Map", "Hidden"], id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: displayMode) { mode in
                    model.showTarget = mode == "Overlay" || mode == "Target"
                    model.showPPM = mode == "Overlay" || mode == "Error Map"
                }
                LabeledContent("Target opacity") {
                    HStack {
                        Slider(value: $model.targetOpacity, in: 0...1)
                            .labelsHidden()
                            .accessibilityLabel("Target ear opacity")
                        Text(model.targetOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                .disabled(!model.showTarget)
                Toggle("Show skeleton", isOn: $model.showSkeleton)
                    .accessibilityIdentifier("ppm.showSkeleton")
            }
            Section {
                Picker("Controls", selection: $selectedSection) {
                    ForEach(["Global", "Local", "Shape Keys"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Fitting controls")
                .help("Fit Global first, then Local and Shape Keys")
                Button("Reset Adjustments") { Task { await model.resetControls() } }
                    .disabled(model.busy || model.isUpdatingPreview)
            }
            controlSections
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
    }

    @ViewBuilder private var controlSections: some View {
        switch selectedSection {
        case "Global":
            ForEach(["Location", "Rotation", "Scale"], id: \.self) { kind in
                Section(kind == "Location" ? "Position (mm)" : (kind == "Rotation" ? "Rotation (°)" : "Scale")) {
                    ForEach(model.globalControls.filter { $0.id.split(separator: "|").dropFirst(2).first == Substring(kind) }) { control in
                        PPMFittingParameterRow(control: control, model: model)
                    }
                }
            }
        case "Local":
            Section("Local Controls") {
                ForEach(model.convexGroups, id: \.self) { group in
                    DisclosureGroup(group) {
                        ForEach(model.controls.filter { $0.section == "convex" && $0.group == group }) { control in
                            PPMFittingParameterRow(control: control, model: model)
                        }
                    }
                }
            }
        default:
            Section("Shape Keys") {
                ForEach(model.concaveControls) { control in
                    PPMFittingParameterRow(control: control, model: model)
                }
            }
        }
    }
}

private struct PPMFittingParameterRow: View {
    let control: PPMFittingControl
    @ObservedObject var model: PPMFittingModel

    private var value: Binding<Double> {
        Binding(
            get: { model.controls.first(where: { $0.id == control.id })?.value ?? control.value },
            set: { model.update(control, value: $0) }
        )
    }

    private var parameterLabel: String {
        let parts = control.id.split(separator: "|")
        guard parts.count == 4 else { return control.label }
        let kind = parts[2] == "Location" ? "Position" : String(parts[2])
        return control.section == "global" ? String(parts[3]) : "\(parts[1]) · \(kind) \(parts[3])"
    }

    private var accessibilityName: String {
        let parts = control.id.split(separator: "|")
        if control.section == "global", parts.count == 4 {
            let kind = parts[2] == "Location" ? "Position" : String(parts[2])
            return "\(control.group) \(kind) \(parts[3])"
        }
        return "\(control.group) \(parameterLabel)"
    }

    private var step: Double {
        switch control.unit {
        case "mm", "°": 0.1
        default: 0.01
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(parameterLabel) {
                HStack(spacing: 4) {
                    TextField(parameterLabel, value: value, format: .number.precision(.fractionLength(2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .accessibilityLabel(accessibilityName)
                        .accessibilityIdentifier("ppm.parameter.\(control.id).value")
                    if !control.unit.isEmpty {
                        Text(control.unit)
                            .foregroundStyle(.secondary)
                    }
                    Stepper(value: value, in: control.minimum...control.maximum, step: step) {
                        Text(parameterLabel)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Adjust \(accessibilityName)")
                    .accessibilityIdentifier("ppm.parameter.\(control.id).stepper")
                }
            }
            Slider(value: value, in: control.minimum...control.maximum) { editing in
                if editing {
                    model.beginControlEditing()
                } else {
                    model.endControlEditing()
                }
            }
            .labelsHidden()
            .accessibilityLabel(accessibilityName)
            .accessibilityIdentifier("ppm.parameter.\(control.id).slider")
        }
    }
}

private struct PPMFittingSceneViewport: NSViewRepresentable {
    @ObservedObject var model: PPMFittingModel
    let darkMode: Bool

    func makeNSView(context: Context) -> PPMFittingSceneView {
        let view = PPMFittingSceneView(frame: .zero)
        view.scene = model.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        return view
    }

    func updateNSView(_ view: PPMFittingSceneView, context: Context) {
        view.backgroundColor = .viewportBackground(darkMode: darkMode)
        view.resetView = model.resetCamera
        view.update(scene: model.scene, camera: model.pointOfView, target: model.cameraTarget,
                    span: model.cameraSpan, cameraRevision: model.cameraRevision, busy: model.busy)
    }
}
