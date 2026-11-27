import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HelpRow<Content: View>: View {
    let title: String
    let helpID: String
    @ViewBuilder let content: Content

    init(_ title: String, helpID: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.helpID = helpID
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            SettingLabel(title: title, helpID: helpID)
        }
    }
}

struct HelpToggle: View {
    let title: String
    let helpID: String
    @Binding var isOn: Bool

    init(_ title: String, helpID: String, isOn: Binding<Bool>) {
        self.title = title
        self.helpID = helpID
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingLabel(title: title, helpID: helpID)
        }
    }
}

enum ProjectDefaultsFile {
    static let preferenceKeys = [
        AppPreferences.projectDirectory, AppPreferences.inputHandling, AppPreferences.evaluationGrid,
        AppPreferences.minimumFrequency, AppPreferences.maximumFrequency, AppPreferences.frequencySteps,
        AppPreferences.maxInstances, AppPreferences.maxCPULoad, AppPreferences.workflow
    ]

    private static let integers: [(payload: String, key: String, field: String, config: String)] = [
        ("minimum_frequency", AppPreferences.minimumFrequency, "mesh2hrtf.min_frequency", "preprocessing.min_frequency"),
        ("maximum_frequency", AppPreferences.maximumFrequency, "mesh2hrtf.max_frequency", "preprocessing.max_frequency"),
        ("frequency_steps", AppPreferences.frequencySteps, "mesh2hrtf.frequency_steps", "preprocessing.frequency_step_count"),
        ("max_instances", AppPreferences.maxInstances, "numcalc.parallel_instances", "numcalc.max_instances"),
        ("max_cpu_load", AppPreferences.maxCPULoad, "numcalc.cpu_limit", "numcalc.max_cpu_load")
    ]

    static func payload() -> [String: Any] {
        let defaults = UserDefaults.standard
        var payload: [String: Any] = [
            "project_directory": defaults.string(forKey: AppPreferences.projectDirectory) ?? "",
            "input_handling": defaults.string(forKey: AppPreferences.inputHandling) ?? InputHandling.copy.rawValue,
            "evaluation_grid": defaults.string(forKey: AppPreferences.evaluationGrid) ?? ""
        ]
        for item in integers {
            payload[item.payload] = AppPreferences.int(item.key, fallback: Int(SettingsCatalog.text(item.config)) ?? 0, range: SettingsCatalog.range(item.field))
        }
        let stored = AppPreferences.storedWorkflow
        var workflow: [String: Any] = [
            "ear_model_method": stored["ear_model_method"] as? String ?? EarModelMethod.none.rawValue,
            "inference_model": stored["inference_model"] as? String ?? AppStore.modelName(SettingsCatalog.text("inference.model_config_file"))
        ]
        for field in AppPreferences.workflowFields {
            if field.rule == nil || AppPreferences.workflowFlagRules.contains(field.rule!) {
                workflow[field.key] = AppPreferences.workflowFlag(field, in: stored)
                continue
            }
            let text = AppPreferences.workflowText(field, in: stored).trimmingCharacters(in: .whitespacesAndNewlines)
            if AppPreferences.workflowTextKeys.contains(field.key) { workflow[field.key] = text; continue }
            if let number = Int(text) { workflow[field.key] = number } else if let number = Double(text), number.isFinite { workflow[field.key] = number }
        }
        workflow["acoustic_torso"] = AcousticTorsoSettings(config: stored["acoustic_torso"] as? [String: Any] ?? [:]).payload
        payload["workflow"] = workflow
        return payload
    }

    static func apply(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        defaults.set(values["project_directory"] as? String ?? "", forKey: AppPreferences.projectDirectory)
        defaults.set(values["input_handling"] as? String ?? InputHandling.copy.rawValue, forKey: AppPreferences.inputHandling)
        defaults.set(values["evaluation_grid"] as? String ?? "", forKey: AppPreferences.evaluationGrid)
        for item in integers {
            if let number = values[item.payload] as? Int { defaults.set(number, forKey: item.key) }
        }
        AppPreferences.storeWorkflow(values["workflow"] as? [String: Any] ?? [:])
    }

    static func reset() {
        for key in preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
    }
}

struct ProjectDefaultsActions: View {
    @State private var error: String?

    var body: some View {
        HStack {
            Spacer()
            Button("Save Defaults…", action: save)
            Button("Load Defaults…", action: load)
            Button("Reset to Defaults…", action: reset)
                .help("Existing projects keep their settings.")
        }
        .alert("Couldn’t Update Project Defaults", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Pinna2HRTF Project Defaults.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload = ProjectDefaultsFile.payload()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ProjectConfigDocument.request("save-defaults", ["path": url.path, "defaults": payload]) }
            }.value
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[String: Any], Error> in
                Result {
                    let data = try ProjectConfigDocument.request("read-defaults", ["path": url.path])
                    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let defaults = reply["defaults"] as? [String: Any] else {
                        throw ProjectValidation.Failure(message: "Choose a supported Pinna2HRTF project defaults file.")
                    }
                    return defaults
                }
            }.value
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let defaults):
                guard confirm("Load Project Defaults from “\(url.lastPathComponent)”?", button: "Load") else { return }
                ProjectDefaultsFile.apply(defaults)
            }
        }
    }

    private func reset() {
        guard confirm("Reset Project Defaults?", button: "Reset") else { return }
        ProjectDefaultsFile.reset()
    }

    private func confirm(_ title: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Existing projects, notifications and tool settings stay unchanged."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
