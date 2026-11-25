using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Pinna2HRTF.Windows;

internal static class ProjectDocument
{
    internal static string DefaultEvaluationGrid => SettingsCatalog.Text("paths.evaluation_grid");
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
    internal static Dictionary<string, string> FormValues(ProjectRecord p)
    {
        var pre = p.Settings.Preprocessing; var scan = p.Settings.ScanPreparation; var post = p.Settings.Postprocessing ?? new();
        static string Flag(bool value) => value ? "true" : "false";
        return new()
        {
            ["mesh2hrtf.min_frequency"] = pre.MinFrequency, ["mesh2hrtf.max_frequency"] = pre.MaxFrequency,
            ["mesh2hrtf.frequency_steps"] = pre.FrequencyStepCount, ["mesh2hrtf.microphone_faces"] = pre.SourceAssignmentFaceCount,
            ["mesh2hrtf.ear_distance"] = pre.EarDistance ?? "",
            ["head.radius_scale"] = pre.HeadRadiusScale,
            ["head.width_scale"] = pre.HeadWidthScale,
            ["head.height_scale"] = pre.HeadHeightScale,
            ["head.taper_percent"] = pre.HeadTaperPercent,
            ["mesh_grading.min_edge_length"] = pre.MeshMinEdgeLength, ["mesh_grading.max_edge_length"] = pre.MeshMaxEdgeLength,
            ["mesh_grading.max_error"] = pre.MeshMaxError, ["mesh_grading.gamma"] = pre.MeshGamma, ["mesh_grading.gamma_opposite"] = pre.MeshGammaOpposite,
            ["numcalc.parallel_instances"] = p.Settings.NumCalc.MaxInstances, ["numcalc.cpu_limit"] = p.Settings.NumCalc.MaxCpuLoad,
            ["postprocessing.normalize"] = Flag(post.Normalize), ["postprocessing.level_offset"] = post.LevelOffsetDB,
            ["postprocessing.resample_hrirs"] = Flag(post.ResampleHrirs), ["postprocessing.sampling_rate"] = post.SamplingRate,
            ["postprocessing.spatial_upsampling"] = Flag(post.SpatialUpsampling), ["postprocessing.spatial_subdivisions"] = post.SpatialSubdivisions,
            ["scan.enabled"] = Flag(scan.Enabled), ["scan.path"] = scan.ScanPath, ["scan.rotation"] = scan.RotationDegrees,
            ["scan.prepare_left"] = Flag(scan.PrepareLeft), ["scan.prepare_right"] = Flag(scan.PrepareRight),
            ["scan.target_edge"] = scan.TargetEdgeMM, ["scan.left_margin"] = scan.LeftMarginMM, ["scan.right_margin"] = scan.RightMarginMM,
            ["scan.side_min"] = scan.SideMinMM, ["scan.side_max"] = scan.SideMaxMM,
        };
    }

    internal static string? ValidationError(ProjectRecord p, string? stage = null, string? earModel = null)
    {
        var values = FormValues(p);
        if (earModel != null) values["ear_model.method"] = earModel;
        return SettingsCatalog.Issues(values, stage).Select(issue => issue.Message).FirstOrDefault();
    }

    static object? Numeric(string id, string text, string key)
    {
        var value = SettingsCatalog.FieldMessage(id, text) == null ? text : SettingsCatalog.Text(key);
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (int.TryParse(value.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var whole)) return whole;
        return double.TryParse(value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) ? number : null;
    }

    static JsonNode? Value(object? value) => JsonSerializer.SerializeToNode(value);

    internal static string? ReadAlignmentOriginal(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var note = JsonNode.Parse(File.ReadAllText(Path.ChangeExtension(path, "json")));
            if (note?["kind"]?.GetValue<string>() != "alignment") return null;
            var original = note["source_path"]?.GetValue<string>();
            if (string.IsNullOrWhiteSpace(original)) return null;
            var fullPath = Path.GetFullPath(path);
            var source = Path.GetFullPath(original, Path.GetDirectoryName(fullPath)!);
            return string.Equals(source, fullPath, StringComparison.OrdinalIgnoreCase) ? null : source;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }
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
        Set("paths", "mesh2hrtf_path", environment.EffectiveMesh2HrtfPath);
        Set("paths", "numcalc_executable", environment.NumCalcExecutable);
        Set("paths", "mesh_grading_executable", environment.MeshGradingExecutable);
        Set("paths", "evaluation_grid", string.IsNullOrWhiteSpace(pre.EvaluationGrid) ? DefaultEvaluationGrid : pre.EvaluationGrid);
        Set("scan_preparation", "enabled", scan.Enabled); Set("scan_preparation", "scan_path", PathValue(scan.ScanPath));
        Set("scan_preparation", "original_scan_path", PathValue(scan.OriginalScanPath));
        Set("scan_preparation", "prepare_left", scan.PrepareLeft); Set("scan_preparation", "prepare_right", scan.PrepareRight);
        foreach (var (key, id, text) in new[] { ("rotation_degrees", "scan.rotation", scan.RotationDegrees), ("target_edge_mm", "scan.target_edge", scan.TargetEdgeMM),
            ("left_margin_mm", "scan.left_margin", scan.LeftMarginMM), ("right_margin_mm", "scan.right_margin", scan.RightMarginMM),
            ("side_min_mm", "scan.side_min", scan.SideMinMM), ("side_max_mm", "scan.side_max", scan.SideMaxMM) })
            Set("scan_preparation", key, Numeric(id, text, "scan_preparation." + key));
        Set("scan_preparation", "require_manual_review", scan.RequireManualReview);
        Set("paths", "edited_left_ear", PathValue(scan.IndividualLeftEdit)); Set("paths", "edited_right_ear", PathValue(scan.IndividualRightEdit));
        Set("scan_preparation", "reviewed_left", PathValue(scan.ReviewedLeft)); Set("scan_preparation", "reviewed_right", PathValue(scan.ReviewedRight));
        Set("inference", "enabled", inf.UsePredictionsForPreprocessing && !manual.Enabled);
        Set("inference", "model_config_file", inf.ModelConfig); Set("inference", "model_checkpoint", inf.ModelCheckpoint);
        Set("inference", "target_left_folder", inf.TargetLeftFolder); Set("inference", "target_right_folder", inf.TargetRightFolder);
        Set("inference", "prediction_left_folder", inf.PredictionLeftFolder); Set("inference", "prediction_right_folder", inf.PredictionRightFolder);
        Set("inference", "use_predictions_for_preprocessing", inf.UsePredictionsForPreprocessing);
        Set("ui", "ear_model_method", p.Settings.EarModelMethod);
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
        foreach (var (key, id, text) in new[] { ("min_frequency", "mesh2hrtf.min_frequency", pre.MinFrequency), ("max_frequency", "mesh2hrtf.max_frequency", pre.MaxFrequency),
            ("frequency_step_count", "mesh2hrtf.frequency_steps", pre.FrequencyStepCount), ("source_assignment_face_count", "mesh2hrtf.microphone_faces", pre.SourceAssignmentFaceCount),
            ("mesh_min_edge_length", "mesh_grading.min_edge_length", pre.MeshMinEdgeLength), ("mesh_max_edge_length", "mesh_grading.max_edge_length", pre.MeshMaxEdgeLength),
            ("mesh_max_error", "mesh_grading.max_error", pre.MeshMaxError), ("mesh_gamma", "mesh_grading.gamma", pre.MeshGamma), ("mesh_gamma_opposite", "mesh_grading.gamma_opposite", pre.MeshGammaOpposite) })
            Set("preprocessing", key, Numeric(id, text, "preprocessing." + key));
        foreach (var (key, id, text) in new[] { ("head_radius_scale", "head.radius_scale", pre.HeadRadiusScale), ("head_width_scale", "head.width_scale", pre.HeadWidthScale), ("head_height_scale", "head.height_scale", pre.HeadHeightScale), ("head_taper_percent", "head.taper_percent", pre.HeadTaperPercent) })
            Set("preprocessing", key, Numeric(id, text, "preprocessing." + key));
        Set("preprocessing", "skip_mesh_grading", false);
        Set("numcalc", "enabled", false);
        Set("numcalc", "max_instances", Numeric("numcalc.parallel_instances", num.MaxInstances, "numcalc.max_instances"));
        Set("numcalc", "max_cpu_load", Numeric("numcalc.cpu_limit", num.MaxCpuLoad, "numcalc.max_cpu_load")); Set("numcalc", "adaptive_fmm_length", num.AdaptiveFmmLength);
        Set("postprocessing", "enabled", false); Set("postprocessing", "overwrite", true);
        Set("postprocessing", "output_sofa_dir", string.IsNullOrWhiteSpace(post.OutputFolder) ? Path.Combine(p.SaveLocation, "HRTF") : post.OutputFolder);
        Set("postprocessing", "normalize", post.Normalize); Set("postprocessing", "level_offset_db", Numeric("postprocessing.level_offset", post.LevelOffsetDB, "postprocessing.level_offset_db"));
        Set("postprocessing", "resample_hrirs", post.ResampleHrirs); Set("postprocessing", "sampling_rate", Numeric("postprocessing.sampling_rate", post.SamplingRate, "postprocessing.sampling_rate"));
        Set("postprocessing", "spatial_upsampling", post.SpatialUpsampling);
        Set("postprocessing", "spatial_subdivisions", Numeric("postprocessing.spatial_subdivisions", post.SpatialSubdivisions, "postprocessing.spatial_subdivisions"));
        Set("postprocessing", "spatial_normalize", post.SpatialNormalize);
        return root;
    }

    internal static void Restore(ProjectRecord p, JsonObject root)
    {
        p.PreservedConfigJSON = root.ToJsonString();
        string? Text(string section, string key) => root[section]?[key]?.ToString();
        bool Flag(string section, string key, bool fallback = false) => bool.TryParse(Text(section, key), out var b) ? b : fallback;
        string S(string section, string key, string fallback) => Text(section, key) ?? fallback;
        string D(string section, string key) => Text(section, key) ?? SettingsCatalog.Text(section + "." + key);
        bool B(string section, string key) => Flag(section, key, SettingsCatalog.Flag(section + "." + key));
        p.LeftEar = S("paths", "left_ear", ""); p.RightEar = S("paths", "right_ear", "");
        var pre = p.Settings.Preprocessing; var scan = p.Settings.ScanPreparation; var inf = p.Settings.Inference;
        pre.EarDistance = Text("preprocessing", "ear_distance"); pre.EvaluationGrid = Text("paths", "evaluation_grid");
        pre.MinFrequency = D("preprocessing", "min_frequency"); pre.MaxFrequency = D("preprocessing", "max_frequency");
        pre.FrequencyStepCount = D("preprocessing", "frequency_step_count"); pre.SourceAssignmentFaceCount = D("preprocessing", "source_assignment_face_count");
        pre.MeshMinEdgeLength = D("preprocessing", "mesh_min_edge_length"); pre.MeshMaxEdgeLength = D("preprocessing", "mesh_max_edge_length");
        pre.MeshMaxError = D("preprocessing", "mesh_max_error"); pre.MeshGamma = D("preprocessing", "mesh_gamma");
        pre.MeshGammaOpposite = D("preprocessing", "mesh_gamma_opposite");
        pre.HeadRadiusScale = D("preprocessing", "head_radius_scale");
        pre.HeadWidthScale = D("preprocessing", "head_width_scale");
        pre.HeadHeightScale = D("preprocessing", "head_height_scale");
        pre.HeadTaperPercent = D("preprocessing", "head_taper_percent");
        scan.Enabled = Flag("scan_preparation", "enabled"); scan.ScanPath = S("scan_preparation", "scan_path", "");
        scan.OriginalScanPath = S("scan_preparation", "original_scan_path", scan.ScanPath);
        if (ReadAlignmentOriginal(scan.ScanPath) is string original && File.Exists(original))
            scan.OriginalScanPath = original;

        scan.PrepareLeft = B("scan_preparation", "prepare_left"); scan.PrepareRight = B("scan_preparation", "prepare_right");
        scan.RotationDegrees = D("scan_preparation", "rotation_degrees"); scan.TargetEdgeMM = D("scan_preparation", "target_edge_mm");
        scan.LeftMarginMM = D("scan_preparation", "left_margin_mm"); scan.RightMarginMM = D("scan_preparation", "right_margin_mm");
        scan.SideMinMM = D("scan_preparation", "side_min_mm"); scan.SideMaxMM = D("scan_preparation", "side_max_mm");
        scan.RequireManualReview = B("scan_preparation", "require_manual_review");
        scan.IndividualLeftEdit = Text("paths", "edited_left_ear"); scan.IndividualRightEdit = Text("paths", "edited_right_ear");
        scan.ReviewedLeft = Text("scan_preparation", "reviewed_left"); scan.ReviewedRight = Text("scan_preparation", "reviewed_right");
        inf.UsePredictionsForPreprocessing = Flag("inference", "use_predictions_for_preprocessing");
        inf.ModelConfig = S("inference", "model_config_file", inf.ModelConfig); inf.ModelCheckpoint = S("inference", "model_checkpoint", inf.ModelCheckpoint);
        inf.TargetLeftFolder = S("inference", "target_left_folder", inf.TargetLeftFolder); inf.TargetRightFolder = S("inference", "target_right_folder", inf.TargetRightFolder);
        inf.PredictionLeftFolder = S("inference", "prediction_left_folder", inf.PredictionLeftFolder); inf.PredictionRightFolder = S("inference", "prediction_right_folder", inf.PredictionRightFolder);
        var manual = p.Settings.ManualPPM; manual.Enabled = Flag("manual_ppm", "enabled"); manual.TemplateBlend = Text("manual_ppm", "template_blend");
        if (Text("ui", "ear_model_method") is string method) p.Settings.SelectEarModel(method);
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
        post.OutputFolder = Text("postprocessing", "output_sofa_dir"); post.Normalize = B("postprocessing", "normalize");
        post.LevelOffsetDB = D("postprocessing", "level_offset_db"); post.ResampleHrirs = B("postprocessing", "resample_hrirs");
        post.SamplingRate = D("postprocessing", "sampling_rate");
        post.SpatialUpsampling = B("postprocessing", "spatial_upsampling");
        post.SpatialSubdivisions = D("postprocessing", "spatial_subdivisions");
        post.SpatialNormalize = B("postprocessing", "spatial_normalize");
        p.Settings.NumCalc.MaxInstances = D("numcalc", "max_instances"); p.Settings.NumCalc.MaxCpuLoad = D("numcalc", "max_cpu_load");
        p.Settings.NumCalc.AdaptiveFmmLength = B("numcalc", "adaptive_fmm_length");
    }
}
