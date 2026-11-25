using HelixToolkit;
using HelixToolkit.Maths;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    readonly TextBox earDistanceBox = new();
    readonly TextBox headRadiusScaleBox = new();
    readonly TextBox headWidthScaleBox = new();
    readonly TextBox headHeightScaleBox = new();
    readonly TextBox headTaperPercentBox = new();
    readonly ComboBox torsoModePicker = new();
    Expander? torsoShapeExpander;
    readonly TextBox torsoWidthBox = new();
    readonly TextBox torsoDepthBox = new();
    readonly TextBox torsoHeightBox = new();
    string SelectedTorsoMode => (torsoModePicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "off";
    void UpdateTorsoControls() { if (torsoShapeExpander != null) torsoShapeExpander.Visibility = SelectedTorsoMode == "geometric" ? Visibility.Visible : Visibility.Collapsed; }
    Expander? headShapeExpander;
    DispatcherTimer? headPreviewTimer;
    int headPreviewGeneration;
    string? requestedHeadPreviewKey;
    string? displayedHeadPreviewKey;
    bool headPreviewPending;
    sealed record CachedHeadPreview(string Key, MeshData Head, MeshGeometry3D[] Ears);
    readonly Dictionary<Guid, CachedHeadPreview> headPreviewCache = [];
    string HeadPreviewPath(ProjectRecord project) => Path.Combine(appData, "Cache", "Head Preview", project.Id.ToString(), "head.stl");

    void AddHeadShapeTextSettings(Dictionary<string, TextSetting> settings)
    {
        settings["torso.width"] = new(torsoWidthBox, p => p.Settings.Preprocessing.TorsoWidthMM, (p, v) => p.Settings.Preprocessing.TorsoWidthMM = v.Trim(), SettingsCatalog.Text("preprocessing.torso_width_mm"));
        settings["torso.depth"] = new(torsoDepthBox, p => p.Settings.Preprocessing.TorsoDepthMM, (p, v) => p.Settings.Preprocessing.TorsoDepthMM = v.Trim(), SettingsCatalog.Text("preprocessing.torso_depth_mm"));
        settings["torso.height"] = new(torsoHeightBox, p => p.Settings.Preprocessing.TorsoHeightMM, (p, v) => p.Settings.Preprocessing.TorsoHeightMM = v.Trim(), SettingsCatalog.Text("preprocessing.torso_height_mm"));

        settings["head.radius_scale"] = new(headRadiusScaleBox, p => p.Settings.Preprocessing.HeadRadiusScale, (p, v) => p.Settings.Preprocessing.HeadRadiusScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_radius_scale"));
        settings["head.width_scale"] = new(headWidthScaleBox, p => p.Settings.Preprocessing.HeadWidthScale, (p, v) => p.Settings.Preprocessing.HeadWidthScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_width_scale"));
        settings["head.height_scale"] = new(headHeightScaleBox, p => p.Settings.Preprocessing.HeadHeightScale, (p, v) => p.Settings.Preprocessing.HeadHeightScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_height_scale"));
        settings["head.taper_percent"] = new(headTaperPercentBox, p => p.Settings.Preprocessing.HeadTaperPercent, (p, v) => p.Settings.Preprocessing.HeadTaperPercent = v.Trim(), SettingsCatalog.Text("preprocessing.head_taper_percent"));
    }

    void RequestHeadPreview(bool focus = false)
    {
        if (selectedProject is not { } project || scanAlignmentMode || placementSide != null || shutdownCleanupDone) return;
        var path = HeadPreviewPath(project);
        if (!focus && !SamePath(selectedArtifactPath, path)) return;
        var sources = new[] { "left", "right" }.Select(side => PreprocessingMesh(project, side) ?? (side == "left" ? project.LeftEar : project.RightEar));
        var key = project.Id + "|" + string.Join("|", sources.Select(source => source + ":" + (File.Exists(source) ? MeshIdentity(source) : "missing"))) + "|" +
            JsonSerializer.Serialize(ProjectDocument.FormValues(project).Where(pair => (pair.Key.StartsWith("head.", StringComparison.Ordinal) || pair.Key.StartsWith("torso.", StringComparison.Ordinal)) || pair.Key == "mesh2hrtf.ear_distance").OrderBy(pair => pair.Key));
        if (focus)
        {
            if (!SamePath(selectedArtifactPath, path)) { SaveMeshCamera(); ResetViewer(); }
            selectedArtifactPath = path;
            selectedArtifactSide = null;
            RememberSelectedArtifact(path);
            selectedArtifactText.Text = "Head preview";
            var artifact = artifacts.FirstOrDefault(item => item.IsHeadPreview);
            if (artifact == null) { artifact = new Artifact("Head preview", path, IsHeadPreview: true); artifacts.Add(artifact); }
            refreshingArtifacts = true;
            try { artifactPicker.SelectedItem = artifact; }
            finally { refreshingArtifacts = false; }
        }
        if (headPreviewCache.TryGetValue(project.Id, out var cached) && cached.Key == key)
        {
            headPreviewTimer?.Stop();
            headPreviewGeneration++;
            headPreviewPending = false;
            requestedHeadPreviewKey = key;
            if (currentMesh == null || !SamePath(currentMesh.Path, path) || displayedHeadPreviewKey != key) ShowHeadPreview(project, cached);
            ShowPreviewLoading(null);
            return;
        }
        if (headPreviewPending && requestedHeadPreviewKey == key) return;
        if (!focus && requestedHeadPreviewKey == key) return;
        requestedHeadPreviewKey = key;
        headPreviewPending = true;
        headPreviewGeneration++;
        ShowPreviewLoading("Updating head preview…");
        headPreviewTimer ??= CreateHeadPreviewTimer();
        headPreviewTimer.Stop();
        headPreviewTimer.Start();
    }

    DispatcherTimer CreateHeadPreviewTimer()
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        timer.Tick += async (_, _) => { timer.Stop(); await RefreshHeadPreviewAsync(); };
        return timer;
    }

    async Task RefreshHeadPreviewAsync()
    {
        var generation = headPreviewGeneration;
        var key = requestedHeadPreviewKey ?? "";
        if (selectedProject is not { } project || !SamePath(selectedArtifactPath, HeadPreviewPath(project))) return;
        bool Current() => !shutdownCleanupDone && generation == headPreviewGeneration && selectedProject?.Id == project.Id && SamePath(selectedArtifactPath, HeadPreviewPath(project));
        var left = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
        var right = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
        void Message(string text) { if (!Current()) return; headPreviewPending = false; ShowPreviewLoading(null); viewerPlaceholder.Text = text; viewerPlaceholder.Visibility = Visibility.Visible; }
        if (left == null && right == null) { Message("Choose an ear mesh to preview the head."); return; }
        var values = ProjectDocument.FormValues(project);
        var invalid = values.Keys.Where(id => (id.StartsWith("head.", StringComparison.Ordinal) || id.StartsWith("torso.", StringComparison.Ordinal)) || id == "mesh2hrtf.ear_distance")
            .Select(id => SettingsCatalog.Check(values, id)).FirstOrDefault(message => message != null);
        if (invalid != null) { Message(invalid); return; }
        var folder = Path.Combine(Path.GetDirectoryName(HeadPreviewPath(project))!, Guid.NewGuid().ToString("N"));
        ShowPreviewLoading("Updating head preview…");
        try
        {
            var preprocessing = ProjectDocument.Build(project, currentEnvironment)["preprocessing"];
            var reply = await RequestPythonAsync("project", new { action = "head-preview", left, right, preprocessing, folder });
            if (!Current()) return;
            var head = reply.GetProperty("head").GetString()!;
            var ears = new[] { "left", "right" }.Where(side => reply.TryGetProperty(side, out _)).Select(side => reply.GetProperty(side).GetString()!).ToArray();
            var loaded = await Task.Run(() => {
                var mesh = MeshLoader.Load(head);
                var earMeshes = ears.Select(path => {
                    var geometry = NativeEditor.RawMesh(path);
                    var positions = geometry.Positions ?? throw new InvalidDataException("Ear preview contains no vertices.");
                    for (var i = 0; i < positions.Count; i++) positions[i] = mesh.ToDisplay(positions[i]);
                    NativeEditor.Normals(geometry);
                    return geometry;
                }).ToArray();
                return (mesh, earMeshes);
            });
            if (!Current()) return;
            var cached = new CachedHeadPreview(key, loaded.mesh, loaded.earMeshes);
            headPreviewCache[project.Id] = cached;
            ShowHeadPreview(project, cached);
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or KeyNotFoundException or OperationCanceledException)
        { Message(error.Message); }
        finally
        {
            if (Current()) { headPreviewPending = false; ShowPreviewLoading(null); }
            try { if (Path.GetFullPath(folder).StartsWith(Path.GetFullPath(Path.GetDirectoryName(HeadPreviewPath(project))!) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && Directory.Exists(folder)) Directory.Delete(folder, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    void ShowHeadPreview(ProjectRecord project, CachedHeadPreview cached)
    {
        displayedHeadPreviewKey = cached.Key;
        SaveMeshCamera();
        RemoveMeshVisuals();
        currentMesh = new MeshData(HeadPreviewPath(project), cached.Head.Geometry, cached.Head.Center, cached.Head.Scale, cached.Head.MaximumDimension);
        meshVisual = NativeEditor.Model(currentMesh.Geometry);
        meshVisual.Material = new PhongMaterial { DiffuseColor = new Color4(.7f, .7f, .7f, 1), AmbientColor = new Color4(.5f, .5f, .5f, 1) };
        meshViewport.Items.Add(meshVisual); meshVisuals.Add(meshVisual);
        foreach (var geometry in cached.Ears)
        {
            var ear = NativeEditor.Model(geometry);
            ear.Material = new PhongMaterial { DiffuseColor = new Color4(1f, .58f, .12f, 1), AmbientColor = new Color4(.5f, .5f, .5f, 1) };
            meshViewport.Items.Add(ear); meshVisuals.Add(ear);
        }
        ResetMeshCamera();
        viewerPlaceholder.Visibility = Visibility.Collapsed;
        viewerInteractionHint.Visibility = Visibility.Visible;
        resetViewButtonHost.Visibility = Visibility.Visible;
        meshViewport.Visibility = Visibility.Visible;
        UpdatePlacementButtons();
    }

    readonly TextBlock geometryDescription = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    readonly Dictionary<string, GeometryValues> geometryCache = [];
    readonly Dictionary<string, Task<GeometryValues>> geometryRequests = [];
    GeometryValues? displayedGeometry;
    bool geometryEditing;
    bool registrySavingBlocked;
    static string GeometryDisplay(double value) => value.ToString("F2", System.Globalization.CultureInfo.InvariantCulture);

    Grid GeometryPanel()
    {
        var panel = new StackPanel();
        panel.Children.Add(AddSettingPanel("Ear distance from head center (mm)", "mesh2hrtf.ear_distance", earDistanceBox));
        var footer = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        geometryDescription.VerticalAlignment = VerticalAlignment.Top;
        footer.Children.Add(geometryDescription);
        var reset = new Button { Content = "Reset from meshes", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
        reset.Click += async (_, _) => await EditGeometryAsync("reset", "");
        Grid.SetColumn(reset, 1);
        footer.Children.Add(reset);
        panel.Children.Add(footer);
        var shape = new List<FrameworkElement>();
        shape.Add(AddSettingPanel("Ear-to-ear radius scale", "head.radius_scale", headRadiusScaleBox));
        shape.Add(AddSettingPanel("Front-to-back scale", "head.width_scale", headWidthScaleBox));
        shape.Add(AddSettingPanel("Height scale", "head.height_scale", headHeightScaleBox));
        shape.Add(AddSettingPanel("Head taper (%)", "head.taper_percent", headTaperPercentBox));
        AddExpander(panel, "Head shape", shape);
        headShapeExpander = (Expander)panel.Children[^1];
        headShapeExpander.Expanding += (_, _) => RequestHeadPreview(true);
        torsoModePicker.Items.Add(new ComboBoxItem { Content = "Off", Tag = "off" });
        torsoModePicker.Items.Add(new ComboBoxItem { Content = "Geometric", Tag = "geometric" });
        torsoModePicker.Items.Add(new ComboBoxItem { Content = "Acoustic (not available yet)", Tag = "acoustic", IsEnabled = false });
        panel.Children.Add(AddSettingPanel("Torso modelling", "torso.mode", torsoModePicker));
        var torso = new List<FrameworkElement>();
        torso.Add(AddSettingPanel("Torso width (mm)", "torso.width", torsoWidthBox));
        torso.Add(AddSettingPanel("Torso depth (mm)", "torso.depth", torsoDepthBox));
        torso.Add(AddSettingPanel("Torso height (mm)", "torso.height", torsoHeightBox));
        AddExpander(panel, "Torso shape", torso);
        torsoShapeExpander = (Expander)panel.Children[^1];
        torsoShapeExpander.Expanding += (_, _) => RequestHeadPreview(true);
        torsoModePicker.SelectionChanged += async (_, _) => {
            UpdateTorsoControls();
            if (loading) return;
            await HandleSettingChangeAsync("torso.mode");
            RequestHeadPreview(true);
        };
        UpdateTorsoControls();
        var grid = new Grid();
        grid.Children.Add(panel);
        return grid;
    }

    GeometryValues ApplyGeometrySettings(GeometryValues measured, PreprocessingSettings settings) =>
        settings.EarDistance == null ? measured : measured.AtDistance(HeadGeometry.Parse(settings.EarDistance));

    async void RefreshGeometry()
    {
        var toolRevision = toolEnvironmentRevision;
        try
        {
            var project = selectedProject;
            if (project == null || geometryEditing) return;
            var left = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
            var right = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
            var key = toolRevision + "|" + project.Id + "|" + left + "|" + (left == null ? "" : MeshIdentity(left)) + "|" + right + "|" + (right == null ? "" : MeshIdentity(right));
            RequestHeadPreview();
            if (left == null && right == null)
            {
                displayedGeometry = null;
                loading = true;
                SetGeometryInputText("");
                loading = false;
                geometryDescription.Text = "Load an ear mesh to calculate its distance from the head center.";
                return;
            }
            if (!geometryCache.TryGetValue(key, out var measured))
            {
                displayedGeometry = null;
                geometryDescription.Text = "Calculating geometry…";
                if (!geometryRequests.TryGetValue(key, out var request)) geometryRequests[key] = request = InspectGeometry(left, right);
                try { measured = await request; geometryCache[key] = measured; }
                finally { geometryRequests.Remove(key); }
            }
            if (selectedProject != project || geometryEditing || toolEnvironmentRevision != toolRevision) return;
            var nowLeft = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
            var nowRight = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
            var currentKey = toolRevision + "|" + project.Id + "|" + nowLeft + "|" + (nowLeft == null ? "" : MeshIdentity(nowLeft)) + "|" + nowRight + "|" + (nowRight == null ? "" : MeshIdentity(nowRight));
            if (currentKey != key) { RefreshGeometry(); return; }
            try { displayedGeometry = ApplyGeometrySettings(measured, project.Settings.Preprocessing); }
            catch (Exception error)
            {
                displayedGeometry = measured;
                SetGeometryInputText(project.Settings.Preprocessing.EarDistance ?? GeometryDisplay(measured.Distance));
                geometryDescription.Text = error.Message;
                return;
            }
            loading = true;
            SetGeometryInputText(GeometryDisplay(displayedGeometry.Distance));
            loading = false;
            geometryDescription.Text = $"Left: {(displayedGeometry.Left is double l ? GeometryDisplay(l) : "—")} mm; Right: {(displayedGeometry.Right is double r ? GeometryDisplay(r) : "—")} mm.";
        }
        catch (Exception error) { loading = false; displayedGeometry = null; geometryDescription.Text = error.Message; }
    }

    async Task<GeometryValues> InspectGeometry(string? left, string? right)
    {
        var info = GeometryProcess("-m", "HRTFCalculation", "geometry");
        if (left != null) { info.ArgumentList.Add("--left"); info.ArgumentList.Add(left); }
        if (right != null) { info.ArgumentList.Add("--right"); info.ArgumentList.Add(right); }
        var result = await ToolProcess.RunAsync(info, null, TimeSpan.FromSeconds(180), editorLifetime.Token);
        if (result.ExitCode != 0) throw new IOException(result.Error.Trim());
        return JsonSerializer.Deserialize<GeometryValues>(result.Output) ?? throw new IOException("No geometry measurements returned.");
    }

    async Task EditGeometryAsync(string field, string text)
    {
        var project = selectedProject;
        if (loading || geometryEditing || project == null) return;
        if (ProjectBusy(project.Id)) { LoadSelectedProject(); return; }
        var before = displayedGeometry;
        if (field != "reset" && before != null && text == GeometryDisplay(before.Distance)) return;
        GeometryValues? desired = null;
        try
        {
            if (field != "reset")
            {
                if (before == null) throw new InvalidDataException("Wait for geometry measurements before editing.");
                var number = HeadGeometry.Parse(text);
                if (number == (before.Distance)) return;
                desired = before.AtDistance(number);
            }
            geometryEditing = true;
            LoadSelectedProject();
            await ReconcileOutputsAsync(project, true);
            if (selectedProject != project) return;
            if (Directory.Exists(project.SaveLocation) && HasOutputsFrom(Stage.Preprocessing, project))
            {
                var dialog = new ContentDialog { Title = "Reset pipeline outputs?", Content = "Changing geometry resets Preprocessing and all following outputs. The ear distance will be applied to both ears, preserving their difference.", PrimaryButtonText = "Reset and apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary || selectedProject != project) return;
                if (!await ResetProjectOutputsAsync(project, Stage.Preprocessing) || selectedProject != project) return;
            }
            project.Settings.Preprocessing.EarDistance = desired != null ? HeadGeometry.Number(desired.Distance) : null;
            Persist();
            RefreshPipelineStatus();
            RequestHeadPreview(true);
        }
        catch (Exception error) { geometryDescription.Text = error.Message; AppendLog("Geometry: " + error.Message, project.Id); }
        finally { geometryEditing = false; LoadSelectedProject(); }
    }

    string GeometryYaml(PreprocessingSettings p)
    {
        if (p.EarDistance == null) return "";
        var value = HeadGeometry.Parse(p.EarDistance);
        if (value <= 0) throw new InvalidDataException("Ear distance must be positive.");
        return "  ear_distance: " + HeadGeometry.Number(value) + "\n";
    }

    ProcessStartInfo GeometryProcess(params string[] arguments)
    {
        var python = BundledPythonExecutable();
        if (python != null && !File.Exists(python)) throw new IOException("The Python executable is unavailable. Check Tools in App settings.");
        if (python == null && !File.Exists(environment.UvExecutable)) throw new IOException("The Python runtime and uv executable are unavailable. Check Tools in App settings.");
        var info = new ProcessStartInfo(python ?? environment.UvExecutable)
        { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        if (python == null)
        {
            info.ArgumentList.Add("run"); info.ArgumentList.Add("--offline"); info.ArgumentList.Add("--no-sync"); info.ArgumentList.Add("--project"); info.ArgumentList.Add(packageRoot); info.ArgumentList.Add("python");
        }
        info.ArgumentList.Add("-X"); info.ArgumentList.Add("utf8");
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        ApplyProcessEnvironment(info);
        return info;
    }

    string EarDistanceInputStamp(ProjectRecord project)
    {
        var paths = new[] {
            PreprocessingMesh(project, "left") ?? project.LeftEar,
            PreprocessingMesh(project, "right") ?? project.RightEar
        };
        return string.Join("|", paths.Select(path => path + ":" + (File.Exists(path) ? MeshIdentity(path) : ""))) +
            "|" + project.Settings.Preprocessing.EarDistance + "|" + project.SaveLocation;
    }

    async Task<bool> ConfirmEarDistanceAsync(ProjectRecord project)
    {
        var stamp = EarDistanceInputStamp(project);
        var left = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
        var right = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
        var values = ApplyGeometrySettings(await InspectGeometry(left, right), project.Settings.Preprocessing);
        if (stamp != EarDistanceInputStamp(project))
            throw new InvalidOperationException("Project inputs changed while measuring ear distance. Start preprocessing again.");
        values.Validate();
        if (!HeadGeometry.NeedsWarning(values.Distance)) return true;
        var dialog = new ContentDialog {
            Title = "Ear meshes are close to the head center",
            Content = $"The ear distance from the head center is {GeometryDisplay(values.Distance)} mm. This will produce a very small head. You can proceed anyway or cancel to adjust the distance.",
            PrimaryButtonText = "Proceed anyway", CloseButtonText = "Cancel and adjust",
            DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            if (stamp != EarDistanceInputStamp(project))
                throw new InvalidOperationException("Project inputs changed while the warning was open. Start preprocessing again.");
            return true;
        }
        queuedStages.Remove(project.Id);
        _ = FocusEarDistanceAsync(project);
        return false;
    }

    async Task FocusEarDistanceAsync(ProjectRecord project)
    {
        await Task.Delay(120);
        selectedProject = project;
        RefreshProjectList();
        LoadSelectedProject();
        var section = settingSections.FirstOrDefault(x => Equals(x.Header, "Mesh2HRTF"));
        if (section != null) section.IsExpanded = true;
        await Task.Delay(120);
        earDistanceBox.StartBringIntoView();
        earDistanceBox.Focus(FocusState.Programmatic);
        earDistanceBox.SelectAll();
    }
}
