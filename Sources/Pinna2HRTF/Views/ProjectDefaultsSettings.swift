import SwiftUI

struct ProjectDefaultsSections: View {
    @ObservedObject var store: AppStore
    @AppStorage(AppPreferences.workflow) private var workflowJSON = ""
    @State private var scanExpanded = false

    private var stored: [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(workflowJSON.utf8)) as? [String: Any] else { return [:] }
        return object
    }

    private func field(_ key: String) -> AppPreferences.WorkflowField {
        AppPreferences.workflowFields.first { $0.key == key }!
    }

    private func update(_ key: String, _ value: Any) {
        var values = stored
        values[key] = value
        AppPreferences.storeWorkflow(values)
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { AppPreferences.workflowFlag(field(key), in: stored) }, set: { update(key, $0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { AppPreferences.workflowText(field(key), in: stored) }, set: { update(key, $0) })
    }

    private func whole(_ key: String) -> Binding<Int> {
        Binding(get: { Int(AppPreferences.workflowText(field(key), in: stored)) ?? SettingsCatalog.range(field(key).rule ?? "").lowerBound },
                set: { update(key, $0) })
    }

    private func relationMessage(_ key: String) -> String? {
        guard let rule = field(key).rule else { return nil }
        return SettingsCatalog.check(AppPreferences.workflowFormValues(stored), id: rule)
    }

    private func numberField(_ title: String, key: String) -> some View {
        LabeledTextField(title, helpID: field(key).rule ?? key, text: text(key), validationError: relationMessage(key))
    }

    private var inputSource: Binding<Bool> { flag("full_head_scan") }

    private var earModel: Binding<EarModelMethod> {
        Binding(get: { (stored["ear_model_method"] as? String).flatMap(EarModelMethod.init(rawValue:)) ?? EarModelMethod.none },
                set: { update("ear_model_method", $0.rawValue) })
    }

    private var inferenceModel: Binding<String> {
        Binding(get: { stored["inference_model"] as? String ?? AppStore.modelName(SettingsCatalog.text("inference.model_config_file")) },
                set: { update("inference_model", $0) })
    }

    private var scanEars: Binding<String> {
        Binding(get: {
            let left = AppPreferences.workflowFlag(field("prepare_left"), in: stored)
            let right = AppPreferences.workflowFlag(field("prepare_right"), in: stored)
            return left && right ? "both" : left ? "left" : "right"
        }, set: { choice in
            var values = stored
            values["prepare_left"] = choice != "right"
            values["prepare_right"] = choice != "left"
            AppPreferences.storeWorkflow(values)
        })
    }

    var body: some View {
        Section {
            HelpRow("Input", helpID: "defaults.input_source") {
                Picker("Input", selection: inputSource) {
                    Text("Ear meshes").tag(false)
                    Text("Full-head scan").tag(true)
                }
                .labelsHidden()
                .fixedSize()
            }
            HelpRow("Ears from scan", helpID: "defaults.prepared_ears") {
                Picker("Ears from scan", selection: scanEars) {
                    Text("Left and Right").tag("both")
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                .labelsHidden()
                .fixedSize()
            }
            HelpToggle("Review ears before continuing", helpID: "defaults.require_review", isOn: flag("require_manual_review"))
            DisclosureGroup("Ear Cropping & Remeshing", isExpanded: $scanExpanded) {
                numberField("Target edge (mm)", key: "target_edge_mm")
                numberField("Left margin (mm)", key: "left_margin_mm")
                numberField("Right margin (mm)", key: "right_margin_mm")
                numberField("Inner crop limit (mm)", key: "side_min_mm")
                numberField("Outer crop limit (mm)", key: "side_max_mm")
            }
        } header: {
            Text("Ear Preparation")
        }
        Section {
            HelpRow("Ear model", helpID: "defaults.ear_model_method") {
                Picker("Ear model", selection: earModel) {
                    ForEach(EarModelMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            ModelPicker(selection: inferenceModel, options: store.modelOptions, helpID: "inference.model")
                .disabled(earModel.wrappedValue != .mesh2ppm)
        } header: {
            Text("Ear Model")
        }
    }
}

struct SimulationDefaultsRows: View {
    @AppStorage(AppPreferences.workflow) private var workflowJSON = ""
    @State private var gradingExpanded = false

    private var stored: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(workflowJSON.utf8)) as? [String: Any]) ?? [:]
    }

    private func field(_ key: String) -> AppPreferences.WorkflowField {
        AppPreferences.workflowFields.first { $0.key == key }!
    }

    private func update(_ key: String, _ value: Any) {
        var values = stored
        values[key] = value
        AppPreferences.storeWorkflow(values)
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { AppPreferences.workflowText(field(key), in: stored) }, set: { update(key, $0) })
    }

    private var faces: Binding<Int> {
        let range = SettingsCatalog.range("mesh2hrtf.microphone_faces")
        return Binding(get: { Int(AppPreferences.workflowText(field("source_assignment_face_count"), in: stored)) ?? range.lowerBound },
                       set: { update("source_assignment_face_count", $0) })
    }

    private func numberField(_ title: String, key: String) -> some View {
        let rule = field(key).rule ?? key
        return LabeledTextField(title, helpID: rule, text: text(key),
                                validationError: SettingsCatalog.check(AppPreferences.workflowFormValues(stored), id: rule))
    }

    var body: some View {
        HelpRow("Microphone faces", helpID: "mesh2hrtf.microphone_faces") {
            NumberStepperField(title: "Microphone faces", value: faces, range: SettingsCatalog.range("mesh2hrtf.microphone_faces"))
        }
        DisclosureGroup("Mesh Grading", isExpanded: $gradingExpanded) {
            numberField("Min edge length (mm)", key: "mesh_min_edge_length")
            numberField("Max edge length (mm)", key: "mesh_max_edge_length")
            numberField("Max error (mm)", key: "mesh_max_error")
            numberField("Gamma", key: "mesh_gamma")
            numberField("Gamma opposite", key: "mesh_gamma_opposite")
        }
    }
}

struct HeadTorsoDefaultsSections: View {
    @AppStorage(AppPreferences.workflow) private var workflowJSON = ""

    private var stored: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(workflowJSON.utf8)) as? [String: Any]) ?? [:]
    }

    private func field(_ key: String) -> AppPreferences.WorkflowField {
        AppPreferences.workflowFields.first { $0.key == key }!
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { AppPreferences.workflowText(field(key), in: stored) }, set: { value in
            var values = stored
            values[key] = value
            AppPreferences.storeWorkflow(values)
        })
    }

    private func numberField(_ title: String, key: String) -> some View {
        let rule = field(key).rule ?? key
        return LabeledTextField(title, helpID: rule, text: text(key),
                                validationError: SettingsCatalog.check(AppPreferences.workflowFormValues(stored), id: rule))
    }

    var body: some View {
        Section("Head") {
            numberField("Ear-to-ear radius scale", key: "head_radius_scale")
            numberField("Front-to-back scale", key: "head_width_scale")
            numberField("Height scale", key: "head_height_scale")
            numberField("Head taper (%)", key: "head_taper_percent")
        }
        Section("Torso") {
            LabeledContent {
                Picker("Torso modelling", selection: text("torso_mode")) {
                    Text("Off").tag("off")
                    Text("Geometric").tag("geometric")
                    Text("Acoustic").tag("acoustic")
                }.labelsHidden()
            } label: { SettingLabel(title: "Torso modelling", helpID: "torso.mode") }
            if text("torso_mode").wrappedValue == "geometric" {
                numberField("Torso width (mm)", key: "torso_width_mm")
                numberField("Torso depth (mm)", key: "torso_depth_mm")
                numberField("Torso height (mm)", key: "torso_height_mm")
            }
            if text("torso_mode").wrappedValue == "acoustic" { AcousticTorsoDefaultsControls() }
        }
    }
}

struct AdaptiveFMMDefaultToggle: View {
    @AppStorage(AppPreferences.workflow) private var workflowJSON = ""

    var body: some View {
        let field = AppPreferences.workflowFields.first { $0.key == "adaptive_fmm_length" }!
        let stored = (try? JSONSerialization.jsonObject(with: Data(workflowJSON.utf8)) as? [String: Any]) ?? [:]
        HelpToggle("Adaptive FMM expansion", helpID: "numcalc.adaptive_fmm", isOn: Binding(
            get: { AppPreferences.workflowFlag(field, in: stored) },
            set: { value in
                var values = stored
                values[field.key] = value
                AppPreferences.storeWorkflow(values)
            }))
    }
}

struct ExportDefaultsSections: View {
    @AppStorage(AppPreferences.workflow) private var workflowJSON = ""

    private var stored: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(workflowJSON.utf8)) as? [String: Any]) ?? [:]
    }

    private func field(_ key: String) -> AppPreferences.WorkflowField {
        AppPreferences.workflowFields.first { $0.key == key }!
    }

    private func update(_ key: String, _ value: Any) {
        var values = stored
        values[key] = value
        AppPreferences.storeWorkflow(values)
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { AppPreferences.workflowFlag(field(key), in: stored) }, set: { update(key, $0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { AppPreferences.workflowText(field(key), in: stored) }, set: { update(key, $0) })
    }

    private var subdivisions: Binding<Int> {
        Binding(get: { Int(AppPreferences.workflowText(field("spatial_subdivisions"), in: stored)) ?? 0 },
                set: { update("spatial_subdivisions", $0) })
    }

    var body: some View {
        Section {
            DefaultsOption(title: "Apply level offset", helpID: "postprocessing.normalize", isOn: flag("normalize")) {
                LabeledTextField("Level offset (dB)", helpID: "postprocessing.level_offset", text: text("level_offset_db"))
            }
            DefaultsOption(title: "Resample HRIRs", helpID: "postprocessing.resample_hrirs", isOn: flag("resample_hrirs")) {
                LabeledTextField("Sampling rate (Hz)", helpID: "postprocessing.sampling_rate", text: text("sampling_rate"))
            }
            DefaultsOption(title: "Spatially upsample HRTFs", helpID: "postprocessing.spatial_upsampling", isOn: flag("spatial_upsampling")) {
                LabeledContent {
                    NumberStepperField(title: "Subdivision level", value: subdivisions, range: SettingsCatalog.range("postprocessing.spatial_subdivisions"))
                } label: { SettingLabel(title: "Subdivision level", helpID: "postprocessing.spatial_subdivisions") }
                SettingToggle(title: "Normalize to frontal reference", helpID: "postprocessing.spatial_normalize", isOn: flag("spatial_normalize"))
            }
        } header: { Text("SOFA Export") }
        if AppPreferences.workflowText(AppPreferences.workflowFields.first { $0.key == "torso_mode" }!, in: stored) == "acoustic" {
            Section("Acoustic torso") { AcousticTorsoDefaultsControls(export: true) }
        }
    }
}

private struct DefaultsOption<Content: View>: View {
    let title: String
    let helpID: String
    @Binding var isOn: Bool
    @State private var expanded: Bool
    let content: Content

    init(title: String, helpID: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.helpID = helpID
        self._isOn = isOn
        self._expanded = State(initialValue: isOn.wrappedValue)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { content.disabled(!isOn) } label: {
            SettingToggle(title: title, helpID: helpID, isOn: $isOn)
        }
        .onChange(of: isOn) { expanded = $0 }
    }
}
