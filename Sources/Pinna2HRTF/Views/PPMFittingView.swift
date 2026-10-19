import SwiftUI
import SceneKit
import AppKit

struct PPMFittingView: View {
    @StateObject private var model: PPMFittingModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection = "Global"
    @State private var displayMode = "Overlay"
    @State private var showingHelp = false
    var closeWindow: (() -> Void)?
    var busyChanged: (Bool) -> Void = { _ in }
    let saved: (PPMFittingRequest, String) -> Void

    init(request: PPMFittingRequest, closeWindow: (() -> Void)? = nil, busyChanged: @escaping (Bool) -> Void = { _ in }, saved: @escaping (PPMFittingRequest, String) -> Void) {
        _model = StateObject(wrappedValue: PPMFittingModel(request: request))
        self.closeWindow = closeWindow
        self.busyChanged = busyChanged
        self.saved = saved
    }

    private func closeEditor() {
        if let closeWindow { closeWindow() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ZStack(alignment: .topLeading) {
                    PPMFittingSceneViewport(scene: model.scene, darkMode: colorScheme == .dark)
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
                .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                controlsPanel
                    .frame(minWidth: 320, idealWidth: 390, maxWidth: 500)
            }
            Divider()
            footer
        }
        .frame(minWidth: 800, idealWidth: 1200, minHeight: 600, idealHeight: 800)
        .interactiveDismissDisabled(model.busy || model.isUpdatingPreview)
        .onChange(of: model.busy || model.isUpdatingPreview) { busyChanged($0) }
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
            Picker("Display", selection: $displayMode) {
                ForEach(["Overlay", "Target", "Error Map", "Hidden"], id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            .onChange(of: displayMode) { mode in
                model.showTarget = mode == "Overlay" || mode == "Target"
                model.showPPM = mode == "Overlay" || mode == "Error Map"
            }
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo || model.busy)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .disabled(!model.canRedo || model.busy)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Menu {
                Button("Reset to Template") { Task { await model.resetControls() } }
                    .disabled(model.busy || model.isUpdatingPreview)
            } label: { Image(systemName: "ellipsis.circle") }
            .fixedSize()
            .help("Fitting actions")
            Button("Help", systemImage: "questionmark.circle") { showingHelp.toggle() }
                .labelStyle(.iconOnly)
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Manual Fitting").font(.headline)
                        Text("Fit the whole model first, then convex regions, then concave details. Changes update the preview automatically.")
                        Text("For a right ear, the model is mirrored across Y; control axes follow the template.")
                        Link("Fitting workflow · Perfler et al. (2025)", destination: URL(string: "https://doi.org/10.1016/j.compbiomed.2025.109817")!)
                    }.padding().frame(width: 320)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var controlsPanel: some View {
        VStack(spacing: 0) {
            meshMetrics
                .padding(14)
            Divider()
            Picker("Fitting section", selection: $selectedSection) {
                ForEach(["Global", "Convex", "Concave"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ppmOpacityControl.disabled(!model.showPPM)
                    Divider()
                    if selectedSection == "Global" {
                        ForEach(["Location", "Rotation", "Scale"], id: \.self) { kind in
                            GroupBox(kind == "Location" ? "Position (mm)" : (kind == "Rotation" ? "Rotation (°)" : "Scale")) {
                                VStack(spacing: 8) {
                                    ForEach(model.globalControls.filter { $0.id.split(separator: "|").dropFirst(2).first == Substring(kind) }) { control in
                                        PPMFittingParameterRow(control: control, model: model)
                                    }
                                }.padding(.top, 6)
                            }
                        }
                    } else if selectedSection == "Convex" {
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
                }.padding(14)
            }
            .disabled(model.busy)
        }
    }

    private var ppmOpacityControl: some View {
        HStack(spacing: 8) {
            Label("PPM opacity", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.medium))
                .frame(width: 112, alignment: .leading)
            Slider(value: $model.ppmOpacity, in: 0.15...1)
                .accessibilityLabel("Fitted PPM opacity")
            Text(model.ppmOpacity, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .help("Lower the PPM opacity to compare the distance colors with the target through the overlay.")
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

    private var parameterLabel: String {
        let parts = control.id.split(separator: "|")
        guard parts.count == 4 else { return control.label }
        let kind = parts[2] == "Location" ? "Position" : String(parts[2])
        return control.section == "global" ? String(parts[3]) : "\(parts[1]) · \(kind) \(parts[3])"
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
                    .accessibilityLabel("\(control.group) \(parameterLabel)")
                Stepper(value: value, in: control.minimum...control.maximum, step: step) {
                    Text(parameterLabel)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 48)
                .help("Adjust in \(step, specifier: "%.2g") \(control.unit.isEmpty ? "units" : control.unit) steps")
                .accessibilityLabel("Step \(control.group) \(parameterLabel)")
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
