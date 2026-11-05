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
    readonly Dictionary<Guid,string> stagedSofaOutputs = [];
    readonly Dictionary<Guid,string> runInputStamps = [];
    readonly CancellationTokenSource editorLifetime = new();

    async Task<JsonElement> RequestPythonAsync(string module, object request, CancellationToken token = default)
    {
        var info = GeometryProcess("-B", "-m", module);
        info.RedirectStandardInput = true;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, editorLifetime.Token);
        var payload = JsonSerializer.Serialize(request);
        using var command = JsonDocument.Parse(payload);
        var duplicate = command.RootElement.TryGetProperty("action", out var action) && action.GetString() == "duplicate";
        var timeout = TimeSpan.FromSeconds(module.Contains("PressureField") ? 180 : duplicate ? 600 : 60);
        var result = await ToolProcess.RunAsync(info, payload, timeout, linked.Token).ConfigureAwait(false);
        if (result.ExitCode != 0) throw new IOException(string.IsNullOrWhiteSpace(result.Error) ? "The Python operation failed." : result.Error.Trim());
        using var document = JsonDocument.Parse(result.Output);
        return document.RootElement.Clone();
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

    static string SofaDirectory(ProjectRecord p) => string.IsNullOrWhiteSpace(p.Settings.Postprocessing?.OutputFolder) ? Path.Combine(p.SaveLocation, "HRTF") : Path.GetFullPath(p.Settings.Postprocessing.OutputFolder,p.SaveLocation);
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
        // Resetting generated files keeps the project method and prompts for missing fits.
        InvalidateManualPositions(p);
    }

    bool PreprocessingFilesPresent(ProjectRecord p)
    {
        var selected=new[]{"left","right"}.Where(side=>SourceEar(p,side)!=null).ToArray();
        return selected.Length>0&&selected.All(side=>new[]{Path.Combine(p.SaveLocation,"Projects",side=="left"?"Left":"Right","parameters.json"),Path.Combine(p.SaveLocation,"Intermediates",side=="left"?"Left":"Right","graded_head.ply")}.All(path=>File.Exists(path)&&new FileInfo(path).Length>0));
    }
    string PreprocessingStamp(ProjectRecord p)
    {
        var inputs=new[]{"left","right"}.Select(side=>PreprocessingMesh(p,side)).Select(path=>path==null?"":MeshIdentity(path)).ToArray();
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new{p.Settings.Preprocessing,p.Settings.Inference,p.Settings.ManualPPM,p.Settings.ScanPreparation,inputs}))));
    }
    string InferenceStamp(ProjectRecord p)
    {
        var paths=new[]{SourceEar(p,"left"),SourceEar(p,"right"),p.Settings.Inference.ModelConfig,p.Settings.Inference.ModelCheckpoint};
        return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new{p.Settings.Inference,inputs=paths.Select(path=>File.Exists(path)?MeshIdentity(path!):"").ToArray()}))));
    }
    bool InferenceStampIsCurrent(ProjectRecord p)
    {
        var path=Path.Combine(p.SaveLocation,".pinna2hrtf-inference-signature");
        return File.Exists(path)&&File.ReadAllText(path)==InferenceStamp(p);
    }
    bool PreprocessingStampIsCurrent(ProjectRecord p)
    {
        var path=Path.Combine(p.SaveLocation,".pinna2hrtf-preprocessing-signature");
        return File.Exists(path)&&File.ReadAllText(path)==PreprocessingStamp(p);
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

    ExternalSofaOutputs ExternalOutputsFor(ProjectRecord p) => new(p.SaveLocation, projects.SelectMany(other => ProtectedInputs(other,p.Id)), SofaDirectory(p));
    bool HasExternalSofa(ProjectRecord p) => !ContainsPath(p.SaveLocation,SofaDirectory(p));
    string? SofaConflict(ProjectRecord p)
    {
        var destination=SofaDirectory(p);
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
            var result = await RequestPythonAsync("HRTFCalculation.DesktopBridge", new { action = "duplicate", source = original.SaveLocation, parent = folder.Text, name = name.Text, project = original });
            var duplicate = JsonSerializer.Deserialize<ProjectRecord>(result.GetProperty("project").GetRawText(), jsonOptions) ?? throw new IOException("The project copy returned no data.");
            // Fingerprints include platform timestamps; rebase valid fitting
            // references to their copied source without accepting stale originals.
            foreach (var side in new[] { "left", "right" })
                if (FitIsCurrent(original, side) && duplicate.Settings.ManualPPM.For(side) is { } fit) fit.SourceIdentity = MeshIdentity(fit.Source);
            RecordCreatedFolder(duplicate); duplicate.InputHandling = original.InputHandling;
            projects.Add(duplicate); selectedProject = duplicate; failedStages[duplicate.Id] = [];
            Persist(); LoadSelectedProject(); RefreshProjectList(); RefreshArtifacts(); RefreshPipelineStatus();
        }
        catch (Exception error) { AppendLog("Could not duplicate project: " + error.Message, original.Id); await ShowProjectRemovalErrorAsync(error.Message); }
        finally { outputOperations.Remove(original.Id); }
    }
}
