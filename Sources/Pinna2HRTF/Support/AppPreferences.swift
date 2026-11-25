import Foundation

enum AppPreferences {
    static let projectDirectory = "preferences.projectDirectory"
    static let inputHandling = "preferences.inputHandling"
    static let evaluationGrid = "preferences.evaluationGrid"
    static let minimumFrequency = "preferences.minimumFrequency"
    static let maximumFrequency = "preferences.maximumFrequency"
    static let frequencySteps = "preferences.frequencySteps"
    static let maxInstances = "preferences.maxInstances"
    static let maxCPULoad = "preferences.maxCPULoad"
    static let notifyAll = "preferences.notifyAll"
    static let notifyCompletion = "preferences.notifyCompletion"
    static let notifyFailure = "preferences.notifyFailure"
    static let developerMode = "preferences.developerMode"
    static let developerNumCalc = "preferences.developerNumCalc"
    static let developerMeshGrading = "preferences.developerMeshGrading"
    static let developerUV = "preferences.developerUV"
    static let developerPython = "preferences.developerPython"
    static let developerExternalDir = "preferences.developerExternalDir"
    static let developerModelConfig = "preferences.developerModelConfig"
    static let developerModelCheckpoint = "preferences.developerModelCheckpoint"
    static let developerMesh2HRTF = "preferences.developerMesh2HRTF"
    static let workflow = "preferences.workflow"

    struct WorkflowField {
        let key: String
        let config: String
        let rule: String?
    }

    static let workflowFields: [WorkflowField] = [
        .init(key: "full_head_scan", config: "scan_preparation.enabled", rule: nil),
        .init(key: "prepare_left", config: "scan_preparation.prepare_left", rule: "scan.prepare_left"),
        .init(key: "prepare_right", config: "scan_preparation.prepare_right", rule: "scan.prepare_right"),
        .init(key: "require_manual_review", config: "scan_preparation.require_manual_review", rule: nil),
        .init(key: "target_edge_mm", config: "scan_preparation.target_edge_mm", rule: "scan.target_edge"),
        .init(key: "left_margin_mm", config: "scan_preparation.left_margin_mm", rule: "scan.left_margin"),
        .init(key: "right_margin_mm", config: "scan_preparation.right_margin_mm", rule: "scan.right_margin"),
        .init(key: "side_min_mm", config: "scan_preparation.side_min_mm", rule: "scan.side_min"),
        .init(key: "side_max_mm", config: "scan_preparation.side_max_mm", rule: "scan.side_max"),
        .init(key: "source_assignment_face_count", config: "preprocessing.source_assignment_face_count", rule: "mesh2hrtf.microphone_faces"),
        .init(key: "mesh_min_edge_length", config: "preprocessing.mesh_min_edge_length", rule: "mesh_grading.min_edge_length"),
        .init(key: "mesh_max_edge_length", config: "preprocessing.mesh_max_edge_length", rule: "mesh_grading.max_edge_length"),
        .init(key: "mesh_max_error", config: "preprocessing.mesh_max_error", rule: "mesh_grading.max_error"),
        .init(key: "mesh_gamma", config: "preprocessing.mesh_gamma", rule: "mesh_grading.gamma"),
        .init(key: "mesh_gamma_opposite", config: "preprocessing.mesh_gamma_opposite", rule: "mesh_grading.gamma_opposite"),
        .init(key: "head_radius_scale", config: "preprocessing.head_radius_scale", rule: "head.radius_scale"),
        .init(key: "head_width_scale", config: "preprocessing.head_width_scale", rule: "head.width_scale"),
        .init(key: "head_height_scale", config: "preprocessing.head_height_scale", rule: "head.height_scale"),
        .init(key: "head_taper_percent", config: "preprocessing.head_taper_percent", rule: "head.taper_percent"),
        .init(key: "torso_mode", config: "preprocessing.torso_mode", rule: "torso.mode"),
        .init(key: "torso_width_mm", config: "preprocessing.torso_width_mm", rule: "torso.width"),
        .init(key: "torso_depth_mm", config: "preprocessing.torso_depth_mm", rule: "torso.depth"),
        .init(key: "torso_height_mm", config: "preprocessing.torso_height_mm", rule: "torso.height"),

        .init(key: "adaptive_fmm_length", config: "numcalc.adaptive_fmm_length", rule: nil),
        .init(key: "normalize", config: "postprocessing.normalize", rule: nil),
        .init(key: "level_offset_db", config: "postprocessing.level_offset_db", rule: "postprocessing.level_offset"),
        .init(key: "resample_hrirs", config: "postprocessing.resample_hrirs", rule: nil),
        .init(key: "sampling_rate", config: "postprocessing.sampling_rate", rule: "postprocessing.sampling_rate"),
        .init(key: "spatial_upsampling", config: "postprocessing.spatial_upsampling", rule: nil),
        .init(key: "spatial_subdivisions", config: "postprocessing.spatial_subdivisions", rule: "postprocessing.spatial_subdivisions"),
        .init(key: "spatial_normalize", config: "postprocessing.spatial_normalize", rule: nil)
    ]


    static let workflowFlagRules: Set<String> = ["scan.prepare_left", "scan.prepare_right"]

    static func migrateHeadSettings() throws {
        guard let text = UserDefaults.standard.string(forKey: workflow), HeadGeometrySettings.needsHeadSettingsMigration(text) else { return }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let migrated = try HeadGeometrySettings.migrateHeadState(object)
        let data = try JSONSerialization.data(withJSONObject: migrated, options: .sortedKeys)
        let backup = workflow + ".head-shape-compat-backup"
        if UserDefaults.standard.string(forKey: backup) == nil { UserDefaults.standard.set(text, forKey: backup) }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: workflow)
    }

    static var storedWorkflow: [String: Any] {
        guard let text = UserDefaults.standard.string(forKey: workflow),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        return object
    }

    static func storeWorkflow(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: workflow)
    }

    static func workflowText(_ field: WorkflowField, in stored: [String: Any] = storedWorkflow) -> String {
        switch stored[field.key] {
        case let text as String: return text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.stringValue
        default: return SettingsCatalog.text(field.config)
        }
    }

    static func workflowFlag(_ field: WorkflowField, in stored: [String: Any] = storedWorkflow) -> Bool {
        (stored[field.key] as? Bool) ?? SettingsCatalog.flag(field.config)
    }

    static func workflowFormValues(_ stored: [String: Any] = storedWorkflow) -> [String: String] {
        var values = ["scan.enabled": "true"]
        for key in ["normalize", "resample_hrirs", "spatial_upsampling"] {
            if let field = workflowFields.first(where: { $0.key == key }) {
                values["postprocessing." + key] = String(workflowFlag(field, in: stored))
            }
        }
        for field in workflowFields {
            guard let rule = field.rule else { continue }
            values[rule] = workflowFlagRules.contains(rule) ? String(workflowFlag(field, in: stored)) : workflowText(field, in: stored)
        }
        return values
    }

    static func workflowPayload() -> [String: Any] {
        let stored = storedWorkflow
        let values = workflowFormValues(stored)
        var payload: [String: Any] = [:]
        if let method = stored["ear_model_method"] as? String { payload["ear_model_method"] = method }
        if let model = stored["inference_model"] as? String { payload["inference_model"] = model }
        for field in workflowFields {
            guard stored[field.key] != nil else { continue }
            guard let rule = field.rule, !workflowFlagRules.contains(rule) else {
                payload[field.key] = workflowFlag(field, in: stored)
                continue
            }
            let text = workflowText(field, in: stored).trimmingCharacters(in: .whitespacesAndNewlines)
            guard SettingsCatalog.check(values, id: rule) == nil else { continue }
            if field.key == "torso_mode" { payload[field.key] = text; continue }
            payload[field.key] = Int(text).map { $0 as Any } ?? Double(text).map { $0 as Any }
        }
        return payload.compactMapValues { $0 }
    }

    static var developerModel: (config: String, checkpoint: String)? {
        guard let config = developerOverride(developerModelConfig),
              let checkpoint = developerOverride(developerModelCheckpoint) else { return nil }
        return (config, checkpoint)
    }

    static func int(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(max(defaults.integer(forKey: key), range.lowerBound), range.upperBound)
    }

    static func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func notificationEnabled(_ key: String) -> Bool {
        enabled(notifyAll) && enabled(key)
    }

    static func developerOverride(_ key: String) -> String? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: developerMode),
              let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return (value as NSString).expandingTildeInPath
    }

    static func effectiveEnvironment(_ base: EnvironmentConfig) -> EnvironmentConfig {
        var environment = base
        if let value = developerOverride(developerNumCalc) { environment.numcalcExecutable = value }
        if let value = developerOverride(developerMeshGrading) { environment.meshGradingExecutable = value }
        if let value = developerOverride(developerUV) {
            environment.uvExecutable = value
            environment.uvIsExplicit = true
        }
        if let value = developerOverride(developerExternalDir) { environment.externalDir = value }
        if let value = developerOverride(developerPython) { environment.pythonExecutable = value }
        if let value = developerOverride(developerMesh2HRTF) {
            let nested = URL(fileURLWithPath: value).appendingPathComponent("mesh2hrtf")
            let isRoot = FileManager.default.fileExists(atPath: nested.appendingPathComponent("Mesh2Input/mesh2input.py").path)
            environment.mesh2hrtfPath = isRoot ? nested.path : value
        }
        return environment
    }
}
