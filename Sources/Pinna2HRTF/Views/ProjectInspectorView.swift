import SwiftUI
import AppKit

struct ProjectInspectorView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workflow").font(.headline).padding(12)
            VStack(spacing: 2) {
                ForEach(WorkflowStep.allCases) { step in
                    Button { store.workflowStep = step } label: {
                        HStack {
                            Text("\(step.rawValue + 1). \(step.title)")
                            Spacer(minLength: 4)
                            Label(store.workflowStatus(step), systemImage: store.workflowSymbol(step)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 10).padding(.vertical, 5)
                            .background(store.workflowStep == step ? Color.accentColor.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(store.workflowStep == step ? .isSelected : [])
                }
            }.padding(.horizontal, 8)
            Divider().padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.workflowStep.title).font(.title3.weight(.semibold))
                    stageContent
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(store.selectedProject == nil || store.selectedProjectIsRunning)
            }
            Divider()
            WorkflowFooter(store: store).padding(12)
        }
        .onChange(of: store.earDistanceFocusRequest) { _ in store.workflowStep = .simulation }
    }

    @ViewBuilder var stageContent: some View {
        switch store.workflowStep {
        case .inputs: requiredPanel
        case .prepare:
            if store.selectedProject?.scanPreparation.enabled == true {
                Button("Align scan…") { store.beginScanAlignment() }
                Text("Use an already aligned scan, or align it here before preparing ears.").font(.caption).foregroundStyle(.secondary)
                stageAction(.scanPreparation)
                DisclosureGroup("Advanced settings · scan preparation") {
                    LabeledTextField("Target edge (mm)", helpID: "scan.target_edge", text: scanTextBinding(\.targetEdgeMM))
                    LabeledTextField("Left crop margin (mm)", helpID: "scan.left_margin", text: scanTextBinding(\.leftMarginMM))
                    LabeledTextField("Right crop margin (mm)", helpID: "scan.right_margin", text: scanTextBinding(\.rightMarginMM))
                    LabeledTextField("Inner crop limit (mm)", helpID: "scan.side_min", text: scanTextBinding(\.sideMinMM))
                    LabeledTextField("Outer crop limit (mm)", helpID: "scan.side_max", text: scanTextBinding(\.sideMaxMM))
                    Text("Use an aligned scan in mm. Ears are cropped, remeshed, and repaired. A saved, current ear edit is used automatically.")
                        .font(.caption).foregroundStyle(.secondary)

                }
            }
            Text("Inspect and optionally edit each ear. Original input files are preserved.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.workflowSides) { side in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(side.title) ear").fontWeight(.semibold)
                    HStack {
                        Button("Inspect") {
                            if let p = store.selectedProject, let url = ArtifactScanner.sourceEar(for: p, side: side) {
                                store.openArtifact(Artifact(title: "\(side.title) ear", url: url))
                            }
                        }
                        Button("Edit…") { store.beginEarEditing(side) }
                    }.disabled(!(store.selectedProjectStatus?.fittableSides.contains(side) ?? false))
                    if let p = store.selectedProject,
                       (p.scanPreparation.earEdit(side)) != nil {
                        Text(ArtifactScanner.earReviewIsCurrent(p, side: side) ? "Saved edit in use" : "Saved edit outdated").font(.caption)
                        Button("Use original ear") {
                            store.updateSelectedProject {
                                var scan = $0.scanPreparation
                                scan.setEarEdit(nil, side: side)
                                $0.settings.scanPreparation = scan
                            }
                        }
                    }
                }
            }
        case .model:
            Picker("Ear modelling method", selection: Binding<EarModelMethod?>(get: { store.earModelMethod }, set: { if let value = $0 { store.selectEarModelMethod(value) } })) {
                ForEach(EarModelMethod.allCases) { method in Text(method.title).tag(Optional(method)) }
            }.pickerStyle(.radioGroup)
            Text("One method applies to every included ear.").font(.caption).foregroundStyle(.secondary)
            if store.earModelMethod == .manual {
                manualPPMPanel
            } else if store.earModelMethod == .mesh2ppm {
                Text("Generate PPM geometry automatically.").font(.caption)
                DisclosureGroup("Advanced settings · model") {
                    ModelPicker(selection: modelNameBinding, options: store.modelOptions, helpID: "inference.model")
                }
                stageAction(.inference)
            } else if store.earModelMethod == EarModelMethod.none {
                Text("Using ear meshes directly. Required mesh preprocessing still runs.").font(.caption)
            } else {
                Text("This project has conflicting methods. Choose one above before continuing.").foregroundStyle(.orange)
            }
        case .simulation:
            HeadGeometryControls(store: store)
            Text("Microphone positions").fontWeight(.semibold)
            Text("Automatic positioning remains the default; adjust only when needed.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.workflowSides) { side in
                Button("Adjust \(side.rawValue) microphone…") { store.beginMicrophonePlacement(side) }
                    .disabled(!(store.selectedProjectStatus?.pipelineSides.contains(side) ?? false))
            }
            VStack(alignment: .leading, spacing: 9) {
                    PathField("Evaluation grid", helpID: "mesh2hrtf.evaluation_grid", text: optionalPreprocessingBinding(\.evaluationGrid), mode: .directory)
                    LabeledTextField("Min frequency", helpID: "mesh2hrtf.min_frequency", text: preprocessingBinding(\.minFrequency))
                    LabeledTextField("Max frequency", helpID: "mesh2hrtf.max_frequency", text: preprocessingBinding(\.maxFrequency), validationError: validationMessage("mesh2hrtf.max_frequency"))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SettingLabel(title: "Frequency steps", helpID: "mesh2hrtf.frequency_steps")
                            Spacer()
                            TextField("Frequency steps", text: preprocessingBinding(\.frequencyStepCount))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Stepper("", value: frequencyStepCountBinding, in: 2...10000)
                                .labelsHidden()
                                .fixedSize()
                                .accessibilityLabel("Adjust Frequency steps")
                        }
                        if let error = validationMessage("mesh2hrtf.frequency_steps") { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SettingLabel(title: "Microphone faces", helpID: "mesh2hrtf.microphone_faces")
                            Spacer()
                            TextField("Microphone faces", text: optionalPreprocessingBinding(\.sourceAssignmentFaceCount))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Stepper("", value: sourceAssignmentFaceCountBinding, in: 1...100)
                                .labelsHidden()
                                .fixedSize()
                                .accessibilityLabel("Adjust Microphone faces")
                        }
                        if let error = validationMessage("mesh2hrtf.microphone_faces") { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                SettingsDisclosure("Advanced mesh grading", systemImage: "ruler") {
                    Text("Required safety step")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledTextField("Min edge length", helpID: "mesh_grading.min_edge_length", text: preprocessingBinding(\.meshMinEdgeLength))
                    LabeledTextField("Max edge length", helpID: "mesh_grading.max_edge_length", text: preprocessingBinding(\.meshMaxEdgeLength), validationError: validationMessage("mesh_grading.max_edge_length"))
                    LabeledTextField("Max error", helpID: "mesh_grading.max_error", text: preprocessingBinding(\.meshMaxError))
                    LabeledTextField("Gamma", helpID: "mesh_grading.gamma", text: preprocessingBinding(\.meshGamma))
                    LabeledTextField("Gamma opposite", helpID: "mesh_grading.gamma_opposite", text: preprocessingBinding(\.meshGammaOpposite))
                }
            }
            stageAction(.preprocessing)
        case .calculate:
            Text(store.selectedProjectStatus?.numcalcStatus ?? "Checking project files…").font(.caption)
            DisclosureGroup("Advanced settings · calculation") {
                    LabeledTextField("Parallel instances", helpID: "numcalc.parallel_instances", text: numcalcBinding(\.maxInstances))
                    LabeledTextField("CPU limit (%)", helpID: "numcalc.cpu_limit", text: numcalcBinding(\.maxCPULoad))
                    SettingToggle(title: "Adaptive FMM expansion length", helpID: "numcalc.adaptive_fmm", isOn: numcalcBoolBinding(\.adaptiveFmmLength))

            }
            stageAction(.numcalc)
        case .results:
            SettingToggle(title: "Apply level offset", helpID: "postprocessing.normalize", isOn: postprocessingNormalizeBinding)
            if postprocessingNormalizeBinding.wrappedValue {
                LabeledTextField("Level offset (dB)", helpID: "postprocessing.level_offset", text: postprocessingLevelOffsetBinding)
            }
            SettingToggle(title: "Resample HRIRs", helpID: "postprocessing.resample_hrirs", isOn: postprocessingResampleBinding)
            if postprocessingResampleBinding.wrappedValue {
                LabeledTextField("Sampling rate (Hz)", helpID: "postprocessing.sampling_rate", text: postprocessingSamplingRateBinding)
            }
            SettingToggle(title: "Spatially upsample HRTFs", helpID: "postprocessing.spatial_upsampling", isOn: postprocessingValue(\.spatialUpsampling))
            if store.selectedProject?.settings.postprocessing?.spatialUpsampling == true {
                Stepper("Subdivision level: \(postprocessingValue(\.spatialSubdivisions).wrappedValue)", value: postprocessingValue(\.spatialSubdivisions), in: 0...5)
                SettingToggle(title: "Normalize to frontal reference", helpID: "postprocessing.spatial_normalize", isOn: postprocessingValue(\.spatialNormalize))
                Text("Adds source directions while preserving arrival times. Results are saved in Upsampled; originals are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PathField("SOFA output folder (optional)", helpID: "postprocessing.output_folder", text: postprocessingOutputFolderBinding, mode: .directory)
            stageAction(.postprocessing)
            Button("Open output folder") {
                if let p = store.selectedProject { NSWorkspace.shared.open(ArtifactScanner.postprocessingDirectory(for: p)) }
            }
        }
    }

    @ViewBuilder func stageAction(_ stage: Stage) -> some View {
        Button("Run \(stage.title)") { store.run(stage: stage) }.disabled(!store.canRun(stage: stage))
        if let reason = store.runUnavailableReason(stage: stage) { Text(reason).font(.caption).foregroundStyle(.secondary) }
    }

    var requiredPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledTextField("Project name", helpID: "project.name", text: projectStringBinding(\.name))
            PathField("Save location", helpID: "project.save_location", text: projectStringBinding(\.saveLocation), mode: .directory, showsOpenButton: true)
            Picker("Input source", selection: scanBoolBinding(\.enabled)) {
                Text("Full-head scan").tag(true)
                Text("Individual ear meshes").tag(false)
            }.pickerStyle(.radioGroup)
            if store.selectedProject?.scanPreparation.enabled == true {
                PathField("Full-head scan", helpID: "scan.path", text: scanTextBinding(\.scanPath), mode: .file)
                Toggle("Prepare left ear", isOn: scanBoolBinding(\.prepareLeft))
                Toggle("Prepare right ear", isOn: scanBoolBinding(\.prepareRight))
                Text("Align and extract ears in Prepare ears.").font(.caption)
            } else {
                PathField("Left ear", helpID: "project.left_ear", text: projectStringBinding(\.leftEar), mode: .file)
                PathField("Right ear", helpID: "project.right_ear", text: projectStringBinding(\.rightEar), mode: .file)
                Text("Choose at least one ear. Inspection and editing are available in Prepare ears.").font(.caption)
            }
        }
    }

    func validationMessage(_ id: String) -> String? {
        return store.selectedValidationIssues.first { $0.id == id }?.message
    }

    var manualPPMPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fit a PPM to either ear.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.workflowSides) { side in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(side.title) ear")
                        Text(manualPPMStatus(for: side))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Fit…") { store.beginManualPPMFitting(side) }
                        .disabled(!canFitManually(side))
                }
            }
            Text("Save a current fit for every included ear to continue.").font(.caption)
            if let issue = store.selectedValidationIssues.first(where: { $0.id.hasPrefix("manual_ppm") }) {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    func canFitManually(_ side: EarSide) -> Bool {
        (store.selectedProjectStatus?.fittableSides.contains(side) ?? false) && !store.selectedProjectIsRunning
    }

    func manualPPMStatus(for side: EarSide) -> String {
        guard let project = store.selectedProject,
              project.settings.manualPPMFitting.meshPath(for: side) != nil else { return "Not fitted" }
        guard let status = store.selectedProjectStatus else { return "Checking saved fit…" }
        return status.validFitSides.contains(side) ? "Saved fit" : "Source changed · refit needed"
    }

    var manualPPMBinding: Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.manualPPMFitting.useForPreprocessing ?? false },
            set: { store.setManualPPMFitting($0) }
        )
    }

    func scanTextBinding(_ keyPath: WritableKeyPath<ScanPreparationSettings, String>) -> Binding<String> {
        Binding(get: { store.selectedProject?.scanPreparation[keyPath: keyPath] ?? "" }, set: { value in
            store.updateSelectedProject { project in
                var scan = project.scanPreparation
                scan[keyPath: keyPath] = value
                if keyPath == \.scanPath {
                    scan.originalScanPath = nil
                    scan.rotationDegrees = "0"
                    scan.reviewedLeftPath = nil; scan.reviewedRightPath = nil
                }
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

    var bezierPPMBinding: Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.inference.usePredictionsForPreprocessing ?? false },
            set: { value in
                let current = store.selectedProject?.settings.inference.usePredictionsForPreprocessing ?? false
                guard value != current else { return }
                guard !store.selectedProjectIsRunning else { return }
                store.confirmSetBezierPPM(value)
            }
        )
    }

    func projectStringBinding(_ keyPath: WritableKeyPath<ProjectRecord, String>) -> Binding<String> {
        Binding(
            get: { store.selectedProject?[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject { $0[keyPath: keyPath] = value } }
        )
    }

    func inferenceBinding(_ keyPath: WritableKeyPath<InferenceSettings, String>) -> Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.inference[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject { $0.settings.inference[keyPath: keyPath] = value } }
        )
    }

    var modelNameBinding: Binding<String> {
        Binding(
            get: { store.selectedModelName(for: store.selectedProject) },
            set: { value in store.setSelectedModelName(value) }
        )
    }

    func inferenceBoolBinding(_ keyPath: WritableKeyPath<InferenceSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.inference[keyPath: keyPath] ?? false },
            set: { value in store.updateSelectedProject { $0.settings.inference[keyPath: keyPath] = value } }
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

    func preprocessingBoolBinding(_ keyPath: WritableKeyPath<PreprocessingSettings, Bool?>) -> Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.preprocessing[keyPath: keyPath] ?? false },
            set: { value in store.updateSelectedProject { $0.settings.preprocessing[keyPath: keyPath] = value } }
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

    func postprocessingOptionalPath(_ keyPath: WritableKeyPath<PostprocessingSettings, String?>) -> Binding<String> {
        let value = postprocessingValue(keyPath)
        return Binding(get: { value.wrappedValue ?? "" }, set: {
            let path = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            value.wrappedValue = path.isEmpty ? nil : path
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

    var postprocessingResampleBinding: Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.postprocessing?.resampleHrirs ?? false },
            set: { value in
                store.updateSelectedProject {
                    var settings = $0.settings.postprocessing ?? PostprocessingSettings()
                    settings.resampleHrirs = value
                    $0.settings.postprocessing = settings
                }
            }
        )
    }

    var postprocessingSamplingRateBinding: Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.postprocessing?.samplingRate ?? "48000" },
            set: { value in
                store.updateSelectedProject {
                    var settings = $0.settings.postprocessing ?? PostprocessingSettings()
                    settings.samplingRate = value
                    $0.settings.postprocessing = settings
                }
            }
        )
    }

    var postprocessingNormalizeBinding: Binding<Bool> {
        Binding(
            get: { store.selectedProject?.settings.postprocessing?.normalize ?? true },
            set: { value in
                store.updateSelectedProject {
                    var settings = $0.settings.postprocessing ?? PostprocessingSettings()
                    settings.normalize = value
                    $0.settings.postprocessing = settings
                }
            }
        )
    }

    var postprocessingLevelOffsetBinding: Binding<String> {
        Binding(
            get: { store.selectedProject?.settings.postprocessing?.levelOffsetDB ?? "-30" },
            set: { value in
                store.updateSelectedProject {
                    var settings = $0.settings.postprocessing ?? PostprocessingSettings()
                    settings.levelOffsetDB = value
                    $0.settings.postprocessing = settings
                }
            }
        )
    }
}
