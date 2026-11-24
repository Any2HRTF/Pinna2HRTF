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
    readonly TextBox headYDeformationBox = new();
    readonly TextBox headOvalnessStrengthBox = new();
    readonly TextBox headMinWidthScaleBox = new();
    readonly TextBox headMaxHeightScaleBox = new();
    readonly CheckBox headAdaptiveOvalnessBox = new();
    readonly List<FrameworkElement> headOvalnessRows = [];
    Expander? headShapeExpander;
    Viewport3DX? headPreviewViewport;
    readonly TextBlock headPreviewMessage = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12) };
    readonly List<Element3D> headPreviewModels = [];
    DispatcherTimer? headPreviewTimer;
    int headPreviewGeneration;

    void AddHeadShapeTextSettings(Dictionary<string, TextSetting> settings)
    {
        settings["head.radius_scale"] = new(headRadiusScaleBox, p => p.Settings.Preprocessing.HeadRadiusScale, (p, v) => p.Settings.Preprocessing.HeadRadiusScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_radius_scale"));
        settings["head.width_scale"] = new(headWidthScaleBox, p => p.Settings.Preprocessing.HeadWidthScale, (p, v) => p.Settings.Preprocessing.HeadWidthScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_width_scale"));
        settings["head.height_scale"] = new(headHeightScaleBox, p => p.Settings.Preprocessing.HeadHeightScale, (p, v) => p.Settings.Preprocessing.HeadHeightScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_height_scale"));
        settings["head.y_deformation"] = new(headYDeformationBox, p => p.Settings.Preprocessing.HeadYDeformation, (p, v) => p.Settings.Preprocessing.HeadYDeformation = v.Trim(), SettingsCatalog.Text("preprocessing.head_y_deformation"));
        settings["head.ovalness_strength"] = new(headOvalnessStrengthBox, p => p.Settings.Preprocessing.HeadOvalnessStrength, (p, v) => p.Settings.Preprocessing.HeadOvalnessStrength = v.Trim(), SettingsCatalog.Text("preprocessing.head_ovalness_strength"));
        settings["head.min_width_scale"] = new(headMinWidthScaleBox, p => p.Settings.Preprocessing.HeadMinWidthScale, (p, v) => p.Settings.Preprocessing.HeadMinWidthScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_min_width_scale"));
        settings["head.max_height_scale"] = new(headMaxHeightScaleBox, p => p.Settings.Preprocessing.HeadMaxHeightScale, (p, v) => p.Settings.Preprocessing.HeadMaxHeightScale = v.Trim(), SettingsCatalog.Text("preprocessing.head_max_height_scale"));
    }

    FrameworkElement HeadPreviewPanel()
    {
        headPreviewViewport = new Viewport3DX
        {
            IsRotationEnabled = true, IsPanEnabled = false, IsMoveEnabled = false, IsZoomEnabled = false,
            IsInertiaEnabled = false, UseDefaultGestures = true, CameraRotationMode = CameraRotationMode.Turntable,
            ShowCoordinateSystem = false, ShowViewCube = false, ModelUpDirection = new System.Numerics.Vector3(0, 0, 1),
            EffectsManager = new DefaultEffectsManager(), BackgroundColor = ColorHelper.FromArgb(255, 237, 243, 242)
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(headPreviewViewport, "Head shape preview");
        EvenMeshLighting.Install(headPreviewViewport);
        var host = new Grid { Height = 240, Margin = new Thickness(0, 8, 0, 0), CornerRadius = new CornerRadius(6) };
        host.Children.Add(headPreviewViewport);
        host.Children.Add(headPreviewMessage);
        return host;
    }

    void RequestHeadPreview()
    {
        if (headShapeExpander?.IsExpanded != true) return;
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
        var generation = ++headPreviewGeneration;
        if (selectedProject is not { } project || headPreviewViewport == null) return;
        var left = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
        var right = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
        if (left == null && right == null) { ShowHeadPreviewMessage("Choose an ear mesh to preview the head."); return; }
        var values = ProjectDocument.FormValues(project);
        var invalid = values.Keys.Where(id => id.StartsWith("head.", StringComparison.Ordinal) || id == "mesh2hrtf.ear_distance").Order()
            .Select(id => SettingsCatalog.Check(values, id)).FirstOrDefault(message => message != null);
        if (invalid != null) { ShowHeadPreviewMessage(invalid); return; }
        var folder = Path.Combine(appData, "Cache", "Head Preview", project.Id.ToString());
        headPreviewMessage.Text = "Updating preview…";
        try
        {
            var preprocessing = ProjectDocument.Build(project, currentEnvironment)["preprocessing"];
            var reply = await RequestPythonAsync("project", new { action = "head-preview", left, right, preprocessing, folder });
            if (generation != headPreviewGeneration) return;
            var head = reply.GetProperty("head").GetString()!;
            var ears = new[] { "left", "right" }.Where(side => reply.TryGetProperty(side, out _)).Select(side => reply.GetProperty(side).GetString()!).ToList();
            ShowHeadPreview(head, ears);
        }
        catch (Exception error) when (error is IOException or InvalidDataException or JsonException or InvalidOperationException or KeyNotFoundException)
        {
            if (generation == headPreviewGeneration) ShowHeadPreviewMessage(error.Message);
        }
    }

    void ShowHeadPreviewMessage(string message)
    {
        foreach (var model in headPreviewModels) headPreviewViewport?.Items.Remove(model);
        headPreviewModels.Clear();
        headPreviewMessage.Text = message;
    }

    void ShowHeadPreview(string head, IEnumerable<string> ears)
    {
        if (headPreviewViewport == null) return;
        ShowHeadPreviewMessage("");
        MeshGeometryModel3D Add(string path, Color4 color)
        {
            var geometry = NativeEditor.RawMesh(path);
            NativeEditor.Normals(geometry);
            var model = NativeEditor.Model(geometry);
            model.Material = new PhongMaterial { DiffuseColor = color, AmbientColor = new Color4(.5f, .5f, .5f, 1) };
            headPreviewViewport.Items.Add(model);
            headPreviewModels.Add(model);
            return model;
        }
        var headModel = Add(head, new Color4(.78f, .78f, .78f, 1));
        foreach (var ear in ears) Add(ear, new Color4(1f, .58f, .12f, 1));
        var points = headModel.Geometry!.Positions!.ToArray();
        var low = points.Aggregate(System.Numerics.Vector3.Min);
        var high = points.Aggregate(System.Numerics.Vector3.Max);
        var center = (low + high) / 2;
        var size = System.Numerics.Vector3.Distance(low, high);
        var offset = new System.Numerics.Vector3(size * 1.6f, -size * .25f, size * .33f);
        headPreviewViewport.Camera = new PerspectiveCamera { Position = center + offset, LookDirection = -offset, UpDirection = System.Numerics.Vector3.UnitZ,
            FieldOfView = 34, NearPlaneDistance = size / 1000, FarPlaneDistance = size * 100 };
    }

    void UpdateHeadShapeControls()
    {
        foreach (var row in headOvalnessRows)
            row.Visibility = headAdaptiveOvalnessBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        RequestHeadPreview();
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
        shape.Add(AddSettingPanel("Width change with height (1/mm)", "head.y_deformation", headYDeformationBox));
        shape.Add(AddSettingPanel("Adapt shape to ears", "head.adaptive_ovalness", headAdaptiveOvalnessBox));
        headOvalnessRows.Add(AddSettingPanel("Adaptation strength", "head.ovalness_strength", headOvalnessStrengthBox));
        headOvalnessRows.Add(AddSettingPanel("Smallest front-to-back scale", "head.min_width_scale", headMinWidthScaleBox));
        headOvalnessRows.Add(AddSettingPanel("Largest height scale", "head.max_height_scale", headMaxHeightScaleBox));
        shape.AddRange(headOvalnessRows);
        shape.Add(HeadPreviewPanel());
        headAdaptiveOvalnessBox.Checked += (_, _) => UpdateHeadShapeControls();
        headAdaptiveOvalnessBox.Unchecked += (_, _) => UpdateHeadShapeControls();
        AddExpander(panel, "Head shape", shape);
        headShapeExpander = (Expander)panel.Children[^1];
        headShapeExpander.Expanding += (_, _) => RequestHeadPreview();
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
