import Foundation

struct AcousticTorsoSettings: Codable, Equatable {
    static let keys = ["gain", "min_source_elevation_deg", "max_angular_gap_deg", "symmetry", "delay_model", "model_source_distance_m", "interpolation", "missing_policy", "apply_shadow", "normalize_reflection_mix"]
    static let flags: Set<String> = ["apply_shadow", "normalize_reflection_mix"]
    static let choices: Set<String> = ["symmetry", "delay_model", "interpolation", "missing_policy"]
    var values: [String: String] = [:]

    init(config: [String: Any] = [:]) {
        for key in Self.keys {
            if let value = config[key] as? String { values[key] = value }
            else if let value = config[key] as? NSNumber {
                values[key] = Self.flags.contains(key) ? String(value.boolValue) : value.stringValue
            }
        }
    }

    func text(_ key: String) -> String {
        values[key] ?? (Self.flags.contains(key) ? String(SettingsCatalog.flag("acoustic_torso." + key)) : SettingsCatalog.text("acoustic_torso." + key))
    }

    var payload: [String: Any] {
        Dictionary(uniqueKeysWithValues: Self.keys.map { key -> (String, Any) in
            let value = text(key).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.flags.contains(key) { return (key, value == "true") }
            if Self.choices.contains(key) { return (key, value) }
            return (key, Double(value).map { $0 as Any } ?? NSNull())
        })
    }

    static func effective(_ project: ProjectRecord) -> Self {
        if let saved = project.settings.acousticTorso { return saved }
        let data = Data((project.preservedConfigJSON ?? "{}").utf8)
        let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Self(config: config["acoustic_torso"] as? [String: Any] ?? [:])
    }
}
