using System.Text.Json.Serialization;
namespace Pinna2HRTF.Windows;
class ProjectRecord { public string FolderProvenance { get; set; } = "Unknown"; public string? OwnedFolderIdentity { get; set; } public Guid Id { get; set; } = Guid.NewGuid(); public string Name { get; set; } = ""; public string LeftEar { get; set; } = ""; public string RightEar { get; set; } = ""; public string SaveLocation { get; set; } = ""; public Guid? FolderId { get; set; } public string? PreservedConfigJSON { get; set; } public string? SettingsRevision { get; set; } public InputHandling InputHandling { get; set; } = InputHandling.Copy; public ProjectSettings Settings { get; set; } = new(); [JsonIgnore] public string StatusText { get; set; } = ""; [JsonIgnore] public bool IsRunning { get; set; } }
class ProjectSettings {
    public string? EarModelMethod { get; set; }
    public void SelectEarModel(string method) {
        if (method is not ("mesh2ppm" or "manual" or "none")) throw new ArgumentOutOfRangeException(nameof(method));
        EarModelMethod = method;
        Inference.UsePredictionsForPreprocessing = method == "mesh2ppm";
        ManualPPM.Enabled = method == "manual";
    }
 public AcousticTorsoSettings? AcousticTorso { get; set; } public ManualPPMSettings ManualPPM { get; set; } = new(); public InferenceSettings Inference { get; set; } = new(); public PreprocessingSettings Preprocessing { get; set; } = new(); public NumCalcSettings NumCalc { get; set; } = new(); public PostprocessingSettings? Postprocessing { get; set; } = new(); public ScanPreparationSettings ScanPreparation { get; set; } = new(); }
class ScanPreparationSettings {
    public string? IndividualLeftEdit { get; set; }
    public string? IndividualRightEdit { get; set; }
    public string? EarEdit(string side) => Enabled ? (side == "left" ? ReviewedLeft : ReviewedRight) : (side == "left" ? IndividualLeftEdit : IndividualRightEdit);
    public void SetEarEdit(string side, string? path) {
        if (Enabled) { if (side == "left") ReviewedLeft = path; else ReviewedRight = path; }
        else if (side == "left") IndividualLeftEdit = path; else IndividualRightEdit = path;
    }
 public bool Enabled { get; set; } public string ScanPath { get; set; } = ""; public string OriginalScanPath { get; set; } = ""; public bool PrepareLeft { get; set; } = SettingsCatalog.Flag("scan_preparation.prepare_left"); public bool PrepareRight { get; set; } = SettingsCatalog.Flag("scan_preparation.prepare_right"); public string RotationDegrees { get; set; } = SettingsCatalog.Text("scan_preparation.rotation_degrees"); public string TargetEdgeMM { get; set; } = SettingsCatalog.Text("scan_preparation.target_edge_mm"); public string LeftMarginMM { get; set; } = SettingsCatalog.Text("scan_preparation.left_margin_mm"); public string RightMarginMM { get; set; } = SettingsCatalog.Text("scan_preparation.right_margin_mm"); public string SideMinMM { get; set; } = SettingsCatalog.Text("scan_preparation.side_min_mm"); public string SideMaxMM { get; set; } = SettingsCatalog.Text("scan_preparation.side_max_mm"); public bool RequireManualReview { get; set; } public string? ReviewedLeft { get; set; } public string? ReviewedRight { get; set; } }
class InferenceSettings { public string ModelConfig { get; set; } = ""; public string ModelCheckpoint { get; set; } = ""; public string TargetLeftFolder { get; set; } = SettingsCatalog.Text("inference.target_left_folder"); public string TargetRightFolder { get; set; } = SettingsCatalog.Text("inference.target_right_folder"); public string PredictionLeftFolder { get; set; } = SettingsCatalog.Text("inference.prediction_left_folder"); public string PredictionRightFolder { get; set; } = SettingsCatalog.Text("inference.prediction_right_folder"); public bool UsePredictionsForPreprocessing { get; set; } = false; }
class PreprocessingSettings { public string MinFrequency { get; set; } = SettingsCatalog.Text("preprocessing.min_frequency"); public string MaxFrequency { get; set; } = SettingsCatalog.Text("preprocessing.max_frequency"); public string FrequencyStepCount { get; set; } = SettingsCatalog.Text("preprocessing.frequency_step_count"); public string? EvaluationGrid { get; set; } public string? EarDistance { get; set; } public string SourceAssignmentFaceCount { get; set; } = SettingsCatalog.Text("preprocessing.source_assignment_face_count"); public string MeshMinEdgeLength { get; set; } = SettingsCatalog.Text("preprocessing.mesh_min_edge_length"); public string MeshMaxEdgeLength { get; set; } = SettingsCatalog.Text("preprocessing.mesh_max_edge_length"); public string MeshMaxError { get; set; } = SettingsCatalog.Text("preprocessing.mesh_max_error"); public string MeshGamma { get; set; } = SettingsCatalog.Text("preprocessing.mesh_gamma"); public string MeshGammaOpposite { get; set; } = SettingsCatalog.Text("preprocessing.mesh_gamma_opposite"); public string HeadRadiusScale { get; set; } = SettingsCatalog.Text("preprocessing.head_radius_scale"); public string HeadWidthScale { get; set; } = SettingsCatalog.Text("preprocessing.head_width_scale"); public string HeadHeightScale { get; set; } = SettingsCatalog.Text("preprocessing.head_height_scale"); public string TorsoMode { get; set; } = SettingsCatalog.Text("preprocessing.torso_mode"); public string TorsoWidthMM { get; set; } = SettingsCatalog.Text("preprocessing.torso_width_mm"); public string TorsoDepthMM { get; set; } = SettingsCatalog.Text("preprocessing.torso_depth_mm"); public string TorsoHeightMM { get; set; } = SettingsCatalog.Text("preprocessing.torso_height_mm"); public string HeadTaperPercent { get; set; } = SettingsCatalog.Text("preprocessing.head_taper_percent"); public ManualMicrophonePosition? SourcePositionInputLeft { get; set; } public ManualMicrophonePosition? SourcePositionInputRight { get; set; } }
class ManualMicrophonePosition { public double X { get; set; } public double Y { get; set; } public double Z { get; set; } public string MeshPath { get; set; } = ""; public string MeshIdentity { get; set; } = ""; }
class PostprocessingSettings { public bool SpatialUpsampling { get; set; } = SettingsCatalog.Flag("postprocessing.spatial_upsampling"); public string SpatialSubdivisions { get; set; } = SettingsCatalog.Text("postprocessing.spatial_subdivisions"); public bool SpatialNormalize { get; set; } = SettingsCatalog.Flag("postprocessing.spatial_normalize"); public string? OutputFolder { get; set; } public bool Normalize { get; set; } = SettingsCatalog.Flag("postprocessing.normalize"); public string LevelOffsetDB { get; set; } = SettingsCatalog.Text("postprocessing.level_offset_db");  public bool ResampleHrirs { get; set; } = SettingsCatalog.Flag("postprocessing.resample_hrirs"); public string SamplingRate { get; set; } = SettingsCatalog.Text("postprocessing.sampling_rate"); }
class NumCalcSettings { public string MaxInstances { get; set; } = SettingsCatalog.Text("numcalc.max_instances"); public string MaxCpuLoad { get; set; } = SettingsCatalog.Text("numcalc.max_cpu_load"); public bool AdaptiveFmmLength { get; set; } = SettingsCatalog.Flag("numcalc.adaptive_fmm_length"); }

class ManualPPMSettings
{
    public bool Enabled { get; set; }
    public string? TemplateBlend { get; set; }
    public ManualFit? Left { get; set; }
    public ManualFit? Right { get; set; }
    public ManualFit? For(string side) => side == "left" ? Left : Right;
}
class ManualFit
{
    public string Mesh { get; set; } = "";
    public string Parameters { get; set; } = "";
    public string Blend { get; set; } = "";
    public string Source { get; set; } = "";
    public string SourceIdentity { get; set; } = "";
}

class EnvironmentConfig { public string UvExecutable { get; set; } = ""; public string NumCalcExecutable { get; set; } = ""; public string MeshGradingExecutable { get; set; } = ""; public string ExternalDir { get; set; } = ""; public string? Mesh2HrtfPath { get; set; } [JsonIgnore] public string EffectiveMesh2HrtfPath => Mesh2HrtfPath ?? Path.Combine(ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf"); [JsonIgnore] public bool IsEmpty => string.IsNullOrWhiteSpace(NumCalcExecutable) && string.IsNullOrWhiteSpace(MeshGradingExecutable) && string.IsNullOrWhiteSpace(ExternalDir); }

enum InputHandling { Copy, Reference }
