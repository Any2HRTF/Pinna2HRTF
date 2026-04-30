import Foundation

enum Stage: String, CaseIterable, Identifiable, Codable {
    case inference
    case preprocessing
    case numcalc
    case postprocessing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inference: "Inference"
        case .preprocessing: "Preprocessing"
        case .numcalc: "NumCalc"
        case .postprocessing: "Postprocess"
        }
    }

    var systemImage: String {
        switch self {
        case .inference: "wand.and.stars"
        case .preprocessing: "scissors"
        case .numcalc: "cpu"
        case .postprocessing: "shippingbox"
        }
    }
}

enum StageState: String, Codable {
    case ready
    case running
    case failed
    case done
}

enum InputHandling: String, CaseIterable, Identifiable, Codable {
    case copy
    case reference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: "Copy inputs"
        case .reference: "Reference inputs"
        }
    }
}

struct Artifact: Identifiable, Hashable {
    let title: String
    let url: URL

    var id: String { url.path }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

struct EnvironmentConfig: Codable, Equatable {
    var uvExecutable: String
    var numcalcExecutable: String
    var meshGradingExecutable: String
    var externalDir: String
}

struct InferenceSettings: Codable, Equatable {
    var modelConfig: String
    var modelCheckpoint: String
    var targetLeftFolder = "Target STL Left"
    var targetRightFolder = "Target STL Right"
    var predictionLeftFolder = "Prediction STL Left"
    var predictionRightFolder = "Prediction STL Right"
    var usePredictionsForPreprocessing = true
}

struct PreprocessingSettings: Codable, Equatable {
    var minFrequency = "0"
    var maxFrequency = "24000"
    var frequencyStepCount = "129"
    var meshMinEdgeLength = "0.5"
    var meshMaxEdgeLength = "10.0"
    var meshMaxError = "0.5"
    var meshGammaLeft = "0.15"
    var meshGammaRight = "0.2"
}

struct NumCalcSettings: Codable, Equatable {
    var maxInstances = "1"
    var maxCPULoad = "90"
}

struct ProjectSettings: Codable, Equatable {
    var inference: InferenceSettings
    var preprocessing = PreprocessingSettings()
    var numcalc = NumCalcSettings()
}

struct ProjectRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var leftEar: String
    var rightEar: String
    var saveLocation: String
    var inputHandling: InputHandling = .copy
    var settings: ProjectSettings
}

struct ProjectRegistry: Codable, Equatable {
    var projects: [ProjectRecord]
    var selectedProjectID: UUID?
    var environment: EnvironmentConfig
}
