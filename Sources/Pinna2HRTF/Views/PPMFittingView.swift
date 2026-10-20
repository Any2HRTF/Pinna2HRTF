import SwiftUI
import SceneKit
import AppKit

struct PPMFittingView: View {
    @StateObject private var model: PPMFittingModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection = "Global"
    @State private var displayMode = "Overlay"
    @State private var showingHelp = false
    let saved: (PPMFittingRequest, String) -> Void

    init(request: PPMFittingRequest, saved: @escaping (PPMFittingRequest, String) -> Void) {
        _model = StateObject(wrappedValue: PPMFittingModel(request: request))
        self.saved = saved
    }

    private func closeEditor() {
        dismiss()
    }

    var body: some View {
        EditorSheetLayout {
            header
        } viewport: {
            ZStack(alignment: .topTrailing) {
                PPMFittingSceneViewport(model: model)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Target ear and fitted PPM 3D preview")
                    .accessibilityAddTraits(.isImage)
                legend.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                EditorCameraControls(fit: model.resetCamera, direction: model.setCameraView).padding(12)
                if model.busy {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } inspector: {
            controlsPanel
        } footer: {
            footer
        }
        .interactiveDismissDisabled(model.busy || model.isUpdatingPreview)
        .task { await model.open() }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Target ear", systemImage: "circle.fill")
                .foregroundStyle(Color.gray)
            Label("PPM · distance error", systemImage: "circle.fill")
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
                Label("Blender skeleton", systemImage: "line.diagonal")
                    .foregroundStyle(.cyan)
            }
            Text("Drag to rotate · Scroll to zoom")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manual PPM Fit · \(model.request.side.title) Ear").font(.headline)
                Text("\(model.request.targetMesh.lastPathComponent) · Original mesh is preserved")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    private var fittingActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Display", selection: $displayMode) {
                ForEach(["Overlay", "Target", "Error Map", "Hidden"], id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            .onChange(of: displayMode) { mode in
                model.showTarget = mode == "Overlay" || mode == "Target"
                model.showPPM = mode == "Overlay" || mode == "Error Map"
            }
            Toggle("Show Blender skeleton", isOn: $model.showSkeleton)
                .accessibilityIdentifier("ppm.showSkeleton")
                .help("Overlay the posed Blender bones, including curved Bendy bones, through the PPM surface.")
            Menu {
                Button("Reset to Template") { Task { await model.resetControls() } }
                    .disabled(model.busy || model.isUpdatingPreview)
            } label: { Text("Fitting actions") }
            .accessibilityLabel("Fitting actions")
            .fixedSize()
            .help("Fitting actions")
            Button("Help", systemImage: "questionmark.circle") { showingHelp.toggle() }
                .labelStyle(.iconOnly)
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Manual Fitting").font(.headline)
                        Text("Fit the whole model first, then local bone controls, then shape keys. Changes update the preview automatically.")
                        Text("For a right ear, the model is mirrored across Y; control axes follow the template.")
                        Link("Fitting workflow · Perfler et al. (2025)", destination: URL(string: "https://doi.org/10.1016/j.compbiomed.2025.109817")!)
                    }.padding().frame(width: 320)
                }
        }
    }

    private var historyControls: some View {
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo || model.busy)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .disabled(!model.canRedo || model.busy)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    var controlsPanel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                historyControls
                meshMetrics
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                fittingActions
                Picker("Fitting section", selection: $selectedSection) {
                    ForEach(["Global", "Local", "Shape Keys"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                targetOpacityControl.disabled(!model.showTarget)
                Divider()
                // Plain headings preserve Computer access; GroupBox crashes the helper here.
                if selectedSection == "Global" {
                    ForEach(["Location", "Rotation", "Scale"], id: \.self) { kind in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(kind == "Location" ? "Position (mm)" : (kind == "Rotation" ? "Rotation (°)" : "Scale"))
                                .font(.caption.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            VStack(spacing: 8) {
                                ForEach(model.globalControls.filter { $0.id.split(separator: "|").dropFirst(2).first == Substring(kind) }) { control in
                                    PPMFittingParameterRow(control: control, model: model)
                                }
                            }.padding(.top, 6)
                        }
                    }
                } else if selectedSection == "Local" {
                    ForEach(model.convexGroups, id: \.self) { group in
                        DisclosureGroup(group) {
                            VStack(spacing: 8) {
                                ForEach(model.controls.filter { $0.section == "convex" && $0.group == group }) { control in
                                    PPMFittingParameterRow(control: control, model: model)
                                }
                            }.padding(.top, 7)
                        }
                    }
                } else {
                    ForEach(model.concaveControls) { control in
                        PPMFittingParameterRow(control: control, model: model)
                    }
                }

                Divider()
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                }.padding(16)
            }
        }.disabled(model.busy)
    }

    private var targetOpacityControl: some View {
        HStack(spacing: 8) {
            Label("Target opacity", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.medium))
                .frame(width: 112, alignment: .leading)
            Slider(value: $model.targetOpacity, in: 0...1)
                .accessibilityLabel("Target ear opacity")
            Text(model.targetOpacity, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .help("Fade the target ear to reveal the fitted PPM and its distance colors underneath.")
    }

    private var meshMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let metric = model.metrics.first(where: { $0.label == "Symmetric RMSE" }) {
                HStack {
                    Text("Symmetric RMSE").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.3f mm", metric.value)).monospacedDigit()
                }
            } else {
                Text("Calculating mesh distances…").foregroundStyle(.secondary)
            }
            DisclosureGroup("Distance Details") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Nearest-vertex RMSE both ways; summary statistics use PPM → target.")
                        .foregroundStyle(.secondary)
                    ForEach(model.metrics) { metric in
                        HStack {
                            Text(metric.label)
                            Spacer()
                            Text(String(format: "%.3f mm", metric.value)).monospacedDigit()
                        }
                    }
                }.font(.caption).padding(.top, 6)
            }
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            Text("Review shape and mesh distances before saving.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { closeEditor() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.busy || model.isUpdatingPreview)
            Button("Save Manual Fit") {
                Task {
                    if await model.save() {
                        saved(model.request, model.templateBlendPath)
                        closeEditor()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
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
        case "×": 0.01
        default: 0.01
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(parameterLabel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                TextField(parameterLabel, value: value, format: .number.precision(.fractionLength(2)))
                    .labelsHidden()
                    .accessibilityLabel(accessibilityName)
                    .accessibilityIdentifier("ppm.parameter.\(control.id).value")
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 78)
                if !control.unit.isEmpty {
                    Text(control.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                Slider(value: value, in: control.minimum...control.maximum) { editing in
                    if editing {
                        model.beginControlEditing()
                    } else {
                        model.endControlEditing()
                    }
                }
                    .accessibilityLabel(accessibilityName)
                    .accessibilityIdentifier("ppm.parameter.\(control.id).slider")
                Stepper(value: value, in: control.minimum...control.maximum, step: step) {
                    Text(parameterLabel)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 48)
                .help("Adjust in \(step, specifier: "%.2g") \(control.unit.isEmpty ? "units" : control.unit) steps")
                .accessibilityLabel("Adjust \(accessibilityName)")
                .accessibilityIdentifier("ppm.parameter.\(control.id).stepper")
            }
        }
    }
}

private struct PPMFittingSceneViewport: NSViewRepresentable {
    @ObservedObject var model: PPMFittingModel

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NavigableSCNView {
        let view = NavigableSCNView(frame: .zero)
        view.scene = model.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        return view
    }

    func updateNSView(_ view: NavigableSCNView, context: Context) {
        if view.scene !== model.scene { view.scene = model.scene }
        if view.pointOfView !== model.pointOfView || context.coordinator.cameraRevision != model.cameraRevision {
            view.configureNavigation(camera: model.pointOfView, target: model.cameraTarget, span: model.cameraSpan)
            context.coordinator.cameraRevision = model.cameraRevision
        }
        view.allowsCameraControl = !model.busy
        view.needsDisplay = true
    }

    final class Coordinator {
        var cameraRevision = -1
    }
}
