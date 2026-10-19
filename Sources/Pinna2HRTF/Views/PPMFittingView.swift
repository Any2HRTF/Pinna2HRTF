import SwiftUI
import SceneKit
import AppKit

struct PPMFittingView: View {
    @StateObject private var model: PPMFittingModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let saved: (PPMFittingRequest, String) -> Void

    init(request: PPMFittingRequest, saved: @escaping (PPMFittingRequest, String) -> Void) {
        _model = StateObject(wrappedValue: PPMFittingModel(request: request))
        self.saved = saved
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    PPMFittingSceneViewport(scene: model.scene, darkMode: colorScheme == .dark)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Target ear", systemImage: "circle.fill")
                            .foregroundStyle(Color(red: 0.22, green: 0.48, blue: 0.74))
                        Label("BezierPPM", systemImage: "circle.fill")
                            .foregroundStyle(Color(red: 0.92, green: 0.34, blue: 0.16))
                        Text("Drag to rotate · Scroll to zoom")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                    if model.busy {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .background(.regularMaterial, in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
                Divider()
                controlsPanel
                    .frame(width: 390)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1050, idealWidth: 1340, minHeight: 720, idealHeight: 850)
        .interactiveDismissDisabled(model.busy || model.isUpdatingPreview)
        .task { await model.open() }
    }

    var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manual PPM Fit · \(model.request.side.title) Ear")
                    .font(.headline)
                Text("Target: \(model.request.targetMesh.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Target", isOn: $model.showTarget)
                .toggleStyle(.checkbox)
            Toggle("PPM", isOn: $model.showPPM)
                .toggleStyle(.checkbox)
            Button("Reset to Template") { Task { await model.resetControls() } }
                .disabled(model.busy || model.isUpdatingPreview)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Fit in three passes")
                    .font(.subheadline.weight(.semibold))
                Text("Edits update the PPM preview as you move a control. Fit the whole model first, then convex regions, then concave details; iterate as needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Manual fitting workflow · Perfler et al. (2025)",
                     destination: URL(string: "https://doi.org/10.1016/j.compbiomed.2025.109817")!)
                    .font(.caption)
                meshMetrics
                if model.request.side == .right {
                    Text("The right-side model is mirrored across Y; control axes follow the template.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                GroupBox("1 · Global fit") {
                    VStack(spacing: 8) {
                        ForEach(model.globalControls) { control in
                            PPMFittingParameterRow(control: control, model: model)
                        }
                    }
                    .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("2 · Convex regions")
                        .font(.subheadline.weight(.semibold))
                    ForEach(model.convexGroups, id: \.self) { group in
                        DisclosureGroup(group) {
                            VStack(spacing: 8) {
                                ForEach(model.controls.filter { $0.section == "convex" && $0.group == group }) { control in
                                    PPMFittingParameterRow(control: control, model: model)
                                }
                            }
                            .padding(.top, 7)
                        }
                        .font(.callout.weight(.medium))
                    }
                }

                GroupBox("3 · Concave details") {
                    VStack(spacing: 8) {
                        ForEach(model.concaveControls) { control in
                            PPMFittingParameterRow(control: control, model: model)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(14)
        }
        .disabled(model.busy)
    }

    private var meshMetrics: some View {
        GroupBox("Mesh distance (mm)") {
            VStack(alignment: .leading, spacing: 7) {
                Text("BezierPPM → target · nearest target vertex")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Type").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Value").frame(width: 100, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                ForEach(model.metrics) { metric in
                    HStack {
                        Text(metric.id.capitalized).frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.3f mm", metric.value))
                            .frame(width: 100, alignment: .trailing)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                if model.metrics.isEmpty {
                    Text("Calculating mesh distances…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 5)
        }
    }

    var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.busy || model.isUpdatingPreview)
            Button("Save Manual Fit") {
                Task {
                    if await model.save() {
                        saved(model.request, model.templateBlendPath)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSave)
        }
        .padding(14)
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
                Text(control.label)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                TextField(control.label, value: value, format: .number.precision(.fractionLength(2)))
                    .labelsHidden()
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
                Slider(value: value, in: control.minimum...control.maximum)
                    .accessibilityLabel("\(control.group) \(control.label)")
                Stepper(value: value, in: control.minimum...control.maximum, step: step) {
                    Text(control.label)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 48)
                .help("Adjust in \(step, specifier: "%.2g") \(control.unit.isEmpty ? "units" : control.unit) steps")
                .accessibilityLabel("Step \(control.group) \(control.label)")
            }
        }
    }
}

private struct PPMFittingSceneViewport: NSViewRepresentable {
    let scene: SCNScene
    let darkMode: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== scene { view.scene = scene }
        let camera = scene.rootNode.childNodes.first { $0.camera != nil }
        if view.pointOfView !== camera { view.pointOfView = camera }
        view.backgroundColor = darkMode ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
    }
}
