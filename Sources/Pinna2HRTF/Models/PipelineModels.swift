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
        case .scanPreparation: "Scan preparation"
        case .inference: "Mesh2PPM inference"
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
    var cachedExists: Bool? = nil
    var exists: Bool { cachedExists ?? FileManager.default.fileExists(atPath: url.path) }
    var isPressure: Bool { url.lastPathComponent == "NC.inp" }
    var isMesh: Bool { ["stl", "ply"].contains(url.pathExtension.lowercased()) }
    var isImage: Bool { ["jpeg", "jpg", "pdf", "png"].contains(url.pathExtension.lowercased()) }
    var systemImage: String { isPressure ? "waveform.path" : isImage ? "photo" : "cube" }
}

struct ViewerCameraState: Codable, Equatable {
    var target: [Double]? = nil
    var orientation: [Double]? = nil
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
    var pythonExecutable: String?
    var uvIsExplicit: Bool?
    var mesh2hrtfPath: String?

    var effectiveMesh2HRTFPath: String {
        mesh2hrtfPath ?? URL(fileURLWithPath: externalDir).appendingPathComponent("src/Mesh2HRTF/mesh2hrtf").path
    }
}

struct ScanPreparationSettings: Codable, Equatable {
    var enabled = false
    var scanPath = ""
    var rotationDegrees = SettingsCatalog.text("scan_preparation.rotation_degrees")
    var originalScanPath: String?
    var requireManualReview: Bool?
    var individualLeftEdit: String?
    var individualRightEdit: String?
    func earEdit(_ side: EarSide) -> String? {
        enabled ? (side == .left ? reviewedLeftPath : reviewedRightPath) : (side == .left ? individualLeftEdit : individualRightEdit)
    }
    mutating func setEarEdit(_ path: String?, side: EarSide) {
        if enabled {
            if side == .left { reviewedLeftPath = path } else { reviewedRightPath = path }
        } else if side == .left { individualLeftEdit = path } else { individualRightEdit = path }
    }
    var reviewedLeftPath: String?
    var reviewedRightPath: String?
    var prepareLeft = SettingsCatalog.flag("scan_preparation.prepare_left")
    var prepareRight = SettingsCatalog.flag("scan_preparation.prepare_right")
    var targetEdgeMM = SettingsCatalog.text("scan_preparation.target_edge_mm")
    var leftMarginMM = SettingsCatalog.text("scan_preparation.left_margin_mm")
    var rightMarginMM = SettingsCatalog.text("scan_preparation.right_margin_mm")
    var sideMinMM = SettingsCatalog.text("scan_preparation.side_min_mm")
    var sideMaxMM = SettingsCatalog.text("scan_preparation.side_max_mm")
}

struct InferenceSettings: Codable, Equatable {
    var modelConfig: String
    var modelCheckpoint: String
    var targetLeftFolder = SettingsCatalog.text("inference.target_left_folder")
    var targetRightFolder = SettingsCatalog.text("inference.target_right_folder")
    var predictionLeftFolder = SettingsCatalog.text("inference.prediction_left_folder")
    var predictionRightFolder = SettingsCatalog.text("inference.prediction_right_folder")
    var usePredictionsForPreprocessing = false
}

struct ManualPPMFittingSettings: Codable, Equatable {
    var selectedMethod: EarModelMethod?
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

    mutating func reconcileAfterOutputReset() {
        for side in EarSide.allCases {
            let files = [meshPath(for: side), parametersPath(for: side)]
            guard files.contains(where: { $0.map { !FileManager.default.fileExists(atPath: $0) } ?? true }) else { continue }
            if side == .left {
                leftMeshPath = nil; leftParametersPath = nil; leftBlendPath = nil
                leftSourcePath = nil; leftSourceIdentity = nil
            } else {
                rightMeshPath = nil; rightParametersPath = nil; rightBlendPath = nil
                rightSourcePath = nil; rightSourceIdentity = nil
            }
        }
        if let templateBlendPath, !FileManager.default.fileExists(atPath: templateBlendPath) {
            self.templateBlendPath = nil
        }
    }

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
    var minFrequency = SettingsCatalog.text("preprocessing.min_frequency")
    var maxFrequency = SettingsCatalog.text("preprocessing.max_frequency")
    var frequencyStepCount = SettingsCatalog.text("preprocessing.frequency_step_count")
    var evaluationGrid: String?
    var earDistance: String?
    var meshMinEdgeLength = SettingsCatalog.text("preprocessing.mesh_min_edge_length")
    var meshMaxEdgeLength = SettingsCatalog.text("preprocessing.mesh_max_edge_length")
    var meshMaxError = SettingsCatalog.text("preprocessing.mesh_max_error")
    var meshGamma = SettingsCatalog.text("preprocessing.mesh_gamma")
    var meshGammaOpposite = SettingsCatalog.text("preprocessing.mesh_gamma_opposite")
    var skipMeshGrading: Bool?
    var sourceAssignmentFaceCount: String? = SettingsCatalog.text("preprocessing.source_assignment_face_count")
    var sourcePositionInputLeft: ManualMicrophonePosition?
    var sourcePositionInputRight: ManualMicrophonePosition?
}

struct NumCalcSettings: Codable, Equatable {
    var maxInstances = SettingsCatalog.text("numcalc.max_instances")
    var maxCPULoad = SettingsCatalog.text("numcalc.max_cpu_load")
    var adaptiveFmmLength = SettingsCatalog.flag("numcalc.adaptive_fmm_length")

    enum CodingKeys: String, CodingKey {
        case maxInstances
        case maxCPULoad
        case adaptiveFmmLength
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .maxInstances) { maxInstances = value }
        if let value = try container.decodeIfPresent(String.self, forKey: .maxCPULoad) { maxCPULoad = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .adaptiveFmmLength) { adaptiveFmmLength = value }
    }
}

struct PostprocessingSettings: Codable, Equatable {
    var normalize = SettingsCatalog.flag("postprocessing.normalize")
    var levelOffsetDB = SettingsCatalog.text("postprocessing.level_offset_db")
    var resampleHrirs = SettingsCatalog.flag("postprocessing.resample_hrirs")
    var samplingRate = SettingsCatalog.text("postprocessing.sampling_rate")
    var outputFolder: String?
    var spatialUpsampling = SettingsCatalog.flag("postprocessing.spatial_upsampling")
    var spatialSubdivisions = Int(SettingsCatalog.text("postprocessing.spatial_subdivisions")) ?? 0
    var spatialNormalize = SettingsCatalog.flag("postprocessing.spatial_normalize")
    var matlabExecutable: String?
    var amtPath: String?

    enum CodingKeys: String, CodingKey {
        case normalize, levelOffsetDB, resampleHrirs, samplingRate, outputFolder
        case spatialUpsampling, spatialSubdivisions, spatialNormalize, matlabExecutable, amtPath
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try values.decodeIfPresent(Bool.self, forKey: .normalize) { normalize = value }
        if let value = try values.decodeIfPresent(String.self, forKey: .levelOffsetDB) { levelOffsetDB = value }
        if let value = try values.decodeIfPresent(Bool.self, forKey: .resampleHrirs) { resampleHrirs = value }
        if let value = try values.decodeIfPresent(String.self, forKey: .samplingRate) { samplingRate = value }
        outputFolder = try values.decodeIfPresent(String.self, forKey: .outputFolder)
        if let value = try values.decodeIfPresent(Bool.self, forKey: .spatialUpsampling) { spatialUpsampling = value }
        if let value = try values.decodeIfPresent(Int.self, forKey: .spatialSubdivisions) { spatialSubdivisions = value }
        if let value = try values.decodeIfPresent(Bool.self, forKey: .spatialNormalize) { spatialNormalize = value }
        matlabExecutable = try values.decodeIfPresent(String.self, forKey: .matlabExecutable)
        amtPath = try values.decodeIfPresent(String.self, forKey: .amtPath)
    }

    var normalizedSamplingRate: Int {
        if ProjectValidation.fieldMessage("postprocessing.sampling_rate", text: samplingRate) == nil, let rate = Int(samplingRate.trimmingCharacters(in: .whitespacesAndNewlines)) { return rate }
        return Int(SettingsCatalog.text("postprocessing.sampling_rate")) ?? 0
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
    var settingsRevision: String?
    var automaticMicrophoneSides: [EarSide]?
    var stageOutcomes: [String: StageState]?
    var settings: ProjectSettings
}

extension ProjectRecord {
    func protectedOutputInputs(resettingProjectID: UUID? = nil) -> [String] {
        let scan = scanPreparation
        var paths = [leftEar, rightEar, scan.originalScanPath ?? "", settings.preprocessing.evaluationGrid ?? ""]
        let alignedScan = URL(fileURLWithPath: saveLocation).appendingPathComponent("MeshEdits/AlignedScan.ply").standardizedFileURL.path
        let canResetAlignment = id == resettingProjectID && !(scan.originalScanPath ?? "").isEmpty
            && URL(fileURLWithPath: scan.scanPath).standardizedFileURL.path == alignedScan
            && scan.originalScanPath != scan.scanPath
        if !canResetAlignment { paths.append(scan.scanPath) }
        if id != resettingProjectID {
            paths += [scan.reviewedLeftPath ?? "", scan.reviewedRightPath ?? "", scan.individualLeftEdit ?? "", scan.individualRightEdit ?? ""]
            let fitting = settings.manualPPMFitting
            paths += [fitting.leftMeshPath ?? "", fitting.rightMeshPath ?? "",
                      fitting.leftParametersPath ?? "", fitting.rightParametersPath ?? "",
                      fitting.leftBlendPath ?? "", fitting.rightBlendPath ?? "", fitting.templateBlendPath ?? ""]
        }
        return paths.filter { !$0.isEmpty && $0 != "Default" && $0 != Defaults.evaluationGrid }
    }

    mutating func reconcileAfterOutputReset() {
        settings.manualPPMFitting.reconcileAfterOutputReset()
        if var scan = settings.scanPreparation {
            if let path = scan.individualLeftEdit, !FileManager.default.fileExists(atPath: path) { scan.individualLeftEdit = nil }
            if let path = scan.individualRightEdit, !FileManager.default.fileExists(atPath: path) { scan.individualRightEdit = nil }
            if let path = scan.reviewedLeftPath, !FileManager.default.fileExists(atPath: path) { scan.reviewedLeftPath = nil }
            if let path = scan.reviewedRightPath, !FileManager.default.fileExists(atPath: path) { scan.reviewedRightPath = nil }
            if !FileManager.default.fileExists(atPath: scan.scanPath), let original = scan.originalScanPath {
                scan.scanPath = original
                scan.originalScanPath = nil
            }
            settings.scanPreparation = scan
        }
    }

    var scanPreparation: ScanPreparationSettings { settings.scanPreparation ?? ScanPreparationSettings() }
    var pipelineLeftEar: String { pipelineEar(for: .left) }
    var pipelineRightEar: String { pipelineEar(for: .right) }

    func pipelineEar(for side: EarSide, inspection: ArtifactScanner.Inspection = .init()) -> String {
        guard scanPreparation.enabled else { return ArtifactScanner.sourceEar(for: self, side: side, inspection: inspection)?.path ?? "" }
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
