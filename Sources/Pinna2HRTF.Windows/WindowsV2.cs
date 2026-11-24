using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    bool meshPointerIsPrimary;
    readonly TextBox scanRotationBox = new(), targetEdgeBox = new(), leftMarginBox = new(), rightMarginBox = new(), sideMinBox = new(), sideMaxBox = new(), sofaFolderBox = new();
    readonly CheckBox requireReviewBox = new() { Content = "Require ear review before continuing" };
    readonly HashSet<Window> editorWindows = [];
    readonly Dictionary<Guid,string> runInputStamps = [];
    readonly CancellationTokenSource editorLifetime = new();

    async Task<JsonElement> RequestPythonAsync(string commandName, object request, CancellationToken token = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, editorLifetime.Token);
        var payload = JsonSerializer.Serialize(request);
        using var command = JsonDocument.Parse(payload);
        var action = command.RootElement.GetProperty("action").GetString();
        var arguments = new List<string> { "-B", "-m", "HRTFCalculation", commandName };
        if (commandName == "project") arguments.Add(action!);
        var info = GeometryProcess(arguments.ToArray());
        info.RedirectStandardInput = true;
        var timeout = TimeSpan.FromSeconds(commandName switch {
            "outputs" => 3600, "pressure" => 180, "mesh" => 600,
            _ when action is "duplicate" or "publish-editor" or "copy-input" or "stage-status" or "record-stage" => 600,
            _ => 60
        });
        var result = await ToolProcess.RunAsync(info, payload, timeout, linked.Token).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            var detail = string.IsNullOrWhiteSpace(result.Error) ? "The Python operation failed." : result.Error.Trim();
            var (name, message) = CommandError(detail);
            if (name == "SettingsRevisionConflict") throw new SettingsRevisionConflictException(message ?? detail);
            throw new IOException(message ?? detail);
        }
        using var document = JsonDocument.Parse(result.Output);
        return document.RootElement.Clone();
    }


    static (string? Name, string? Message) CommandError(string detail)
    {
        try
        {
            using var reply = JsonDocument.Parse(detail.Split('\n')[^1]);
            var root = reply.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("error", out var name) || name.ValueKind != JsonValueKind.String) return (null, null);
            return (name.GetString(), root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String ? message.GetString() : null);
        }
        catch (JsonException) { return (null, null); }
    }

    void AddV2TextSettings(Dictionary<string, TextSetting> settings)
    {
        settings["postprocessing.spatial_subdivisions"] = new(spatialSubdivisionsBox, p => p.Settings.Postprocessing?.SpatialSubdivisions, (p,v) => (p.Settings.Postprocessing ??= new()).SpatialSubdivisions = v, "3");
        settings["scan_preparation.rotation"] = new(scanRotationBox, p => p.Settings.ScanPreparation.RotationDegrees, (p,v) => p.Settings.ScanPreparation.RotationDegrees = v, "0");
        settings["scan_preparation.target_edge"] = new(targetEdgeBox, p => p.Settings.ScanPreparation.TargetEdgeMM, (p,v) => p.Settings.ScanPreparation.TargetEdgeMM = v, "0.75");
        settings["scan_preparation.left_margin"] = new(leftMarginBox, p => p.Settings.ScanPreparation.LeftMarginMM, (p,v) => p.Settings.ScanPreparation.LeftMarginMM = v, "20");
        settings["scan_preparation.right_margin"] = new(rightMarginBox, p => p.Settings.ScanPreparation.RightMarginMM, (p,v) => p.Settings.ScanPreparation.RightMarginMM = v, "10");
        settings["scan_preparation.side_min"] = new(sideMinBox, p => p.Settings.ScanPreparation.SideMinMM, (p,v) => p.Settings.ScanPreparation.SideMinMM = v, "30");
        settings["scan_preparation.side_max"] = new(sideMaxBox, p => p.Settings.ScanPreparation.SideMaxMM, (p,v) => p.Settings.ScanPreparation.SideMaxMM = v, "110");
        settings["postprocessing.output_folder"] = new(sofaFolderBox, p => p.Settings.Postprocessing?.OutputFolder, (p,v) => (p.Settings.Postprocessing ??= new()).OutputFolder = v.Trim(), "");
    }

    static string SofaDirectory(ProjectRecord p)
    {
        try {
            var folder = p.Settings.Postprocessing?.OutputFolder;
            if (string.IsNullOrWhiteSpace(folder)) return Path.Combine(p.SaveLocation, "HRTF");
            if (Path.IsPathFullyQualified(folder)) return Path.GetFullPath(folder);
            if (string.IsNullOrWhiteSpace(p.SaveLocation) || !Path.IsPathFullyQualified(p.SaveLocation)) return "";
            return Path.GetFullPath(folder, p.SaveLocation);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return ""; }
    }
    string? SourceEar(ProjectRecord p, string side, ArtifactInspection? inspection = null)
    {
        var scan = p.Settings.ScanPreparation;
        if (!scan.Enabled) {
            var path = side == "left" ? p.LeftEar : p.RightEar;
            if (!File.Exists(path)) return null;
            var edited = scan.EarEdit(side);
            return EarReviewIsCurrent(p, side, inspection) ? edited : path;
        }
        if (!(side == "left" ? scan.PrepareLeft : scan.PrepareRight) || !ScanPreparationOutputsCurrent(p, inspection)) return null;
        var reviewed = side == "left" ? scan.ReviewedLeft : scan.ReviewedRight;
        if (EarReviewIsCurrent(p, side, inspection)) return reviewed;
        if (!string.IsNullOrWhiteSpace(reviewed)) return null;
        var prepared = Path.Combine(p.SaveLocation, "Prepared", side == "left" ? "Left.stl" : "Right.stl");
        return File.Exists(prepared) ? prepared : null;
    }

    bool FitIsCurrent(ProjectRecord p, string side)
    {
        var fit = p.Settings.ManualPPM.For(side); var source = SourceEar(p, side);
        return fit != null && source != null && SamePath(source, fit.Source) && MeshIdentity(source) == fit.SourceIdentity && File.Exists(fit.Mesh) && File.Exists(fit.Parameters);
    }

    IEnumerable<string> ProtectedInputs(ProjectRecord p, Guid resetting)
    {
        yield return p.LeftEar; yield return p.RightEar; yield return p.Settings.Preprocessing.EvaluationGrid ?? "";
        var scan = p.Settings.ScanPreparation;
        yield return scan.OriginalScanPath;
        var ownAligned = p.Id == resetting && !string.IsNullOrWhiteSpace(scan.OriginalScanPath) && !SamePath(scan.OriginalScanPath, scan.ScanPath) &&
            SamePath(scan.ScanPath, Path.Combine(p.SaveLocation, "MeshEdits", "AlignedScan.ply"));
        if (!ownAligned) yield return scan.ScanPath;
        if (p.Id != resetting)
        {
            yield return scan.IndividualLeftEdit ?? ""; yield return scan.IndividualRightEdit ?? "";
            yield return scan.ReviewedLeft ?? ""; yield return scan.ReviewedRight ?? "";
            yield return p.Settings.ManualPPM.TemplateBlend ?? "";
            foreach (var fit in new[] { p.Settings.ManualPPM.Left, p.Settings.ManualPPM.Right }.OfType<ManualFit>())
                foreach (var path in new[] { fit.Mesh, fit.Parameters, fit.Blend, fit.Source }) yield return path;
        }
    }

    void ReconcileEditorReferences(ProjectRecord p)
    {
        var scan = p.Settings.ScanPreparation;
        if (!File.Exists(scan.IndividualLeftEdit)) scan.IndividualLeftEdit = null;
        if (!File.Exists(scan.IndividualRightEdit)) scan.IndividualRightEdit = null;
        if (!File.Exists(scan.ReviewedLeft)) scan.ReviewedLeft = null;
        if (!File.Exists(scan.ReviewedRight)) scan.ReviewedRight = null;
        if (!File.Exists(scan.ScanPath) && File.Exists(scan.OriginalScanPath)) { scan.ScanPath = scan.OriginalScanPath; scan.OriginalScanPath = ""; }
        var manual = p.Settings.ManualPPM;
        if (manual.Left is { } l && !File.Exists(l.Mesh)) manual.Left = null;
        if (manual.Right is { } r && !File.Exists(r.Mesh)) manual.Right = null;
        if (!File.Exists(manual.TemplateBlend)) manual.TemplateBlend = null;
        InvalidateManualPositions(p);
    }

    bool PreprocessingFilesPresent(ProjectRecord p)
    {
        var selected=new[]{"left","right"}.Where(side=>SourceEar(p,side)!=null).ToArray();
        return selected.Length>0&&selected.All(side=>new[]{Path.Combine(p.SaveLocation,"Projects",side=="left"?"Left":"Right","parameters.json"),Path.Combine(p.SaveLocation,"Intermediates",side=="left"?"Left":"Right","graded_head.ply")}.All(path=>File.Exists(path)&&new FileInfo(path).Length>0));
    }
    string PreprocessingStamp(ProjectRecord p)
    {
        var config = ProjectDocument.Build(p, environment);
        var preprocessing = config["preprocessing"]!.DeepClone().AsObject();
        foreach (var key in new[] { "enabled", "title", "pictures", "write_intermediates" }) preprocessing.Remove(key);
        var grid = p.Settings.Preprocessing.EvaluationGrid;
        if (string.IsNullOrWhiteSpace(grid)) grid = ProjectDocument.DefaultEvaluationGrid;
        if (grid == ProjectDocument.DefaultEvaluationGrid) grid = Path.Combine(packageRoot, "HRTFCalculation", "EvaluationGrids", grid);
        else if (!Path.IsPathFullyQualified(grid)) grid = Path.Combine(environment.EffectiveMesh2HrtfPath, "Mesh2Input", "EvaluationGrids", "Data", grid);
        var ears = new JsonObject();
        foreach (var side in WorkflowSides(p))
        {
            var settings = preprocessing.DeepClone().AsObject();
            settings.Remove("source_position_input_" + (side == "left" ? "right" : "left"));
            var mesh = PreprocessingMesh(p, side);
            ears[side] = new JsonObject {
                ["settings"] = settings,
                ["mesh_sha256"] = mesh == null ? "" : FileDigest(mesh),
                ["grid_nodes"] = File.Exists(Path.Combine(grid, "Nodes.txt")) ? FileDigest(Path.Combine(grid, "Nodes.txt")) : "unavailable",
                ["grid_elements"] = File.Exists(Path.Combine(grid, "Elements.txt")) ? FileDigest(Path.Combine(grid, "Elements.txt")) : "unavailable"
            };
        }
        return new JsonObject { ["format"] = "pinna2hrtf-preprocessing-windows-v3", ["ears"] = ears }.ToJsonString();
    }
    string InferenceStamp(ProjectRecord p)
    {
        var paths=new[]{SourceEar(p,"left"),SourceEar(p,"right"),p.Settings.Inference.ModelConfig,p.Settings.Inference.ModelCheckpoint};
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new{p.Settings.Inference,inputs=paths.Select(path=>File.Exists(path)?MeshIdentity(path!):"").ToArray()}))));
    }
    bool SofaFilesPresent(ProjectRecord p)
    {
        try
        {
            var selected=new[]{"left","right"}.Where(side=>SourceEar(p,side)!=null).ToArray();
            if(selected.Length==0)return false;
            string[]? names=null;
            foreach(var side in selected)
            {
                var folder=Path.Combine(p.SaveLocation,"Projects",side=="left"?"Left":"Right","Output2HRTF");
                if(!Directory.Exists(folder))return false;
                var current=Directory.GetFiles(folder,"*.sofa").Select(Path.GetFileName).OfType<string>().OrderBy(x=>x).ToArray();
                if(!current.Any(n=>n.StartsWith("HRIR_"))||!current.Any(n=>n.StartsWith("HRTF_")))return false;
                if(names!=null&&!names.SequenceEqual(current))return false;names=current;
            }
            return names!.All(name=>File.Exists(Path.Combine(SofaDirectory(p),selected.Length==2?Path.GetFileNameWithoutExtension(name)+"_merged.sofa":name)));
        }
        catch(IOException){return false;}
    }

    string? SofaConflict(ProjectRecord p)
    {
        var destination=SofaDirectory(p);
        if (string.IsNullOrWhiteSpace(destination)) return "Choose a project save location before a relative SOFA folder.";
        if(Path.GetFullPath(destination)==Path.GetPathRoot(Path.GetFullPath(destination)))return "Choose a SOFA folder below a drive root.";
        foreach(var other in projects.Where(o=>o.Id!=p.Id&&!string.IsNullOrWhiteSpace(o.SaveLocation)))
            if(ContainsPath(other.SaveLocation,destination)||ContainsPath(destination,other.SaveLocation)||ContainsPath(SofaDirectory(other),destination)||ContainsPath(destination,SofaDirectory(other)))return "Choose a SOFA destination separate from other projects.";
        return null;
    }

    async Task<bool> ConfirmOutputChangeAsync(ProjectRecord p, IDisposable? parent = null)
    {
        var dialog = new ContentDialog { Title = "Reset pipeline outputs?", Content = "This change resets preprocessing and later results. Inputs and saved editor work are preserved.",
            PrimaryButtonText = "Reset and apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot };
        return await ShowDialogAsync(dialog) == ContentDialogResult.Primary && await ResetProjectOutputsAsync(p, Stage.Preprocessing, parent);
    }

    async Task DuplicateProjectV2Async()
    {
        var original = selectedProject;
        if (original == null || runs.ContainsKey(original.Id) || outputOperations.Contains(original.Id)) return;
        var name = new TextBox { Header = "Project name", Text = original.Name + " Copy" };
        var folder = new TextBox { Header = "Parent folder", Text = Path.GetDirectoryName(original.SaveLocation) ?? original.SaveLocation };
        var browse = new Button { Content = "Choose folder…" }; browse.Click += async (_, _) => { var result = await PickFolderAsync(folder.Text); if (result != null) folder.Text = result; };
        var panel = new StackPanel { Spacing = 10 }; panel.Children.Add(name); panel.Children.Add(folder); panel.Children.Add(browse);
        var dialog = new ContentDialog { Title = "Duplicate project", Content = panel, PrimaryButtonText = "Duplicate", CloseButtonText = "Cancel", XamlRoot = Root.XamlRoot };
        if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;
        if (!projects.Contains(original) || ProjectBusy(original.Id)) return;
        using var reservation = projectOperations.TryReserve(original.Id);
        if (reservation == null) return;
        outputOperations.Add(original.Id);
        try
        {
            var result = await RequestPythonAsync("project", new { action = "duplicate", source = original.SaveLocation, parent = folder.Text, name = name.Text, project = original });
            var duplicate = JsonSerializer.Deserialize<ProjectRecord>(result.GetProperty("project").GetRawText(), jsonOptions) ?? throw new IOException("The project copy returned no data.");
            await Task.Run(() => {
                using var fresh = FileFingerprints.Fresh();
                foreach (var side in new[] { "left", "right" })
                    if (FitIsCurrent(original, side) && duplicate.Settings.ManualPPM.For(side) is { } fit)
                        fit.SourceIdentity = MeshIdentity(fit.Source);
            });
            RecordCreatedFolder(duplicate); duplicate.InputHandling = original.InputHandling;
            projects.Add(duplicate); selectedProject = duplicate; failedStages[duplicate.Id] = [];
            Persist(); LoadSelectedProject(); RefreshProjectList(); RefreshArtifacts(); RefreshPipelineStatus();
        }
        catch (Exception error) { AppendLog("Could not duplicate project: " + error.Message, original.Id); await ShowProjectRemovalErrorAsync(error.Message); }
        finally { outputOperations.Remove(original.Id); }
    }
}

sealed class SettingsRevisionConflictException(string message) : IOException(message);
