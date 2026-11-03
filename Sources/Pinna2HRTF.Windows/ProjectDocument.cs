using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Pinna2HRTF.Windows;

// A preserved, validated document is the base. Only fields owned by desktop
// controls are replaced; supported YAML-only settings survive every app save.
internal static class ProjectDocument
{
    internal static double Number(string value) => HeadGeometry.Parse(value);
    internal static bool SameJson(JsonNode? left,JsonNode? right)
    {
        using var a=JsonDocument.Parse(left?.ToJsonString()??"null");using var b=JsonDocument.Parse(right?.ToJsonString()??"null");
        static bool Same(JsonElement x,JsonElement y)
        {
            if(x.ValueKind==JsonValueKind.Number&&y.ValueKind==JsonValueKind.Number)return x.GetDouble()==y.GetDouble();
            if(x.ValueKind!=y.ValueKind)return false;
            return x.ValueKind switch
            {
                JsonValueKind.Object=>x.EnumerateObject().Count()==y.EnumerateObject().Count()&&x.EnumerateObject().All(p=>y.TryGetProperty(p.Name,out var value)&&Same(p.Value,value)),
                JsonValueKind.Array=>x.GetArrayLength()==y.GetArrayLength()&&x.EnumerateArray().Zip(y.EnumerateArray()).All(pair=>Same(pair.First,pair.Second)),
                JsonValueKind.String=>x.GetString()==y.GetString(),_=>x.ValueKind==y.ValueKind
            };
        }
        return Same(a.RootElement,b.RootElement);
    }
    internal static string? ValidationError(ProjectRecord p)
    {
        try
        {
            var pre=p.Settings.Preprocessing;var scan=p.Settings.ScanPreparation;var post=p.Settings.Postprocessing??new();
            int Integer(string value,string name,int minimum){if(!int.TryParse(value,NumberStyles.Integer,CultureInfo.InvariantCulture,out var n)||n<minimum)throw new InvalidDataException($"{name}: enter a whole number of at least {minimum}.");return n;}
            double Positive(string value,string name,bool zero=false){var n=Number(value);if(zero?n<0:n<=0)throw new InvalidDataException($"{name}: enter a {(zero?"nonnegative":"positive")} number.");return n;}
            var min=Integer(pre.MinFrequency,"Minimum frequency",0);var max=Integer(pre.MaxFrequency,"Maximum frequency",1);
            if(max<=min)return "Maximum frequency must be greater than minimum frequency.";
            Integer(pre.FrequencyStepCount,"Frequency steps",2);Integer(pre.SourceAssignmentFaceCount,"Microphone faces",1);
            var small=Positive(pre.MeshMinEdgeLength,"Minimum edge length");var large=Positive(pre.MeshMaxEdgeLength,"Maximum edge length");
            if(large<small)return "Maximum edge length must be at least the minimum edge length.";
            Positive(pre.MeshMaxError,"Mesh error",true);Positive(pre.MeshGamma,"Gamma");Positive(pre.MeshGammaOpposite,"Gamma opposite");
            if(pre.EarDistance!=null)Positive(pre.EarDistance,"Ear distance");
            Integer(p.Settings.NumCalc.MaxInstances,"Parallel instances",1);var cpu=Integer(p.Settings.NumCalc.MaxCpuLoad,"CPU limit",1);if(cpu>100)return "CPU limit must be from 1 to 100%.";
            if(post.Normalize)Number(post.LevelOffsetDB);
            if (Integer(post.SpatialSubdivisions, "Spatial subdivisions", 0) > 5) return "Spatial subdivisions must be from 0 to 5.";
            if(Integer(post.SamplingRate,"Sampling rate",1)%10!=0)return "Sampling rate must be divisible by 10 Hz.";
            if(scan.Enabled)
            {
                Number(scan.RotationDegrees);Positive(scan.TargetEdgeMM,"Target edge length");Positive(scan.LeftMarginMM,"Left crop margin",true);Positive(scan.RightMarginMM,"Right crop margin",true);
                var inner=Positive(scan.SideMinMM,"Inner crop limit",true);var outer=Positive(scan.SideMaxMM,"Outer crop limit");if(outer<=inner)return "Outer crop limit must exceed the inner limit.";
            }
            return null;
        }
        catch(Exception error) when(error is FormatException or InvalidDataException or OverflowException){return error.Message;}
    }
    static JsonNode? Value(object? value) => JsonSerializer.SerializeToNode(value);
    internal static JsonObject Build(ProjectRecord p, EnvironmentConfig environment)
    {
        var root = p.PreservedConfigJSON == null ? new JsonObject() : JsonNode.Parse(p.PreservedConfigJSON)!.AsObject();
        JsonObject Section(string name)
        {
            if (root[name] is not JsonObject) root[name] = new JsonObject();
            return root[name]!.AsObject();
        }
        void Set(string section, string key, object? value) => Section(section)[key] = Value(value);
        object? PathValue(string? path) => string.IsNullOrWhiteSpace(path) ? null : path;
        var pre = p.Settings.Preprocessing; var scan = p.Settings.ScanPreparation;
        var inf = p.Settings.Inference; var manual = p.Settings.ManualPPM;
        var post = p.Settings.Postprocessing ?? new PostprocessingSettings(); var num = p.Settings.NumCalc;
        Set("paths", "left_ear", PathValue(p.LeftEar)); Set("paths", "right_ear", PathValue(p.RightEar));
        Set("paths", "output_dir", p.SaveLocation);
        Set("paths", "external_deps_dir", environment.ExternalDir);
        Set("paths", "numcalc_executable", environment.NumCalcExecutable);
        Set("paths", "mesh_grading_executable", environment.MeshGradingExecutable);
        Set("paths", "evaluation_grid", string.IsNullOrWhiteSpace(pre.EvaluationGrid) ? "Default" : pre.EvaluationGrid);
        Set("scan_preparation", "enabled", scan.Enabled); Set("scan_preparation", "scan_path", PathValue(scan.ScanPath));
        Set("scan_preparation", "original_scan_path", PathValue(scan.OriginalScanPath));
        Set("scan_preparation", "prepare_left", scan.PrepareLeft); Set("scan_preparation", "prepare_right", scan.PrepareRight);
        foreach (var pair in new[] { ("rotation_degrees", scan.RotationDegrees), ("target_edge_mm", scan.TargetEdgeMM),
            ("left_margin_mm", scan.LeftMarginMM), ("right_margin_mm", scan.RightMarginMM),
            ("side_min_mm", scan.SideMinMM), ("side_max_mm", scan.SideMaxMM) }) Set("scan_preparation", pair.Item1, Number(pair.Item2));
        Set("scan_preparation", "require_manual_review", scan.RequireManualReview);
        Set("scan_preparation", "reviewed_left", PathValue(scan.ReviewedLeft)); Set("scan_preparation", "reviewed_right", PathValue(scan.ReviewedRight));
        Set("inference", "enabled", inf.UsePredictionsForPreprocessing && !manual.Enabled);
        Set("inference", "model_config_file", inf.ModelConfig); Set("inference", "model_checkpoint", inf.ModelCheckpoint);
        Set("inference", "target_left_folder", inf.TargetLeftFolder); Set("inference", "target_right_folder", inf.TargetRightFolder);
        Set("inference", "prediction_left_folder", inf.PredictionLeftFolder); Set("inference", "prediction_right_folder", inf.PredictionRightFolder);
        Set("inference", "use_predictions_for_preprocessing", inf.UsePredictionsForPreprocessing);
        Set("manual_ppm", "enabled", manual.Enabled); Set("manual_ppm", "template_blend", PathValue(manual.TemplateBlend));
        foreach (var side in new[] { "left", "right" })
        {
            var fit = manual.For(side);
            Set("manual_ppm", side + "_mesh", PathValue(fit?.Mesh)); Set("manual_ppm", side + "_parameters", PathValue(fit?.Parameters));
            Set("manual_ppm", side + "_blend", PathValue(fit?.Blend)); Set("manual_ppm", side + "_source", PathValue(fit?.Source));
            Set("manual_ppm", side + "_source_identity", fit?.SourceIdentity);
            var position = side == "left" ? pre.SourcePositionInputLeft : pre.SourcePositionInputRight;
            Set("preprocessing", "source_position_input_" + side, position == null ? null : new[] { position.X, position.Y, position.Z });
        }
        Section("preprocessing").Remove("head_radius");
        Set("preprocessing", "title", p.Name); Set("preprocessing", "ear_distance", pre.EarDistance == null ? null : Number(pre.EarDistance));
        foreach (var pair in new[] { ("min_frequency", pre.MinFrequency), ("max_frequency", pre.MaxFrequency),
            ("mesh_min_edge_length", pre.MeshMinEdgeLength), ("mesh_max_edge_length", pre.MeshMaxEdgeLength),
            ("mesh_max_error", pre.MeshMaxError), ("mesh_gamma", pre.MeshGamma), ("mesh_gamma_opposite", pre.MeshGammaOpposite) })
            Set("preprocessing", pair.Item1, Number(pair.Item2));
        Set("preprocessing", "frequency_step_count", int.Parse(pre.FrequencyStepCount, CultureInfo.InvariantCulture));
        Set("preprocessing", "source_assignment_face_count", int.Parse(pre.SourceAssignmentFaceCount, CultureInfo.InvariantCulture));
        Set("preprocessing", "skip_mesh_grading", false);
        Set("numcalc", "enabled", false); Set("numcalc", "mode", "local");
        Set("numcalc", "max_instances", int.Parse(num.MaxInstances, CultureInfo.InvariantCulture));
        Set("numcalc", "max_cpu_load", Number(num.MaxCpuLoad)); Set("numcalc", "adaptive_fmm_length", num.AdaptiveFmmLength);
        Set("postprocessing", "enabled", false); Set("postprocessing", "overwrite", true);
        Set("postprocessing", "output_sofa_dir", string.IsNullOrWhiteSpace(post.OutputFolder) ? Path.Combine(p.SaveLocation, "HRTF") : post.OutputFolder);
        Set("postprocessing", "normalize", post.Normalize); Set("postprocessing", "level_offset_db", Number(post.LevelOffsetDB));
        Set("postprocessing", "resample_hrirs", post.ResampleHrirs); Set("postprocessing", "sampling_rate", int.Parse(post.SamplingRate, CultureInfo.InvariantCulture));
        Set("postprocessing", "spatial_upsampling", post.SpatialUpsampling);
        Set("postprocessing", "spatial_subdivisions", int.Parse(post.SpatialSubdivisions, CultureInfo.InvariantCulture));
        Set("postprocessing", "spatial_normalize", post.SpatialNormalize);
        return root;
    }

    internal static void Restore(ProjectRecord p, JsonObject root)
    {
        p.PreservedConfigJSON = root.ToJsonString();
        string? Text(string section, string key) => root[section]?[key]?.ToString();
        bool Flag(string section, string key, bool fallback = false) => bool.TryParse(Text(section, key), out var b) ? b : fallback;
        string S(string section, string key, string fallback) => Text(section, key) ?? fallback;
        p.LeftEar = S("paths", "left_ear", ""); p.RightEar = S("paths", "right_ear", "");
        var pre = p.Settings.Preprocessing; var scan = p.Settings.ScanPreparation; var inf = p.Settings.Inference;
        pre.EarDistance = Text("preprocessing", "ear_distance"); pre.EvaluationGrid = Text("paths", "evaluation_grid");
        pre.MinFrequency = S("preprocessing", "min_frequency", "0"); pre.MaxFrequency = S("preprocessing", "max_frequency", "24000");
        pre.FrequencyStepCount = S("preprocessing", "frequency_step_count", "129"); pre.SourceAssignmentFaceCount = S("preprocessing", "source_assignment_face_count", "6");
        pre.MeshMinEdgeLength = S("preprocessing", "mesh_min_edge_length", "0.5"); pre.MeshMaxEdgeLength = S("preprocessing", "mesh_max_edge_length", "10");
        pre.MeshMaxError = S("preprocessing", "mesh_max_error", "0.5"); pre.MeshGamma = S("preprocessing", "mesh_gamma", "0.2");
        pre.MeshGammaOpposite = S("preprocessing", "mesh_gamma_opposite", "0.1");
        scan.Enabled = Flag("scan_preparation", "enabled"); scan.ScanPath = S("scan_preparation", "scan_path", "");
        scan.OriginalScanPath = S("scan_preparation", "original_scan_path", scan.ScanPath);
        // Imported alignment provenance must retain the read-only source for Reset Outputs.
        try
        {
            var note = JsonNode.Parse(File.ReadAllText(Path.ChangeExtension(scan.ScanPath, "json")));
            var original = note?["source_path"]?.GetValue<string>();
            if (note?["kind"]?.GetValue<string>() == "alignment" && File.Exists(original) &&
                !string.Equals(Path.GetFullPath(original!), Path.GetFullPath(scan.ScanPath), StringComparison.OrdinalIgnoreCase))
                scan.OriginalScanPath = original!;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or InvalidOperationException) { }

        scan.PrepareLeft = Flag("scan_preparation", "prepare_left", true); scan.PrepareRight = Flag("scan_preparation", "prepare_right", true);
        scan.RotationDegrees = S("scan_preparation", "rotation_degrees", "0"); scan.TargetEdgeMM = S("scan_preparation", "target_edge_mm", "0.75");
        scan.LeftMarginMM = S("scan_preparation", "left_margin_mm", "20"); scan.RightMarginMM = S("scan_preparation", "right_margin_mm", "10");
        scan.SideMinMM = S("scan_preparation", "side_min_mm", "30"); scan.SideMaxMM = S("scan_preparation", "side_max_mm", "110");
        scan.RequireManualReview = Flag("scan_preparation", "require_manual_review");
        scan.ReviewedLeft = Text("scan_preparation", "reviewed_left"); scan.ReviewedRight = Text("scan_preparation", "reviewed_right");
        inf.UsePredictionsForPreprocessing = Flag("inference", "use_predictions_for_preprocessing");
        inf.ModelConfig = S("inference", "model_config_file", inf.ModelConfig); inf.ModelCheckpoint = S("inference", "model_checkpoint", inf.ModelCheckpoint);
        inf.TargetLeftFolder = S("inference", "target_left_folder", inf.TargetLeftFolder); inf.TargetRightFolder = S("inference", "target_right_folder", inf.TargetRightFolder);
        inf.PredictionLeftFolder = S("inference", "prediction_left_folder", inf.PredictionLeftFolder); inf.PredictionRightFolder = S("inference", "prediction_right_folder", inf.PredictionRightFolder);
        var manual = p.Settings.ManualPPM; manual.Enabled = Flag("manual_ppm", "enabled"); manual.TemplateBlend = Text("manual_ppm", "template_blend");
        foreach (var side in new[] { "left", "right" })
        {
            var mesh = Text("manual_ppm", side + "_mesh");
            if (mesh != null)
            {
                var fit = new ManualFit { Mesh = mesh, Parameters = S("manual_ppm", side + "_parameters", ""), Blend = S("manual_ppm", side + "_blend", ""),
                    Source = S("manual_ppm", side + "_source", ""), SourceIdentity = S("manual_ppm", side + "_source_identity", "") };
                if (side == "left") manual.Left = fit; else manual.Right = fit;
            }
        }
        var post = p.Settings.Postprocessing = new PostprocessingSettings();
        post.OutputFolder = Text("postprocessing", "output_sofa_dir"); post.Normalize = Flag("postprocessing", "normalize", true);
        post.LevelOffsetDB = S("postprocessing", "level_offset_db", "-30"); post.ResampleHrirs = Flag("postprocessing", "resample_hrirs");
        post.SamplingRate = S("postprocessing", "sampling_rate", "48000");
        post.SpatialUpsampling = Flag("postprocessing", "spatial_upsampling");
        post.SpatialSubdivisions = S("postprocessing", "spatial_subdivisions", "3");
        post.SpatialNormalize = Flag("postprocessing", "spatial_normalize");
        p.Settings.NumCalc.MaxInstances = S("numcalc", "max_instances", "1"); p.Settings.NumCalc.MaxCpuLoad = S("numcalc", "max_cpu_load", "90");
        p.Settings.NumCalc.AdaptiveFmmLength = Flag("numcalc", "adaptive_fmm_length", true);
    }
}
