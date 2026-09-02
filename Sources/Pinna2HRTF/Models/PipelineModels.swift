import Foundation

enum Stage: String, CaseIterable, Identifiable, Codable {
    case inference
    case preprocessing
    case numcalc
    case postprocessing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inference: "Mesh2PPM Inference"
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
    case skipped
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

enum EarSide: String, CaseIterable, Identifiable, Codable {
    case left
    case right

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ManualMicrophonePosition: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    var meshPath: String
    var meshIdentity: String
}

struct Artifact: Identifiable, Hashable {
    let title: String
    let url: URL

    var id: String { url.path }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    var isMesh: Bool { ["stl", "ply"].contains(url.pathExtension.lowercased()) }
    var isImage: Bool { ["jpeg", "jpg", "pdf", "png"].contains(url.pathExtension.lowercased()) }
    var systemImage: String { isImage ? "photo" : "cube" }
}

struct ViewerCameraState: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double
}

struct ProjectViewerState: Codable, Equatable {
    var selectedArtifactPath: String?
    var cameraByArtifact: [String: ViewerCameraState] = [:]
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
    var targetLeftFolder = "Input/Left"
    var targetRightFolder = "Input/Right"
    var predictionLeftFolder = "Intermediates/Left"
    var predictionRightFolder = "Intermediates/Right"
    var usePredictionsForPreprocessing = true
}

struct PreprocessingSettings: Codable, Equatable {
    var minFrequency = "0"
    var maxFrequency = "24000"
    var frequencyStepCount = "129"
    var evaluationGrid: String?
    var headRadius: String?
    var useCustomHeadRadius: Bool?
    var meshMinEdgeLength = "0.5"
    var meshMaxEdgeLength = "10.0"
    var meshMaxError = "0.5"
    var meshGamma = "0.2"
    var meshGammaOpposite = "0.1"
    var skipMeshGrading: Bool?
    var sourceAssignmentFaceCount: String? = "6"
    var sourcePositionInputLeft: ManualMicrophonePosition?
    var sourcePositionInputRight: ManualMicrophonePosition?
}

struct NumCalcSettings: Codable, Equatable {
    var maxInstances = "1"
    var maxCPULoad = "90"
    var adaptiveFmmLength = true

    enum CodingKeys: String, CodingKey {
        case maxInstances
        case maxCPULoad
        case adaptiveFmmLength
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxInstances = try container.decodeIfPresent(String.self, forKey: .maxInstances) ?? "1"
        maxCPULoad = try container.decodeIfPresent(String.self, forKey: .maxCPULoad) ?? "90"
        adaptiveFmmLength = try container.decodeIfPresent(Bool.self, forKey: .adaptiveFmmLength) ?? true
    }
}

struct PostprocessingSettings: Codable, Equatable {
    var normalize = true
    var levelOffsetDB = "-30"
}

struct ProjectSettings: Codable, Equatable {
    var inference: InferenceSettings
    var preprocessing = PreprocessingSettings()
    var numcalc = NumCalcSettings()
    var postprocessing: PostprocessingSettings? = PostprocessingSettings()
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
