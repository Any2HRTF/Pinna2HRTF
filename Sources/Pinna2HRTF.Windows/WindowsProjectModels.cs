using System.Text.Json.Serialization;
namespace Pinna2HRTF.Windows;
class ProjectRecord { public string FolderProvenance { get; set; } = "Unknown"; public string? OwnedFolderIdentity { get; set; } public Guid Id { get; set; } = Guid.NewGuid(); public string Name { get; set; } = ""; public string LeftEar { get; set; } = ""; public string RightEar { get; set; } = ""; public string SaveLocation { get; set; } = ""; public Guid? FolderId { get; set; } public string? PreservedConfigJSON { get; set; } public InputHandling InputHandling { get; set; } = InputHandling.Copy; public ProjectSettings Settings { get; set; } = new(); [JsonIgnore] public string StatusText { get; set; } = ""; [JsonIgnore] public bool IsRunning { get; set; } }
class ProjectSettings { public ManualPPMSettings ManualPPM { get; set; } = new(); public InferenceSettings Inference { get; set; } = new(); public PreprocessingSettings Preprocessing { get; set; } = new(); public NumCalcSettings NumCalc { get; set; } = new(); public PostprocessingSettings? Postprocessing { get; set; } = new(); public ScanPreparationSettings ScanPreparation { get; set; } = new(); }
class ScanPreparationSettings { public bool Enabled { get; set; } public string ScanPath { get; set; } = ""; public string OriginalScanPath { get; set; } = ""; public bool PrepareLeft { get; set; } = true; public bool PrepareRight { get; set; } = true; public string RotationDegrees { get; set; } = "0"; public string TargetEdgeMM { get; set; } = "0.75"; public string LeftMarginMM { get; set; } = "20"; public string RightMarginMM { get; set; } = "10"; public string SideMinMM { get; set; } = "30"; public string SideMaxMM { get; set; } = "110"; public bool RequireManualReview { get; set; } public string? ReviewedLeft { get; set; } public string? ReviewedRight { get; set; } }
class InferenceSettings { public string ModelConfig { get; set; } = ""; public string ModelCheckpoint { get; set; } = ""; public string TargetLeftFolder { get; set; } = "Input/Left"; public string TargetRightFolder { get; set; } = "Input/Right"; public string PredictionLeftFolder { get; set; } = "Intermediates/Left"; public string PredictionRightFolder { get; set; } = "Intermediates/Right"; public bool UsePredictionsForPreprocessing { get; set; } = false; }
class PreprocessingSettings { public string MinFrequency { get; set; } = "0"; public string MaxFrequency { get; set; } = "24000"; public string FrequencyStepCount { get; set; } = "129"; public string? EvaluationGrid { get; set; } public string? EarDistance { get; set; } public string SourceAssignmentFaceCount { get; set; } = "6"; public string MeshMinEdgeLength { get; set; } = "0.5"; public string MeshMaxEdgeLength { get; set; } = "10.0"; public string MeshMaxError { get; set; } = "0.5"; public string MeshGamma { get; set; } = "0.2"; public string MeshGammaOpposite { get; set; } = "0.1"; public ManualMicrophonePosition? SourcePositionInputLeft { get; set; } public ManualMicrophonePosition? SourcePositionInputRight { get; set; } }
class ManualMicrophonePosition { public double X { get; set; } public double Y { get; set; } public double Z { get; set; } public string MeshPath { get; set; } = ""; public string MeshIdentity { get; set; } = ""; }
class PostprocessingSettings { public bool SpatialUpsampling { get; set; } public string SpatialSubdivisions { get; set; } = "3"; public bool SpatialNormalize { get; set; } public string? OutputFolder { get; set; } public bool Normalize { get; set; } = true; public string LevelOffsetDB { get; set; } = "-30";  public bool ResampleHrirs { get; set; } = false; public string SamplingRate { get; set; } = "48000"; }
class NumCalcSettings { public string MaxInstances { get; set; } = "1"; public string MaxCpuLoad { get; set; } = "90"; public bool AdaptiveFmmLength { get; set; } = true; }

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

class EnvironmentConfig { public string UvExecutable { get; set; } = ""; public string NumCalcExecutable { get; set; } = ""; public string MeshGradingExecutable { get; set; } = ""; public string ExternalDir { get; set; } = ""; [JsonIgnore] public bool IsEmpty => string.IsNullOrWhiteSpace(NumCalcExecutable) && string.IsNullOrWhiteSpace(MeshGradingExecutable) && string.IsNullOrWhiteSpace(ExternalDir); }

enum InputHandling { Copy, Reference }
