import SwiftUI

struct AcousticTorsoControls: View {
    @Binding var settings: AcousticTorsoSettings
    var export: Bool = false

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { settings.text(key) }, set: { settings.values[key] = $0 })
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { settings.text(key) == "true" }, set: { settings.values[key] = String($0) })
    }

    private func number(_ title: String, _ key: String) -> some View {
        LabeledTextField(title, helpID: "acoustic_torso." + key, text: text(key),
                         validationError: SettingsCatalog.fieldMessage("acoustic_torso." + key, text: settings.text(key)))
    }

    private func choice(_ title: String, _ key: String, _ options: [(String, String)]) -> some View {
        LabeledContent {
            Picker(title, selection: text(key)) {
                ForEach(options, id: \.1) { option in Text(option.0).tag(option.1) }
            }.labelsHidden()
        } label: { SettingLabel(title: title, helpID: "acoustic_torso." + key) }
    }

    var body: some View {
        if export {
            number("Reflection gain", "gain")
            SettingToggle(title: "Apply torso shadow", helpID: "acoustic_torso.apply_shadow", isOn: flag("apply_shadow"))
            SettingToggle(title: "Normalize reflection mix", helpID: "acoustic_torso.normalize_reflection_mix", isOn: flag("normalize_reflection_mix"))
            choice("Delay model", "delay_model", [("Algazi", "algazi"), ("Reijniers delay", "reijniers")])
            if settings.text("delay_model") == "reijniers" { number("Model source distance (m)", "model_source_distance_m") }
            DisclosureGroup("Advanced acoustic options") {
                choice("HRIR interpolation", "interpolation", [("Peak-aligned interpolation", "aligned_idw"), ("Nearest direction", "nearest")])
                choice("Missing reflection coverage", "missing_policy", [("Stop export", "error"), ("Skip uncovered directions", "skip")])
            }
        } else {
            number("Maximum angular gap (°)", "max_angular_gap_deg")
            number("Minimum elevation (°)", "min_source_elevation_deg")
            choice("Grid symmetry", "symmetry", [("Automatic", "auto"), ("Require symmetry", "require"), ("Off", "off")])
        }
    }
}

struct AcousticTorsoDefaultsControls: View {
    @AppStorage(AppPreferences.workflow) private var workflowJSON = ""
    var export: Bool = false

    var body: some View {
        let stored = (try? JSONSerialization.jsonObject(with: Data(workflowJSON.utf8))) as? [String: Any] ?? [:]
        AcousticTorsoControls(settings: Binding(get: {
            AcousticTorsoSettings(config: stored["acoustic_torso"] as? [String: Any] ?? [:])
        }, set: { value in
            var stored = AppPreferences.storedWorkflow
            stored["acoustic_torso"] = value.values
            AppPreferences.storeWorkflow(stored)
        }), export: export)
    }
}

struct AcousticTorsoGridStatus: View {
    let request: String
    @State private var message = "Checking grid…"

    var body: some View {
        LabeledContent("Evaluation grid", value: message)
            .task(id: request) {
                message = "Checking grid…"
                let result = await Task.detached { () -> String in
                    do {
                        let payload = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any] ?? [:]
                        let reply = try ProjectConfigDocument.request("acoustic-torso-status", payload)
                        let value = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
                        return value?["message"] as? String ?? "Grid status unavailable."
                    } catch { return error.localizedDescription }
                }.value
                if !Task.isCancelled { message = result }
            }
    }
}
