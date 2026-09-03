import SwiftUI

struct ProjectInspectorView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project")
                    .font(.headline)
                Spacer()
            }
            Divider()
            if store.selectedProject == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No project selected")
                        .font(.title3.weight(.semibold))
                    Text("Create or select a project in the sidebar to edit settings and run the pipeline.")
                        .foregroundStyle(.secondary)
                    Button {
                        store.createProject()
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                settingsPanel
                    .frame(maxHeight: .infinity)
                Divider()
                RunPanelView(store: store)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                requiredPanel
                SettingsDisclosure("Mesh2PPM", systemImage: "wand.and.stars") {
                    ModelPicker(selection: modelNameBinding, options: store.modelOptions, helpID: "inference.model")
                }
                SettingsDisclosure("Mesh2HRTF", systemImage: "waveform.path.ecg") {
                    PathField("Evaluation grid", helpID: "mesh2hrtf.evaluation_grid", text: optionalPreprocessingBinding(\.evaluationGrid), mode: .directory)
                    SettingToggle(title: "Use custom head radius", helpID: "mesh2hrtf.use_head_radius", isOn: useCustomHeadRadiusBinding)
                    LabeledMillimeterSlider("Head radius", helpID: "mesh2hrtf.head_radius", value: headRadiusBinding, range: 0...200, sliderEnabled: useCustomHeadRadiusBinding.wrappedValue)
                    LabeledTextField("Min frequency", helpID: "mesh2hrtf.min_frequency", text: preprocessingBinding(\.minFrequency))
                    LabeledTextField("Max frequency", helpID: "mesh2hrtf.max_frequency", text: preprocessingBinding(\.maxFrequency))
                    HStack {
                        SettingLabel(title: "Frequency steps", helpID: "mesh2hrtf.frequency_steps")
                        Spacer()
                        Stepper(value: frequencyStepCountBinding, in: 2...10000) {
                            Text("\(frequencyStepCountBinding.wrappedValue)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    HStack {
                        SettingLabel(title: "Microphone faces", helpID: "mesh2hrtf.microphone_faces")
                        Spacer()
                        Stepper(value: sourceAssignmentFaceCountBinding, in: 1...100) {
                            Text("\(sourceAssignmentFaceCountBinding.wrappedValue)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
                SettingsDisclosure("Mesh Grading", systemImage: "ruler") {
                    Text("Required safety step")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledTextField("Min edge length", helpID: "mesh_grading.min_edge_length", text: preprocessingBinding(\.meshMinEdgeLength))
                    LabeledTextField("Max edge length", helpID: "mesh_grading.max_edge_length", text: preprocessingBinding(\.meshMaxEdgeLength))
                    LabeledTextField("Max error", helpID: "mesh_grading.max_error", text: preprocessingBinding(\.meshMaxError))
                    LabeledTextField("Gamma", helpID: "mesh_grading.gamma", text: preprocessingBinding(\.meshGamma))
                    LabeledTextField("Gamma opposite", helpID: "mesh_grading.gamma_opposite", text: preprocessingBinding(\.meshGammaOpposite))
                }
                SettingsDisclosure("NumCalc", systemImage: "cpu") {
                    LabeledTextField("Parallel instances", helpID: "numcalc.parallel_instances", text: numcalcBinding(\.maxInstances))
                    LabeledTextField("CPU limit (%)", helpID: "numcalc.cpu_limit", text: numcalcBinding(\.maxCPULoad))
                    SettingToggle(title: "Adaptive FMM expansion length", helpID: "numcalc.adaptive_fmm", isOn: numcalcBoolBinding(\.adaptiveFmmLength))
                }
                SettingsDisclosure("Postprocessing", systemImage: "slider.horizontal.3") {
                    SettingToggle(title: "Normalize HRTFs", helpID: "postprocessing.normalize", isOn: postprocessingNormalizeBinding)
                    LabeledTextField("Level offset (dB)", helpID: "postprocessing.level_offset", text: postprocessingLevelOffsetBinding, fieldEnabled: postprocessingNormalizeBinding.wrappedValue)
                }
            }
            .padding(.vertical, 4)
        }
    }

    var requiredPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledTextField("Project name", helpID: "project.name", text: projectStringBinding(\.name, refresh: false))
            PathField("Left ear (optional)", helpID: "project.left_ear", text: projectStringBinding(\.leftEar), mode: .file)
            PathField("Right ear (optional)", helpID: "project.right_ear", text: projectStringBinding(\.rightEar), mode: .file)
            Text("Choose at least one ear mesh.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PathField("Save location", helpID: "project.save_location", text: projectStringBinding(\.saveLocation), mode: .directory)
                SettingToggle(title: "Use Mesh2PPM", helpID: "project.use_bezierppm", isOn: inferenceBoolBinding(\.usePredictionsForPreprocessing))
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    func projectStringBinding(_ keyPath: WritableKeyPath<ProjectRecord, String>, refresh: Bool = true) -> Binding<String> {
        Binding(
            get: { store.selectedProject?[keyPath: keyPath] ?? "" },
            set: { value in store.updateSelectedProject(refresh: refresh) { $0[keyPath: keyPath] = value } }
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

    var headRadiusBinding: Binding<Double> {
        Binding(
            get: {
                guard let text = store.selectedProject?.settings.preprocessing.headRadius, let value = Double(text) else {
                    return 0
                }
                return min(max(value, 0), 200)
            },
            set: { value in
                let rounded = Int(min(max(value, 0), 200).rounded())
                store.updateSelectedProject { project in
                    project.settings.preprocessing.headRadius = "\(rounded)"
                }
            }
        )
    }

    var useCustomHeadRadiusBinding: Binding<Bool> {
        Binding(
            get: {
                guard let preprocessing = store.selectedProject?.settings.preprocessing else {
                    return false
                }
                return preprocessing.useCustomHeadRadius ?? (preprocessing.headRadius != nil)
            },
            set: { value in
                store.updateSelectedProject { project in
                    project.settings.preprocessing.useCustomHeadRadius = value
                    if value, project.settings.preprocessing.headRadius == nil {
                        project.settings.preprocessing.headRadius = "0"
                    }
                }
            }
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
