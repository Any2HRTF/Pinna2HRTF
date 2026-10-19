import Foundation

enum Stage: String, CaseIterable, Identifiable, Codable {
    case scanPreparation = "scan-preparation"
    case inference
    case preprocessing
    case numcalc
    case postprocessing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanPreparation: "Scan Preparation"
        case .inference: "Mesh2PPM Inference"
        case .preprocessing: "Preprocessing"
        case .numcalc: "NumCalc"
        case .postprocessing: "Postprocess"
        }
    }

    var systemImage: String {
        switch self {
        case .scanPreparation: "bandage"
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
    case stopped
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
    var isPressure: Bool { url.lastPathComponent == "NC.inp" }
    var isMesh: Bool { ["stl", "ply"].contains(url.pathExtension.lowercased()) }
    var isImage: Bool { ["jpeg", "jpg", "pdf", "png"].contains(url.pathExtension.lowercased()) }
    var systemImage: String { isPressure ? "waveform.path" : isImage ? "photo" : "cube" }
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

struct ScanPreparationSettings: Codable, Equatable {
    var enabled = false
    var scanPath = ""
    var rotationDegrees = "0"
    var originalScanPath: String?
    var requireManualReview: Bool?
    var reviewedLeftPath: String?
    var reviewedRightPath: String?
    var prepareLeft = true
    var prepareRight = true
    var targetEdgeMM = "0.75"
    var leftMarginMM = "20"
    var rightMarginMM = "10"
    var sideMinMM = "30"
    var sideMaxMM = "110"
}

struct InferenceSettings: Codable, Equatable {
    var modelConfig: String
    var modelCheckpoint: String
    var targetLeftFolder = "Input/Left"
    var targetRightFolder = "Input/Right"
    var predictionLeftFolder = "Intermediates/Left"
    var predictionRightFolder = "Intermediates/Right"
    var usePredictionsForPreprocessing = false
}

struct ManualPPMFittingSettings: Codable, Equatable {
    var useForPreprocessing = false
    var templateBlendPath: String?
    var leftMeshPath: String?
    var rightMeshPath: String?
    var leftParametersPath: String?
    var rightParametersPath: String?
    var leftBlendPath: String?
    var rightBlendPath: String?
    var leftSourcePath: String?
    var rightSourcePath: String?
    var leftSourceIdentity: String?
    var rightSourceIdentity: String?

    func meshPath(for side: EarSide) -> String? { side == .left ? leftMeshPath : rightMeshPath }
    func parametersPath(for side: EarSide) -> String? { side == .left ? leftParametersPath : rightParametersPath }
    func blendPath(for side: EarSide) -> String? { side == .left ? leftBlendPath : rightBlendPath }
    func sourcePath(for side: EarSide) -> String? { side == .left ? leftSourcePath : rightSourcePath }
    func sourceIdentity(for side: EarSide) -> String? { side == .left ? leftSourceIdentity : rightSourceIdentity }

    mutating func setFit(meshPath: String, parametersPath: String, blendPath: String, sourcePath: String,
                         sourceIdentity: String, for side: EarSide) {
        if side == .left {
            leftMeshPath = meshPath
            leftParametersPath = parametersPath
            leftBlendPath = blendPath
            leftSourcePath = sourcePath
            leftSourceIdentity = sourceIdentity
        } else {
            rightMeshPath = meshPath
            rightParametersPath = parametersPath
            rightBlendPath = blendPath
            rightSourcePath = sourcePath
            rightSourceIdentity = sourceIdentity
        }
    }
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
    var resampleHrirs = false
    var samplingRate = "48000"
    var outputFolder: String?

    enum CodingKeys: String, CodingKey {
        case normalize, levelOffsetDB, resampleHrirs, samplingRate, outputFolder
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        normalize = try values.decodeIfPresent(Bool.self, forKey: .normalize) ?? true
        levelOffsetDB = try values.decodeIfPresent(String.self, forKey: .levelOffsetDB) ?? "-30"
        resampleHrirs = try values.decodeIfPresent(Bool.self, forKey: .resampleHrirs) ?? false
        samplingRate = try values.decodeIfPresent(String.self, forKey: .samplingRate) ?? "48000"
        outputFolder = try values.decodeIfPresent(String.self, forKey: .outputFolder)
    }

    var normalizedSamplingRate: Int {
        guard let rate = Int(samplingRate.trimmingCharacters(in: .whitespacesAndNewlines)), rate > 0, rate % 10 == 0 else { return 48000 }
        return rate
    }
}

struct ProjectSettings: Codable, Equatable {
    var inference: InferenceSettings
    var manualPPMFitting = ManualPPMFittingSettings()
    var scanPreparation: ScanPreparationSettings?
    var preprocessing = PreprocessingSettings()
    var numcalc = NumCalcSettings()
    var postprocessing: PostprocessingSettings? = PostprocessingSettings()

    private enum CodingKeys: String, CodingKey {
        case inference, manualPPMFitting, scanPreparation, preprocessing, numcalc, postprocessing
    }

    init(inference: InferenceSettings, manualPPMFitting: ManualPPMFittingSettings = ManualPPMFittingSettings(),
         scanPreparation: ScanPreparationSettings? = nil, preprocessing: PreprocessingSettings = PreprocessingSettings(),
         numcalc: NumCalcSettings = NumCalcSettings(), postprocessing: PostprocessingSettings? = PostprocessingSettings()) {
        self.inference = inference
        self.manualPPMFitting = manualPPMFitting
        self.scanPreparation = scanPreparation
        self.preprocessing = preprocessing
        self.numcalc = numcalc
        self.postprocessing = postprocessing
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inference = try values.decode(InferenceSettings.self, forKey: .inference)
        manualPPMFitting = try values.decodeIfPresent(ManualPPMFittingSettings.self, forKey: .manualPPMFitting) ?? ManualPPMFittingSettings()
        scanPreparation = try values.decodeIfPresent(ScanPreparationSettings.self, forKey: .scanPreparation)
        preprocessing = try values.decodeIfPresent(PreprocessingSettings.self, forKey: .preprocessing) ?? PreprocessingSettings()
        numcalc = try values.decodeIfPresent(NumCalcSettings.self, forKey: .numcalc) ?? NumCalcSettings()
        postprocessing = try values.decodeIfPresent(PostprocessingSettings.self, forKey: .postprocessing) ?? PostprocessingSettings()
    }
}

struct ProjectRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var leftEar: String
    var rightEar: String
    var saveLocation: String
    var inputHandling: InputHandling = .copy
    var folderID: UUID?
    var preservedConfigJSON: String?
    var stageOutcomes: [String: StageState]?
    var settings: ProjectSettings
}

extension ProjectRecord {
    var scanPreparation: ScanPreparationSettings { settings.scanPreparation ?? ScanPreparationSettings() }
    var pipelineLeftEar: String { pipelineEar(for: .left) }
    var pipelineRightEar: String { pipelineEar(for: .right) }

    func pipelineEar(for side: EarSide, inspection: ArtifactScanner.Inspection = .init()) -> String {
        guard scanPreparation.enabled else { return side == .left ? leftEar : rightEar }
        return ArtifactScanner.preparedEarURL(for: side, in: self, inspection: inspection)?.path ?? ""
    }
}

struct ProjectFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isExpanded = true
}

struct ProjectRegistry: Codable, Equatable {
    var projects: [ProjectRecord]
    var selectedProjectID: UUID?
    var environment: EnvironmentConfig
    var folders: [ProjectFolder] = []

    init(projects: [ProjectRecord], selectedProjectID: UUID?, environment: EnvironmentConfig, folders: [ProjectFolder] = []) {
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.environment = environment
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case projects, selectedProjectID, environment, folders
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decode([ProjectRecord].self, forKey: .projects)
        selectedProjectID = try values.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        environment = try values.decode(EnvironmentConfig.self, forKey: .environment)
        folders = try values.decodeIfPresent([ProjectFolder].self, forKey: .folders) ?? []
        let folderIDs = Set(folders.map(\.id))
        for index in projects.indices {
            if let id = projects[index].folderID, !folderIDs.contains(id) {
                projects[index].folderID = nil
            }
        }
    }
}
