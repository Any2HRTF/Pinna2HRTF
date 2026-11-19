import SwiftUI
import AppKit

struct ProjectInspectorView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Group {
            if store.selectedProject == nil {
                NoProjectSelectedView()
            } else {
                VStack(spacing: 0) {
                    stepList
                    Divider()
                    Form { stageContent }
                        .formStyle(.grouped)
                        .disabled(store.selectedProjectIsRunning)
                        .safeAreaInset(edge: .bottom, spacing: 0) { WorkflowFooter(store: store) }
                        .modifier(FooterScrollEdge())
                }
            }
        }
        .onChange(of: store.earDistanceFocusRequest) { _ in store.workflowStep = .simulation }
    }

    private var stepList: some View {
        List(selection: Binding<WorkflowStep?>(get: { store.workflowStep }, set: { if let step = $0 { store.workflowStep = step } })) {
            ForEach(WorkflowStep.allCases) { step in
                let status = store.workflowStatus(step)
                HStack(spacing: 6) {
                    Label {
                        Text(step.title).lineLimit(1)
                    } icon: {
                        Image(systemName: store.workflowSymbol(for: status)).foregroundStyle(statusColor(status))
                    }
                    Spacer(minLength: 4)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .tag(step)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(WorkflowStep.allCases.count) * 26 + 12)
        .accessibilityLabel("Workflow")
    }

    private func statusColor(_ status: String) -> Color {
        if status == "Complete" { return .green }
        if status == "Failed" { return .red }
        if status == "Stopped" || status.hasPrefix("Needs") || status == "Choose method" { return .orange }
        if status == "Ready" || status.hasPrefix("Running") { return .accentColor }
        return .secondary
    }

    @ViewBuilder var stageContent: some View {
        switch store.workflowStep {
        case .inputs: projectSections
        case .prepare: prepareSections
        case .simulation: simulationSections
        case .calculate: calculationSections
        case .results: exportSections
        }
    }

    @ViewBuilder var projectSections: some View {
        Section {
            LabeledTextField("Project name", helpID: "project.name", text: projectStringBinding(\.name))
            PathField("Save location", helpID: "project.save_location", text: projectStringBinding(\.saveLocation), mode: .directory)
        }
        Section {
            Picker("Input", selection: scanBoolBinding(\.enabled)) {
                Text("Full-head scan").tag(true)
                Text("Ear meshes").tag(false)
            }
            .pickerStyle(.radioGroup)
            if store.selectedProject?.scanPreparation.enabled == true {
                PathField("Head scan", helpID: "scan.path", text: Binding(get: { store.selectedProject?.scanPreparation.scanPath ?? "" }, set: { store.setHeadScan($0) }), mode: .file)
            } else {
                PathField("Left ear", helpID: "project.left_ear", text: projectStringBinding(\.leftEar), mode: .file)
                PathField("Right ear", helpID: "project.right_ear", text: projectStringBinding(\.rightEar), mode: .file)
            }
        }
    }

    @ViewBuilder var prepareSections: some View {
        if store.selectedProject?.scanPreparation.enabled == true {
            Section("Head Scan") {
                LabeledContent("Alignment") {
                    Button("Align Scan…") { store.beginScanAlignment() }
                }
                LabeledContent("Prepare") {
                    HStack(spacing: 12) {
                        Toggle("Left", isOn: scanBoolBinding(\.prepareLeft))
                            .accessibilityLabel("Prepare left ear")
                        Toggle("Right", isOn: scanBoolBinding(\.prepareRight))
                            .accessibilityLabel("Prepare right ear")
                    }
                    .toggleStyle(.checkbox)
                }
                DisclosureGroup("Advanced") {
                    Toggle("Review ears before continuing", isOn: Binding(
                        get: { store.selectedProject?.scanPreparation.requireManualReview ?? false },
                        set: { value in store.updateSelectedProject { project in
                            var scan = project.scanPreparation
                            scan.requireManualReview = value
                            project.settings.scanPreparation = scan
                        } }
                    ))
                    LabeledTextField("Target edge (mm)", helpID: "scan.target_edge", text: scanTextBinding(\.targetEdgeMM))
                    LabeledTextField("Left crop margin (mm)", helpID: "scan.left_margin", text: scanTextBinding(\.leftMarginMM))
                    LabeledTextField("Right crop margin (mm)", helpID: "scan.right_margin", text: scanTextBinding(\.rightMarginMM))
                    LabeledTextField("Inner crop limit (mm)", helpID: "scan.side_min", text: scanTextBinding(\.sideMinMM))
                    LabeledTextField("Outer crop limit (mm)", helpID: "scan.side_max", text: scanTextBinding(\.sideMaxMM))
                }
            }
        }
        Section("Ears") {
            ForEach(store.workflowSides) { side in
                earRow(side)
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ear model")
                ForEach(EarModelMethod.allCases) { method in
                    HStack(spacing: 4) {
                        EarModelRadioButton(title: method.title, isSelected: store.earModelMethod == method) {
                            store.selectEarModelMethod(method)
                        }
                        SettingHelpButton(helpID: "ear_model.\(method.rawValue)")
                    }
                }
            }
            if store.earModelMethod == nil {
                FieldWarning("Choose one method")
            }
            switch store.earModelMethod {
            case .manual: manualPPMRows
            case .mesh2ppm: ModelPicker(selection: modelNameBinding, options: store.modelOptions, helpID: "inference.model")
            default: EmptyView()
            }
        }
    }

    private func earRow(_ side: EarSide) -> some View {
        let fittable = store.selectedProjectStatus?.fittableSides.contains(side) ?? false
        let hasEdit = store.selectedProject?.scanPreparation.earEdit(side) != nil
        let editOutdated = hasEdit && store.selectedProjectStatus.map { !$0.currentEarEdits.contains(side) } == true
        return LabeledContent {
            HStack(spacing: 6) {
                Button("Inspect") {
                    if let project = store.selectedProject, let url = ArtifactScanner.sourceEar(for: project, side: side) {
                        store.openArtifact(Artifact(title: "\(side.title) ear", url: url))
                    }
                }
                .disabled(!fittable)
                Button("Edit…") { store.beginEarEditing(side) }
                    .disabled(!fittable)
                if hasEdit {
                    Button("Use Original") {
                        store.updateSelectedProject {
                            var scan = $0.scanPreparation
                            scan.setEarEdit(nil, side: side)
                            $0.settings.scanPreparation = scan
                        }
                    }
                    .help("Discard the saved edit for the \(side.rawValue) ear")
                }
            }
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(side.title) ear")
                if editOutdated { FieldWarning("Edit outdated") }
            }
        }
    }

    @ViewBuilder var manualPPMRows: some View {
        ForEach(store.workflowSides) { side in
            LabeledContent {
                HStack(spacing: 8) {
                    Text(manualPPMStatus(for: side))
                        .foregroundStyle(.secondary)
                    Button("Fit…") { store.beginManualPPMFitting(side) }
                        .disabled(!canFitManually(side))
                }
            } label: {
                Text("\(side.title) fit")
            }
        }
        if let issue = store.selectedValidationIssues.first(where: { $0.id.hasPrefix("manual_ppm") }) {
            FieldWarning(issue.message)
        }
    }

    @ViewBuilder var simulationSections: some View {
        Section("Head") {
            HeadGeometryControls(store: store)
        }
        Section("Microphones") {
            LabeledContent("Position") {
                HStack(spacing: 6) {
                    ForEach(store.workflowSides) { side in
                        Button("Adjust \(side.title)…") { store.beginMicrophonePlacement(side) }
                            .accessibilityLabel("Adjust \(side.title) Microphone")
                            .disabled(!(store.selectedProjectStatus?.pipelineSides.contains(side) ?? false))
                    }
                }
                .fixedSize()
            }
            numberRow("Microphone faces", helpID: "mesh2hrtf.microphone_faces", value: sourceAssignmentFaceCountBinding, range: 1...100)
        }
        Section("Frequencies") {
            PathField("Evaluation grid", helpID: "mesh2hrtf.evaluation_grid", text: optionalPreprocessingBinding(\.evaluationGrid), mode: .directory,
                      defaultName: Defaults.evaluationGrid)
            LabeledTextField("Min frequency (Hz)", helpID: "mesh2hrtf.min_frequency", text: preprocessingBinding(\.minFrequency))
            LabeledTextField("Max frequency (Hz)", helpID: "mesh2hrtf.max_frequency", text: preprocessingBinding(\.maxFrequency), validationError: validationMessage("mesh2hrtf.max_frequency"))
            numberRow("Frequency steps", helpID: "mesh2hrtf.frequency_steps", value: frequencyStepCountBinding, range: 2...10000)
        }
        Section {
            DisclosureGroup("Mesh Grading") {
                LabeledTextField("Min edge length (mm)", helpID: "mesh_grading.min_edge_length", text: preprocessingBinding(\.meshMinEdgeLength))
                LabeledTextField("Max edge length (mm)", helpID: "mesh_grading.max_edge_length", text: preprocessingBinding(\.meshMaxEdgeLength), validationError: validationMessage("mesh_grading.max_edge_length"))
                LabeledTextField("Max error (mm)", helpID: "mesh_grading.max_error", text: preprocessingBinding(\.meshMaxError))
                LabeledTextField("Gamma", helpID: "mesh_grading.gamma", text: preprocessingBinding(\.meshGamma))
                LabeledTextField("Gamma opposite", helpID: "mesh_grading.gamma_opposite", text: preprocessingBinding(\.meshGammaOpposite))
            }
        }
    }

    @ViewBuilder var calculationSections: some View {
        Section {
            LabeledContent("Progress") {
                Text(numcalcProgress).monospacedDigit()
            }
        }
        Section {
            LabeledTextField("Parallel instances", helpID: "numcalc.parallel_instances", text: numcalcBinding(\.maxInstances))
            LabeledTextField("CPU limit (%)", helpID: "numcalc.cpu_limit", text: numcalcBinding(\.maxCPULoad))
            SettingToggle(title: "Adaptive FMM expansion", helpID: "numcalc.adaptive_fmm", isOn: numcalcBoolBinding(\.adaptiveFmmLength))
        }
    }

    @ViewBuilder var exportSections: some View {
        Section {
            SettingToggle(title: "Apply level offset", helpID: "postprocessing.normalize", isOn: postprocessingValue(\.normalize))
            if postprocessingValue(\.normalize).wrappedValue {
                LabeledTextField("Level offset (dB)", helpID: "postprocessing.level_offset", text: postprocessingValue(\.levelOffsetDB))
            }
            SettingToggle(title: "Resample HRIRs", helpID: "postprocessing.resample_hrirs", isOn: postprocessingValue(\.resampleHrirs))
            if postprocessingValue(\.resampleHrirs).wrappedValue {
                LabeledTextField("Sampling rate (Hz)", helpID: "postprocessing.sampling_rate", text: postprocessingValue(\.samplingRate))
            }
        }
        Section {
            SettingToggle(title: "Spatial upsampling", helpID: "postprocessing.spatial_upsampling", isOn: postprocessingValue(\.spatialUpsampling))
            if postprocessingValue(\.spatialUpsampling).wrappedValue {
                numberRow("Subdivision level", helpID: "postprocessing.spatial_subdivisions", value: postprocessingValue(\.spatialSubdivisions), range: 0...5)
                SettingToggle(title: "Normalize to frontal reference", helpID: "postprocessing.spatial_normalize", isOn: postprocessingValue(\.spatialNormalize))
            }
        }
        Section {
            PathField("Output folder", helpID: "postprocessing.output_folder", text: postprocessingOutputFolderBinding, mode: .directory,
                      defaultName: "HRTF", defaultPath: store.selectedProject.map { ArtifactScanner.postprocessingDirectory(for: $0).path })
            LabeledContent("Results") {
                Button("Open Output Folder") {
                    if let project = store.selectedProject { NSWorkspace.shared.open(ArtifactScanner.postprocessingDirectory(for: project)) }
                }
            }
        }
    }

    private func numberRow(_ title: String, helpID: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                NumberStepperField(title: title, value: value, range: range)
                if let error = validationMessage(helpID) { FieldWarning(error) }
            }
        } label: {
            SettingLabel(title: title, helpID: helpID)
        }
    }

    private var numcalcProgress: String {
        guard let status = store.selectedProjectStatus?.numcalcStatus else { return "Checking…" }
        return status.hasPrefix("NumCalc: ") ? String(status.dropFirst("NumCalc: ".count)) : status
    }

    func validationMessage(_ id: String) -> String? {
        store.selectedValidationIssues.first { $0.id == id }?.message
    }

    func canFitManually(_ side: EarSide) -> Bool {
        (store.selectedProjectStatus?.fittableSides.contains(side) ?? false) && !store.selectedProjectIsRunning
    }

    func manualPPMStatus(for side: EarSide) -> String {
        guard let project = store.selectedProject,
              project.settings.manualPPMFitting.meshPath(for: side) != nil else { return "Not fitted" }
        guard let status = store.selectedProjectStatus else { return "Checking…" }
        return status.validFitSides.contains(side) ? "Fitted" : "Refit needed"
    }

    func scanTextBinding(_ keyPath: WritableKeyPath<ScanPreparationSettings, String>) -> Binding<String> {
        Binding(get: { store.selectedProject?.scanPreparation[keyPath: keyPath] ?? "" }, set: { value in
            store.updateSelectedProject { project in
                var scan = project.scanPreparation
                guard scan[keyPath: keyPath] != value else { return }
                scan[keyPath: keyPath] = value
                project.settings.scanPreparation = scan
            }
        })
    }

    func scanBoolBinding(_ keyPath: WritableKeyPath<ScanPreparationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.selectedProject?.scanPreparation[keyPath: keyPath] ?? false }, set: { value in
            store.updateSelectedProject { project in
                var scan = project.scanPreparation
                scan[keyPath: keyPath] = value
                project.settings.scanPreparation = scan
            }
        })
    }

    func projectStringBinding(_ keyPath: WritableKeyPath<ProjectRecord, String>) -> Binding<String> {
        Binding(
            get: { store.selectedProject?[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject { $0[keyPath: keyPath] = value } }
        )
    }

    var modelNameBinding: Binding<String> {
        Binding(
            get: { store.selectedModelName(for: store.selectedProject) },
            set: { value in store.setSelectedModelName(value) }
        )
    }

    func preprocessingBinding(_ keyPath: WritableKeyPath<PreprocessingSettings, String>) -> Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.preprocessing[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject { $0.settings.preprocessing[keyPath: keyPath] = value } }
        )
    }

    func optionalPreprocessingBinding(_ keyPath: WritableKeyPath<PreprocessingSettings, String?>) -> Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.preprocessing[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject { $0.settings.preprocessing[keyPath: keyPath] = value.isEmpty ? nil : value } }
        )
    }

    func numcalcBinding(_ keyPath: WritableKeyPath<NumCalcSettings, String>) -> Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.numcalc[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject { $0.settings.numcalc[keyPath: keyPath] = value } }
        )
    }

    func numcalcBoolBinding(_ keyPath: WritableKeyPath<NumCalcSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.numcalc[keyPath: keyPath] ?? true },
            set: { value in store.updateSelectedProject { $0.settings.numcalc[keyPath: keyPath] = value } }
        )
    }

    var sourceAssignmentFaceCountBinding: Binding<Int> {
        Binding(
            get: {
                let value = Int(store.selectedProject?.settings.preprocessing.sourceAssignmentFaceCount ?? "") ?? 6
                return min(max(value, 1), 100)
            },
            set: { value in
                store.updateSelectedProject {
                    $0.settings.preprocessing.sourceAssignmentFaceCount = "\(min(max(value, 1), 100))"
                }
            }
        )
    }

    var frequencyStepCountBinding: Binding<Int> {
        Binding(
            get: {
                let value = Int(store.selectedProject?.settings.preprocessing.frequencyStepCount ?? "") ?? 129
                return min(max(value, 2), 10000)
            },
            set: { value in
                store.updateSelectedProject {
                    $0.settings.preprocessing.frequencyStepCount = "\(min(max(value, 2), 10000))"
                }
            }
        )
    }

    func postprocessingValue<T>(_ keyPath: WritableKeyPath<PostprocessingSettings, T>) -> Binding<T> {
        Binding(get: { (store.selectedProject?.settings.postprocessing ?? PostprocessingSettings())[keyPath: keyPath] }, set: { value in
            store.updateSelectedProject {
                var settings = $0.settings.postprocessing ?? PostprocessingSettings()
                settings[keyPath: keyPath] = value
                $0.settings.postprocessing = settings
            }
        })
    }

    var postprocessingOutputFolderBinding: Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.postprocessing?.outputFolder ?? "" },
            set: { value in
                store.updateSelectedProject {
                    var settings = $0.settings.postprocessing ?? PostprocessingSettings()
                    settings.outputFolder = value.isEmpty ? nil : value
                    $0.settings.postprocessing = settings
                }
            }
        )
    }
}

struct NoProjectSelectedView: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView("No Project Selected", systemImage: "folder")
        } else {
            Text("No Project Selected")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EarModelRadioButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let isSelected: Bool
    let select: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.selectModel))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.state = isSelected ? .on : .off
        button.isEnabled = isEnabled
        context.coordinator.select = isSelected ? nil : select
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    final class Coordinator: NSObject {
        var select: (() -> Void)?

        @objc func selectModel() { select?() }
    }
}

private struct FooterScrollEdge: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            content
        }
    }
}
