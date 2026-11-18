using HelixToolkit.Maths;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Numerics;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    string? alignmentWorkspace;
    string? alignmentSource;
    string? alignmentSourceHash;
    JsonElement? pendingAlignment;
    Guid? alignmentProjectId;
    Guid? alignmentSessionProject;
    string? alignmentSessionSource;
    int alignmentGeneration;
    bool alignmentSaving;
    bool alignmentDiscardPromptOpen;
    readonly HashSet<string> activeAlignmentWorkspaces = [];
    readonly CheckBox coordinateToggle = new() { Content = "Show coordinate system", IsChecked = true };
    readonly ProgressRing alignmentLoadingRing = new() { Width = 20, Height = 20, IsActive = false, Visibility = Visibility.Collapsed };
    readonly List<LineGeometryModel3D> alignmentAxes = [];

    static bool IsGeneratedAlignment(ProjectRecord project, string path) =>
        (!string.IsNullOrWhiteSpace(project.SaveLocation) && SamePath(path, Path.Combine(project.SaveLocation, "MeshEdits", "AlignedScan.ply")))
        || ProjectDocument.ReadAlignmentOriginal(path) != null;

    static string ResolveAlignmentSource(ProjectRecord project)
    {
        var scan = project.Settings.ScanPreparation;
        var recorded = scan.OriginalScanPath;
        var generated = IsGeneratedAlignment(project, scan.ScanPath);
        if (!generated) return scan.ScanPath;
        if (!string.IsNullOrWhiteSpace(recorded) && !IsGeneratedAlignment(project, recorded) && File.Exists(recorded)) return recorded;
        var original = ProjectDocument.ReadAlignmentOriginal(scan.ScanPath);
        if (original != null && !IsGeneratedAlignment(project, original)) return original;
        return !string.IsNullOrWhiteSpace(recorded) && !IsGeneratedAlignment(project, recorded) ? recorded : "";
    }

    async Task<bool> ConfirmCancelAlignmentAsync()
    {
        if (!scanAlignmentMode) return true;
        if (alignmentSaving || alignmentDiscardPromptOpen) return false;
        var session = alignmentGeneration;
        if (scanAlignmentLandmarks.Count != 0)
        {
            var dialog = new ContentDialog
            {
                Title = "Discard unsaved alignment?", PrimaryButtonText = "Discard",
                CloseButtonText = "Keep editing", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot
            };
            alignmentDiscardPromptOpen = true;
            try { if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return false; }
            finally { alignmentDiscardPromptOpen = false; }
        }
        if (!scanAlignmentMode || session != alignmentGeneration || alignmentSaving) return false;
        EndScanAlignment();
        RefreshArtifacts();
        return true;
    }

    void UpdateAlignmentSaveEnabled()
    {
        if (pendingAlignment != null)
            scanAlignmentStatus.Text = "Inspect alignment: X forward, Y left, Z up. Save or cancel.";
        applyScanAlignmentButton.IsEnabled = scanAlignmentLandmarks.Count == 3;
    }

    void ClearAlignmentPreview()
    {
        alignmentGeneration++;
        pendingAlignment = null; alignmentProjectId = null;
        if (alignmentWorkspace != null && !activeAlignmentWorkspaces.Contains(alignmentWorkspace)) { try { Directory.Delete(alignmentWorkspace, true); } catch (IOException) { } }
        alignmentWorkspace = null; alignmentSource = null; alignmentSourceHash = null;
        applyScanAlignmentButton.Content = "Preview alignment";
        foreach(var axis in alignmentAxes) meshViewport.Items.Remove(axis); alignmentAxes.Clear();
    }

    void UpdateAlignmentAxes()
    {
        foreach(var axis in alignmentAxes)meshViewport.Items.Remove(axis);alignmentAxes.Clear();
        meshViewport.ShowCoordinateSystem = scanAlignmentMode && coordinateToggle.IsChecked == true;
        if (!scanAlignmentMode || coordinateToggle.IsChecked != true || currentMesh == null) return;
        var start=currentMesh.ToDisplay(Vector3.Zero);var length=(float)(750*currentMesh.Scale);
        foreach(var (direction,color) in new[]{(Vector3.UnitX,Colors.Red),(Vector3.UnitY,Colors.Green),(Vector3.UnitZ,Colors.Blue)})
        {
            var builder=new LineBuilder();builder.AddLine(start,start+direction*length);
            var line=new LineGeometryModel3D{Geometry=builder.ToLineGeometry3D(),Color=color,Thickness=3,IsHitTestVisible=false};
            alignmentAxes.Add(line);meshViewport.Items.Add(line);
        }
    }

    async Task PreviewOrSaveAlignmentAsync()
    {
        var project=selectedProject;
        if(!scanAlignmentMode||project==null||alignmentSessionProject!=project.Id||alignmentDiscardPromptOpen||runs.ContainsKey(project.Id)||outputOperations.Contains(project.Id))return;
        using var reservation = projectOperations.TryReserve(project.Id);
        if (reservation == null) return;
        var session = alignmentGeneration;
        var originalRoot = project.SaveLocation;
        var workspace = alignmentWorkspace;
        var originalSource = alignmentSource;
        var originalHash = alignmentSourceHash;
        if (workspace != null) activeAlignmentWorkspaces.Add(workspace);
        applyScanAlignmentButton.IsEnabled=false;
        alignmentSaving = pendingAlignment != null;
        try
        {
            if(pendingAlignment is { } aligned)
            {
                if(alignmentProjectId!=project.Id||alignmentWorkspace==null||alignmentSource==null)throw new IOException("The project changed; restart alignment.");
                var destination=Path.Combine(originalRoot,"MeshEdits","AlignedScan.ply");
                var operation=new Dictionary<string,object>{["action"]="align",["points"]=scanAlignmentLandmarks.Select(p=>new[]{(double)p.X,p.Y,p.Z}).ToArray(),
                    ["transform"]=aligned.GetProperty("transform"),["alignment_method"]=aligned.GetProperty("alignment_method"),["landmark_labels"]=new[]{"nose_tip","left_ear_canal_entrance","right_ear_canal_entrance"}};
                var staged = Path.Combine(workspace!, "saved-alignment.ply");
                await RunMeshEditorPythonAsync(new(){["action"]="save",["kind"]="alignment",["source"]=Path.Combine(workspace!,"aligned.ply"),
                    ["original_source"]=originalSource!,["original_sha256"]=originalHash!,["destination"]=staged,["operations"]=new[]{operation}});
                if (shutdownCleanupDone || !projects.Contains(project) || project.SaveLocation != originalRoot) return;
                await PublishEditorFilesAsync(project, new() { [destination] = File.ReadAllBytes(staged), [Path.ChangeExtension(destination, "json")] = File.ReadAllBytes(Path.ChangeExtension(staged, "json")) }, editorLifetime.Token,
                    new() { [destination] = File.GetLastWriteTimeUtc(staged) }, new() { [originalSource!] = originalHash! });
                var scan=project.Settings.ScanPreparation;scan.OriginalScanPath=originalSource!;scan.ScanPath=destination;scan.RotationDegrees="0";scan.Enabled=true;scan.ReviewedLeft=null;scan.ReviewedRight=null;
                project.Settings.Preprocessing.SourcePositionInputLeft=null;project.Settings.Preprocessing.SourcePositionInputRight=null;
                Persist();
                alignmentSaving = false;
                if (selectedProject == project && session == alignmentGeneration) { EndScanAlignment(); LoadSelectedProject(); RememberSelectedArtifact(destination); RefreshArtifacts(); }
                RefreshPipelineStatus();return;
            }
            if(scanAlignmentLandmarks.Count!=3)return;
            ClearAlignmentPreview();alignmentProjectId=project.Id;
            alignmentSource=alignmentSessionSource;
            if (alignmentSource == null || !File.Exists(alignmentSource)) throw new IOException("The original scan is missing. Reopen alignment to locate it.");
            alignmentWorkspace=Path.Combine(Path.GetTempPath(),"pinna-align-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(alignmentWorkspace);
            workspace = alignmentWorkspace; activeAlignmentWorkspaces.Add(workspace); session = alignmentGeneration;
            var preview=Path.Combine(alignmentWorkspace,"aligned.ply");var frame=Path.Combine(alignmentWorkspace,"frame");
            scanAlignmentStatus.Text = "Preparing alignment preview…";
            alignmentLoadingRing.IsActive = true;
            alignmentLoadingRing.Visibility = Visibility.Visible;
            var result=await RunMeshEditorPythonAsync(new(){["action"]="align",["source"]=alignmentSource,["original_source"]=alignmentSource,["output"]=preview,["frame"]=frame,["points"]=scanAlignmentLandmarks.Select(p=>new[]{(double)p.X,p.Y,p.Z}).ToArray()});
            if(session != alignmentGeneration || selectedProject!=project || shutdownCleanupDone)return;
            alignmentSourceHash=result.GetProperty("source_sha256").GetString();
            pendingAlignment=result;
            SelectAlignmentArtifact(new Artifact("Alignment preview — unsaved",preview));
            applyScanAlignmentButton.Content="Save alignment";scanAlignmentStatus.Text="Inspect alignment: X forward, Y left, Z up. Save or cancel.";
        }
        catch(Exception error){AppendLog("Scan alignment: " + error.Message, project.Id); if(selectedProject==project && session==alignmentGeneration)scanAlignmentStatus.Text=error.Message;}
        finally
        {
            if (session == alignmentGeneration) { alignmentLoadingRing.IsActive = false; alignmentLoadingRing.Visibility = Visibility.Collapsed; }
            alignmentSaving = false;
            if (workspace != null)
            {
                activeAlignmentWorkspaces.Remove(workspace);
                if (alignmentWorkspace != workspace) { try { Directory.Delete(workspace, true); } catch(IOException) {} }
            }
            if(selectedProject==project && session==alignmentGeneration && scanAlignmentMode)UpdateAlignmentSaveEnabled();
        }
    }
}
