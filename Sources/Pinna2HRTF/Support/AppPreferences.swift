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
    static let notifyCompletion = "preferences.notifyCompletion"
    static let notifyFailure = "preferences.notifyFailure"
    static let appearance = "preferences.appearance"

    static func int(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(max(defaults.integer(forKey: key), range.lowerBound), range.upperBound)
    }

    static func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
