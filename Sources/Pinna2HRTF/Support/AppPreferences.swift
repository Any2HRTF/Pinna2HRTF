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
    static let appearance = "preferences.appearance"
    static let developerMode = "preferences.developerMode"
    static let developerNumCalc = "preferences.developerNumCalc"
    static let developerMeshGrading = "preferences.developerMeshGrading"
    static let developerUV = "preferences.developerUV"
    static let developerPython = "preferences.developerPython"
    static let developerExternalDir = "preferences.developerExternalDir"

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
        return environment
    }
}
