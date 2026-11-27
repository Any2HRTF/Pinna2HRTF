using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using CommunityToolkit.WinUI.Controls;
using Windows.System;
using Windows.Storage.Pickers;

namespace Pinna2HRTF.Windows;

internal sealed class AppPreferences
{
    public int Version { get; set; } = 1;
    public string ProjectDirectory { get; set; } = "";
    public InputHandling InputHandling { get; set; } = InputHandling.Copy;
    public string EvaluationGrid { get; set; } = "";
    public int MinimumFrequency { get; set; } = SettingsCatalog.Whole("preprocessing.min_frequency");
    public int MaximumFrequency { get; set; } = SettingsCatalog.Whole("preprocessing.max_frequency");
    public int FrequencySteps { get; set; } = SettingsCatalog.Whole("preprocessing.frequency_step_count");
    public int MaxInstances { get; set; } = SettingsCatalog.Whole("numcalc.max_instances");
    public int MaxCpuLoad { get; set; } = SettingsCatalog.Whole("numcalc.max_cpu_load");
    public bool NotifyAll { get; set; } = true;
    public bool NotifyCompletion { get; set; } = true;
    public bool NotifyFailure { get; set; } = true;
    public bool DeveloperMode { get; set; }
    public string NumCalc { get; set; } = "";
    public string MeshGrading { get; set; } = "";
    public string Python { get; set; } = "";
    public string Uv { get; set; } = "";
    public string ExternalDirectory { get; set; } = "";
    public string Mesh2Hrtf { get; set; } = "";
    public WorkflowPreferences Workflow { get; set; } = new();

    public Dictionary<string, string> FormValues()
    {
        var values = Workflow.FormValues();
        values["mesh2hrtf.min_frequency"] = MinimumFrequency.ToString(CultureInfo.InvariantCulture);
        values["mesh2hrtf.max_frequency"] = MaximumFrequency.ToString(CultureInfo.InvariantCulture);
        values["mesh2hrtf.frequency_steps"] = FrequencySteps.ToString(CultureInfo.InvariantCulture);
        values["numcalc.parallel_instances"] = MaxInstances.ToString(CultureInfo.InvariantCulture);
        values["numcalc.cpu_limit"] = MaxCpuLoad.ToString(CultureInfo.InvariantCulture);
        return values;
    }
}

internal sealed class WorkflowPreferences
{
    public bool FullHeadScan { get; set; } = SettingsCatalog.Flag("scan_preparation.enabled");
    public bool PrepareLeft { get; set; } = SettingsCatalog.Flag("scan_preparation.prepare_left");
    public bool PrepareRight { get; set; } = SettingsCatalog.Flag("scan_preparation.prepare_right");
    public bool RequireManualReview { get; set; } = SettingsCatalog.Flag("scan_preparation.require_manual_review");
    public string EarModelMethod { get; set; } = "none";
    public string InferenceModel { get; set; } = Path.GetFileNameWithoutExtension(SettingsCatalog.Text("inference.model_config_file"));
    public double TargetEdgeMm { get; set; } = SettingsCatalog.Decimal("scan_preparation.target_edge_mm");
    public double LeftMarginMm { get; set; } = SettingsCatalog.Decimal("scan_preparation.left_margin_mm");
    public double RightMarginMm { get; set; } = SettingsCatalog.Decimal("scan_preparation.right_margin_mm");
    public double SideMinMm { get; set; } = SettingsCatalog.Decimal("scan_preparation.side_min_mm");
    public double SideMaxMm { get; set; } = SettingsCatalog.Decimal("scan_preparation.side_max_mm");
    public int SourceAssignmentFaceCount { get; set; } = SettingsCatalog.Whole("preprocessing.source_assignment_face_count");
    public double MeshMinEdgeLength { get; set; } = SettingsCatalog.Decimal("preprocessing.mesh_min_edge_length");
    public double MeshMaxEdgeLength { get; set; } = SettingsCatalog.Decimal("preprocessing.mesh_max_edge_length");
    public double MeshMaxError { get; set; } = SettingsCatalog.Decimal("preprocessing.mesh_max_error");
    public double MeshGamma { get; set; } = SettingsCatalog.Decimal("preprocessing.mesh_gamma");
    public double MeshGammaOpposite { get; set; } = SettingsCatalog.Decimal("preprocessing.mesh_gamma_opposite");
    public bool AdaptiveFmmLength { get; set; } = SettingsCatalog.Flag("numcalc.adaptive_fmm_length");
    public bool Normalize { get; set; } = SettingsCatalog.Flag("postprocessing.normalize");
    public double LevelOffsetDb { get; set; } = SettingsCatalog.Decimal("postprocessing.level_offset_db");
    public bool ResampleHrirs { get; set; } = SettingsCatalog.Flag("postprocessing.resample_hrirs");
    public int SamplingRate { get; set; } = SettingsCatalog.Whole("postprocessing.sampling_rate");
    public bool SpatialUpsampling { get; set; } = SettingsCatalog.Flag("postprocessing.spatial_upsampling");
    public int SpatialSubdivisions { get; set; } = SettingsCatalog.Whole("postprocessing.spatial_subdivisions");
    public bool SpatialNormalize { get; set; } = SettingsCatalog.Flag("postprocessing.spatial_normalize");
    public double HeadRadiusScale { get; set; } = SettingsCatalog.Decimal("preprocessing.head_radius_scale");
    public double HeadWidthScale { get; set; } = SettingsCatalog.Decimal("preprocessing.head_width_scale");
    public double HeadHeightScale { get; set; } = SettingsCatalog.Decimal("preprocessing.head_height_scale");
    public AcousticTorsoPreferences AcousticTorso { get; set; } = new();
    public string TorsoMode { get; set; } = SettingsCatalog.Text("preprocessing.torso_mode");
    public double TorsoWidthMM { get; set; } = SettingsCatalog.Decimal("preprocessing.torso_width_mm");
    public double TorsoDepthMM { get; set; } = SettingsCatalog.Decimal("preprocessing.torso_depth_mm");
    public double TorsoHeightMM { get; set; } = SettingsCatalog.Decimal("preprocessing.torso_height_mm");
    public double HeadTaperPercent { get; set; } = SettingsCatalog.Decimal("preprocessing.head_taper_percent");
    public string EarCanalCloserMode { get; set; } = SettingsCatalog.Text("preprocessing.ear_canal_closer_mode");
    public string EarCutMode { get; set; } = SettingsCatalog.Text("preprocessing.ear_cut_mode");
    public double EarCutClearanceScale { get; set; } = SettingsCatalog.Decimal("preprocessing.ear_cut_clearance_scale");
    public double ProjectedCutMargin { get; set; } = SettingsCatalog.Decimal("preprocessing.projected_cut_margin");
    public int SeamSmoothingIterations { get; set; } = SettingsCatalog.Whole("preprocessing.seam_smoothing_iterations");
    public double SeamSmoothingFactor { get; set; } = SettingsCatalog.Decimal("preprocessing.seam_smoothing_factor");

    public Dictionary<string, string> FormValues()
    {
        static string Number(double value) => value.ToString("R", CultureInfo.InvariantCulture);
        static string Whole(int value) => value.ToString(CultureInfo.InvariantCulture);
        var values = new Dictionary<string, string>()
        {
            ["scan.enabled"] = "true", ["scan.prepare_left"] = PrepareLeft ? "true" : "false", ["scan.prepare_right"] = PrepareRight ? "true" : "false",
            ["scan.target_edge"] = Number(TargetEdgeMm), ["scan.left_margin"] = Number(LeftMarginMm), ["scan.right_margin"] = Number(RightMarginMm),
            ["scan.side_min"] = Number(SideMinMm), ["scan.side_max"] = Number(SideMaxMm),
            ["mesh2hrtf.microphone_faces"] = Whole(SourceAssignmentFaceCount),
            ["mesh_grading.min_edge_length"] = Number(MeshMinEdgeLength), ["mesh_grading.max_edge_length"] = Number(MeshMaxEdgeLength),
            ["mesh_grading.max_error"] = Number(MeshMaxError), ["mesh_grading.gamma"] = Number(MeshGamma), ["mesh_grading.gamma_opposite"] = Number(MeshGammaOpposite),
            ["postprocessing.level_offset"] = Number(LevelOffsetDb), ["postprocessing.sampling_rate"] = Whole(SamplingRate),
            ["postprocessing.spatial_subdivisions"] = Whole(SpatialSubdivisions),
            ["postprocessing.normalize"] = Normalize ? "true" : "false",
            ["postprocessing.resample_hrirs"] = ResampleHrirs ? "true" : "false",
            ["postprocessing.spatial_upsampling"] = SpatialUpsampling ? "true" : "false",
            ["head.radius_scale"] = Number(HeadRadiusScale),
            ["head.width_scale"] = Number(HeadWidthScale),
            ["head.height_scale"] = Number(HeadHeightScale),
            ["head.taper_percent"] = Number(HeadTaperPercent),
            ["torso.mode"] = TorsoMode,
            ["ear.canal_closure"] = EarCanalCloserMode, ["attachment.cut_mode"] = EarCutMode,
            ["attachment.clearance"] = Number(EarCutClearanceScale), ["attachment.margin"] = Number(ProjectedCutMargin),
            ["attachment.smoothing_passes"] = Whole(SeamSmoothingIterations), ["attachment.smoothing_strength"] = Number(SeamSmoothingFactor),
            ["torso.width"] = Number(TorsoWidthMM),
            ["torso.depth"] = Number(TorsoDepthMM),
            ["torso.height"] = Number(TorsoHeightMM),

        };
        var acoustic = JsonSerializer.SerializeToNode(AcousticTorso, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower })!.AsObject();
        foreach (var value in acoustic) values["acoustic_torso." + value.Key] = value.Value?.ToString().ToLowerInvariant() ?? "";
        return values;
    }

    public bool Valid() => SettingsCatalog.Issues(FormValues(), null).Count == 0
        && EarModelMethod is "none" or "manual" or "mesh2ppm" && !string.IsNullOrEmpty(InferenceModel);
}

public partial class MainWindow
{
    AppPreferences appPreferences = new();
    Grid? appSettingsPage;
    Control? settingsReturnFocus;
    FrameworkElement? settingsWorkspaceHeader;
    UIElement? settingsWorkspaceDragRegion;
    GridLength settingsWorkspaceTitleHeight;
    string? settingsWorkspaceTitle;
    TitleBar? settingsTitleBar;
    Action? refreshAppSettingsStatus;
    Action? refreshToolSettings;
    string? preferencesLoadError;
    ProjectRecord? initialProject;
    string AppPreferencesPath => Path.Combine(appData, "app-settings.json");
    readonly AsyncLocal<ToolEnvironment?> operationTools = new();
    int toolEnvironmentRevision;
    sealed record ToolEnvironment(EnvironmentConfig Environment, string? Python);
    string? PythonOverride => operationTools.Value?.Python ?? (operationTools.Value == null && appPreferences.DeveloperMode && appPreferences.Python.Length > 0 ? appPreferences.Python : null);
    sealed class ToolScope(AsyncLocal<ToolEnvironment?> slot, ToolEnvironment? previous) : IDisposable
    {
        public void Dispose() => slot.Value = previous;
    }
    ToolEnvironment EffectiveTools() => operationTools.Value ?? new(currentEnvironment, PythonOverride);
    IDisposable CaptureTools(ToolEnvironment? snapshot = null)
    {
        var previous = operationTools.Value;
        operationTools.Value = snapshot ?? EffectiveTools();
        return new ToolScope(operationTools, previous);
    }

    void LoadAppPreferences()
    {
        if (!File.Exists(AppPreferencesPath)) return;
        try
        {
            var value = JsonSerializer.Deserialize<AppPreferences>(File.ReadAllText(AppPreferencesPath)) ?? throw new IOException("Empty settings.");
            if (value.Version != 1 || value.Workflow == null || value.Workflow.AcousticTorso == null || SettingsCatalog.Issues(value.FormValues(), null).Count > 0 ||
                !Enum.IsDefined(value.InputHandling) || value.ProjectDirectory == null || value.EvaluationGrid == null ||
                value.NumCalc == null || value.MeshGrading == null || value.Python == null || value.Uv == null || value.ExternalDirectory == null ||
                value.Mesh2Hrtf == null || value.Workflow == null || !value.Workflow.Valid() ||
                !File.Exists(Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources", value.Workflow.InferenceModel + ".yaml")))
                throw new IOException("Invalid settings values or unsupported version.");
            appPreferences = value;
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            preferencesLoadError = "App settings could not be read. Defaults are active. " + error.Message;
        }
    }

    void SaveAppPreferences()
    {
        try
        {
            if (preferencesLoadError != null && File.Exists(AppPreferencesPath))
            {
                File.Copy(AppPreferencesPath, AppPreferencesPath + ".unreadable-" + DateTime.UtcNow.ToString("yyyyMMddHHmmssfff") + ".bak");
                preferencesLoadError = null;
            }
            HeadGeometry.AtomicWrite(AppPreferencesPath, JsonSerializer.Serialize(appPreferences, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            preferencesLoadError = "App settings could not be saved. " + error.Message;
            AppendLog(preferencesLoadError);
        }
    }

    void ApplyAppEnvironment()
    {
        toolEnvironmentRevision++;
        var next = DefaultEnvironment();
        if (appPreferences.DeveloperMode)
        {
            if (appPreferences.NumCalc.Length > 0) next.NumCalcExecutable = appPreferences.NumCalc;
            if (appPreferences.MeshGrading.Length > 0) next.MeshGradingExecutable = appPreferences.MeshGrading;
            if (appPreferences.Uv.Length > 0) next.UvExecutable = appPreferences.Uv;
            if (appPreferences.ExternalDirectory.Length > 0) next.ExternalDir = appPreferences.ExternalDirectory;
            if (appPreferences.Mesh2Hrtf.Length > 0) next.Mesh2HrtfPath = appPreferences.Mesh2Hrtf;
        }
        currentEnvironment = next;
        geometryCache.Clear();
        statusSnapshots.Clear();
        if (statusTimer.IsRunning) { RefreshPipelineStatus(); RefreshGeometry(); }
    }

    async Task ApplyNewProjectDefaultsAsync(ProjectRecord project, int? index = null)
    {
        var preferences = JsonSerializer.Deserialize<AppPreferences>(JsonSerializer.Serialize(appPreferences))!;
        var reply = await RequestNewProjectDefaultsAsync(preferences, index ?? projects.Count + 1);
        project.SaveLocation = reply.GetProperty("save_location").GetString()!;
        project.InputHandling = preferences.InputHandling;
        ProjectDocument.Restore(project, JsonNode.Parse(reply.GetProperty("config").GetRawText())!.AsObject());
    }

    Task<JsonElement> RequestNewProjectDefaultsAsync(AppPreferences preferences, int index) =>
        RequestPythonAsync("project", new {
            action = "new-defaults", parent = preferences.ProjectDirectory.Length > 0 ? preferences.ProjectDirectory : Path.Combine(appData, "Projects"),
            index, defaults = new {
                minimum_frequency = preferences.MinimumFrequency, maximum_frequency = preferences.MaximumFrequency,
                frequency_steps = preferences.FrequencySteps, max_instances = preferences.MaxInstances,
                max_cpu_load = preferences.MaxCpuLoad, evaluation_grid = preferences.EvaluationGrid,
                workflow = JsonSerializer.SerializeToNode(preferences.Workflow, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower })
            }
        });

    async Task InitializeInitialProjectAsync(ProjectRecord project)
    {
        var revision = StatusRevision(project);
        var prepared = Clone(project);
        await ApplyNewProjectDefaultsAsync(prepared, 1);
        if (!projects.Contains(project) || StatusRevision(project) != revision) return;
        project.SaveLocation = prepared.SaveLocation;
        project.InputHandling = prepared.InputHandling;
        project.Settings = prepared.Settings;
        project.PreservedConfigJSON = prepared.PreservedConfigJSON;
        Persist();
        if (selectedProject == project) LoadSelectedProject();
        RefreshPipelineStatus();
    }

    void ShowAppSettings()
    {
        if (appSettingsPage != null) return;
        settingsReturnFocus = FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
        settingsWorkspaceHeader = Root.Children.OfType<FrameworkElement>().FirstOrDefault(child => Grid.GetRow(child) == 0);
        settingsWorkspaceDragRegion = windowChrome?.DragRegion;
        settingsWorkspaceTitleHeight = Root.RowDefinitions[0].Height;
        settingsWorkspaceTitle = Title;
        if (settingsWorkspaceHeader != null) settingsWorkspaceHeader.Visibility = Visibility.Collapsed;
        if (contentGrid != null) contentGrid.Visibility = Visibility.Collapsed;

        var navigation = new NavigationView {
            IsSettingsVisible = false, IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsPaneToggleButtonVisible = false, PaneDisplayMode = NavigationViewPaneDisplayMode.Auto,
            OpenPaneLength = 220, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch
        };
        var menu = settingsWorkspaceHeader == null ? null : FindDescendant<MenuBar>(settingsWorkspaceHeader);
        var header = new TitleBar {
            Height = settingsWorkspaceHeader?.ActualHeight is > 0 ? settingsWorkspaceHeader.ActualHeight : 54,
            LeftHeader = new TextBlock {
                Text = "App Settings", FontFamily = menu?.FontFamily ?? new FontFamily("Segoe UI"),
                FontSize = menu?.FontSize ?? 14, FontWeight = menu?.FontWeight ?? Microsoft.UI.Text.FontWeights.Normal,
                Foreground = menu?.Foreground ?? primaryTextBrush, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 0, 0)
            }, IsBackButtonVisible = true, IsBackButtonEnabled = true,
            IsPaneToggleButtonVisible = true, Background = secondarySurfaceBrush
        };
        header.BackRequested += (_, _) => CloseAppSettings();
        header.PaneToggleRequested += (_, _) => navigation.IsPaneOpen = !navigation.IsPaneOpen;
        settingsTitleBar = header;
        Root.RowDefinitions[0].Height = GridLength.Auto;
        Root.Children.Add(header);
        SetTitleBar(header);
        Title = "App Settings";

        var page = new Grid { Background = appBackgroundBrush };
        page.Children.Add(navigation);
        Grid.SetRow(page, 1);
        Root.Children.Add(page);
        appSettingsPage = page;
        var names = new[] { "Project Defaults", "Notifications", "Tools" };
        var icons = new[] { "\uE8B7", "\uEA8F", "\uE90F" };
        for (var i = 0; i < names.Length; i++)
            navigation.MenuItems.Add(new NavigationViewItem { Content = names[i], Tag = names[i], Icon = new FontIcon { Glyph = icons[i] } });
        string? category = null;
        navigation.SelectionChanged += (_, args) => ShowCategory((args.SelectedItem as NavigationViewItem)?.Tag as string ?? names[0]);
        navigation.SelectedItem = navigation.MenuItems[0];

        void ShowCategory(string name)
        {
            var offset = category == name && navigation.Content is ScrollViewer previous ? previous.VerticalOffset : 0;
            category = name;
            refreshToolSettings = name == "Tools" ? () => ShowCategory(name) : null;
            refreshAppSettingsStatus = null;
            var panel = new StackPanel { Spacing = 24, Margin = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Left };
            var heading = new StackPanel { Spacing = 8 };
            var titleRow = new Grid { ColumnSpacing = 16, RowSpacing = 8 };
            titleRow.ColumnDefinitions.Add(new()); titleRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            titleRow.RowDefinitions.Add(new() { Height = GridLength.Auto }); titleRow.RowDefinitions.Add(new() { Height = GridLength.Auto });
            titleRow.Children.Add(new TextBlock { Text = name, FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            heading.Children.Add(titleRow);
            if (name == names[0])
            {
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
                var saveDefaults = new Button { Content = "Save defaults…" };
                var loadDefaults = new Button { Content = "Load defaults…" };
                var resetDefaults = new Button { Content = "Reset to defaults…", VerticalAlignment = VerticalAlignment.Center };
                actions.Children.Add(saveDefaults); actions.Children.Add(loadDefaults); actions.Children.Add(resetDefaults);
                ToolTipService.SetToolTip(resetDefaults, "Reset Project Defaults. Existing projects keep their settings.");
                Grid.SetColumn(actions, 1); titleRow.Children.Add(actions);
                titleRow.SizeChanged += (_, args) => {
                    var narrow = args.NewSize.Width < 780;
                    Grid.SetRow(actions, narrow ? 1 : 0); Grid.SetColumn(actions, narrow ? 0 : 1);
                    Grid.SetColumnSpan(actions, narrow ? 2 : 1);
                    actions.HorizontalAlignment = narrow ? HorizontalAlignment.Left : HorizontalAlignment.Right;
                    actions.Orientation = args.NewSize.Width < 430 ? Orientation.Vertical : Orientation.Horizontal;
                };
                resetDefaults.Click += async (_, _) => { if (await ResetProjectDefaultsAsync()) ShowCategory(names[0]); };
                saveDefaults.Click += async (_, _) => await SaveDefaultsFileAsync();
                loadDefaults.Click += async (_, _) => { if (await LoadDefaultsFileAsync()) ShowCategory(names[0]); };
            }
            if (name == names[0]) heading.Children.Add(new TextBlock {
                Text = "Default settings used for newly created projects.", Foreground = mutedTextBrush, TextWrapping = TextWrapping.Wrap
            });
            panel.Children.Add(heading);
            if (preferencesLoadError != null)
                panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = preferencesLoadError });
            var scroller = new ScrollViewer {
                Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Top
            };
            scroller.SizeChanged += (_, _) => panel.Width = Math.Max(0, Math.Min(1000, scroller.ActualWidth - 48));
            scroller.Loaded += (_, _) => scroller.ChangeView(null, offset, null, true);
            navigation.Content = scroller;
            if (name == names[0])
            {
                var files = SettingsSection(panel, "Project Setup");
                PathRow(files, "Project location", () => appPreferences.ProjectDirectory, v => appPreferences.ProjectDirectory = v,
                    Path.Combine(appData, "Projects"), true);
                var handling = new RadioButtons { ItemsSource = new[] { "Copy into project", "Reference original files" },
                    SelectedIndex = (int)appPreferences.InputHandling, MaxColumns = 1 };
                handling.SelectionChanged += (_, _) => {
                    if (handling.SelectedIndex < 0) return;
                    appPreferences.InputHandling = (InputHandling)handling.SelectedIndex;
                    SaveAppPreferences();
                };
                files.Children.Add(new SettingsCard { Header = DefaultsLabel("Input files", "defaults.input_handling"), Content = handling });
                var defaults = appPreferences.Workflow;
                ChoiceRow(files, "Input source", ["Individual ear meshes", "Full-head scan"], defaults.FullHeadScan ? 1 : 0,
                    i => defaults.FullHeadScan = i == 1);
                var ears = SettingsSection(panel, "Ear preparation & modelling");
                ChoiceRow(ears, "Ear modelling method", ["Mesh2PPM", "Manual PPM fitting", "No ear model"],
                    Array.IndexOf(new[] { "mesh2ppm", "manual", "none" }, defaults.EarModelMethod),
                    i => defaults.EarModelMethod = new[] { "mesh2ppm", "manual", "none" }[i]);
                var models = modelPicker.Items.Cast<string>().ToArray();
                ChoiceRow(ears, "Mesh2PPM model", models, Array.IndexOf(models, defaults.InferenceModel), i => defaults.InferenceModel = models[i]);
                ChoiceRow(ears, "Canal closure", [.. CanalClosureChoices.Select(choice => choice.Title)], ChoiceIndex(CanalClosureChoices, defaults.EarCanalCloserMode),
                    i => defaults.EarCanalCloserMode = CanalClosureChoices[i].Value, "ear.canal_closure");
                ChoiceRow(ears, "Ears to prepare from a full-head scan", ["Left and right", "Left only", "Right only"],
                    defaults.PrepareLeft && defaults.PrepareRight ? 0 : defaults.PrepareLeft ? 1 : 2,
                    i => { defaults.PrepareLeft = i != 2; defaults.PrepareRight = i != 1; });
                SettingsAdvanced(ears, "Ear cropping & remeshing", controls => {
                    NumberRow(controls, "Target edge length (mm)", "scan.target_edge", () => defaults.TargetEdgeMm, v => defaults.TargetEdgeMm = v);
                    NumberRow(controls, "Left crop margin (mm)", "scan.left_margin", () => defaults.LeftMarginMm, v => defaults.LeftMarginMm = v);
                    NumberRow(controls, "Right crop margin (mm)", "scan.right_margin", () => defaults.RightMarginMm, v => defaults.RightMarginMm = v);
                    NumberRow(controls, "Inner crop limit (mm)", "scan.side_min", () => defaults.SideMinMm, v => defaults.SideMinMm = v);
                    NumberRow(controls, "Outer crop limit (mm)", "scan.side_max", () => defaults.SideMaxMm, v => defaults.SideMaxMm = v);
                    SwitchRow(controls, "Require ear review", defaults.RequireManualReview, v => defaults.RequireManualReview = v);
                });
                var simulation = SettingsSection(panel, "Simulation setup");
                IntegerRow(simulation, "Microphone faces", "mesh2hrtf.microphone_faces", () => defaults.SourceAssignmentFaceCount, v => defaults.SourceAssignmentFaceCount = v);
                PathRow(simulation, "Evaluation grid", () => appPreferences.EvaluationGrid, v => appPreferences.EvaluationGrid = v,
                    Path.Combine(packageRoot, "HRTFCalculation", "EvaluationGrids", ProjectDocument.DefaultEvaluationGrid), true, grid: true);
                IntegerRow(simulation, "Lowest frequency (Hz)", "mesh2hrtf.min_frequency", () => appPreferences.MinimumFrequency, v => appPreferences.MinimumFrequency = v);
                IntegerRow(simulation, "Highest frequency (Hz)", "mesh2hrtf.max_frequency", () => appPreferences.MaximumFrequency, v => appPreferences.MaximumFrequency = v);
                IntegerRow(simulation, "Frequency steps", "mesh2hrtf.frequency_steps", () => appPreferences.FrequencySteps, v => appPreferences.FrequencySteps = v);
                SettingsAdvanced(simulation, "Advanced mesh grading", controls => {
                    NumberRow(controls, "Minimum edge length (mm)", "mesh_grading.min_edge_length", () => defaults.MeshMinEdgeLength, v => defaults.MeshMinEdgeLength = v);
                    NumberRow(controls, "Maximum edge length (mm)", "mesh_grading.max_edge_length", () => defaults.MeshMaxEdgeLength, v => defaults.MeshMaxEdgeLength = v);
                    NumberRow(controls, "Maximum error (mm)", "mesh_grading.max_error", () => defaults.MeshMaxError, v => defaults.MeshMaxError = v);
                    NumberRow(controls, "Gamma", "mesh_grading.gamma", () => defaults.MeshGamma, v => defaults.MeshGamma = v);
                    NumberRow(controls, "Gamma opposite", "mesh_grading.gamma_opposite", () => defaults.MeshGammaOpposite, v => defaults.MeshGammaOpposite = v);
                });
                SettingsAdvanced(simulation, "Head shape", controls => {
                    NumberRow(controls, "Ear-to-ear radius scale", "head.radius_scale", () => defaults.HeadRadiusScale, v => defaults.HeadRadiusScale = v);
                    NumberRow(controls, "Front-to-back scale", "head.width_scale", () => defaults.HeadWidthScale, v => defaults.HeadWidthScale = v);
                    NumberRow(controls, "Height scale", "head.height_scale", () => defaults.HeadHeightScale, v => defaults.HeadHeightScale = v);
                    NumberRow(controls, "Head taper (%)", "head.taper_percent", () => defaults.HeadTaperPercent, v => defaults.HeadTaperPercent = v);
                });
                var torsoChoice = new ComboBox { MaxWidth = 280 };
                torsoChoice.Items.Add(new ComboBoxItem { Content = "Off", Tag = "off" });
                torsoChoice.Items.Add(new ComboBoxItem { Content = "Geometric", Tag = "geometric" });
                torsoChoice.Items.Add(new ComboBoxItem { Content = "Acoustic", Tag = "acoustic" });
                torsoChoice.SelectedIndex = defaults.TorsoMode switch { "geometric" => 1, "acoustic" => 2, _ => 0 };
                simulation.Children.Add(new SettingsCard { Header = DefaultsLabel("Torso modelling", "torso.mode"), Content = torsoChoice });
                var torsoShape = SettingsAdvanced(simulation, "Torso shape", controls => {
                    NumberRow(controls, "Torso width (mm)", "torso.width", () => defaults.TorsoWidthMM, v => defaults.TorsoWidthMM = v);
                    NumberRow(controls, "Torso depth (mm)", "torso.depth", () => defaults.TorsoDepthMM, v => defaults.TorsoDepthMM = v);
                    NumberRow(controls, "Torso height (mm)", "torso.height", () => defaults.TorsoHeightMM, v => defaults.TorsoHeightMM = v);
                });
                torsoShape.Visibility = defaults.TorsoMode == "geometric" ? Visibility.Visible : Visibility.Collapsed;
                var acousticGridDefaults = SettingsAdvanced(simulation, "Acoustic torso grid", controls => AcousticDefaultsGrid(controls, defaults.AcousticTorso));
                acousticGridDefaults.Visibility = defaults.TorsoMode == "acoustic" ? Visibility.Visible : Visibility.Collapsed;
                SettingsExpander? acousticExportDefaults = null;
                torsoChoice.SelectionChanged += (_, _) => {
                    defaults.TorsoMode = torsoChoice.SelectedIndex switch { 1 => "geometric", 2 => "acoustic", _ => "off" };
                    torsoShape.Visibility = defaults.TorsoMode == "geometric" ? Visibility.Visible : Visibility.Collapsed;
                    acousticGridDefaults.Visibility = defaults.TorsoMode == "acoustic" ? Visibility.Visible : Visibility.Collapsed;
                    if (acousticExportDefaults != null) acousticExportDefaults.Visibility = defaults.TorsoMode == "acoustic" ? Visibility.Visible : Visibility.Collapsed;
                    SaveAppPreferences();
                };
                SettingsAdvanced(simulation, "Ear attachment", controls => {
                    ChoiceRow(controls, "Head opening", [.. EarCutChoices.Select(choice => choice.Title)], ChoiceIndex(EarCutChoices, defaults.EarCutMode),
                        i => defaults.EarCutMode = EarCutChoices[i].Value, "attachment.cut_mode");
                    NumberRow(controls, "Opening clearance", "attachment.clearance", () => defaults.EarCutClearanceScale, v => defaults.EarCutClearanceScale = v);
                    NumberRow(controls, "Opening margin (mm)", "attachment.margin", () => defaults.ProjectedCutMargin, v => defaults.ProjectedCutMargin = v);
                    IntegerRow(controls, "Smoothing passes", "attachment.smoothing_passes", () => defaults.SeamSmoothingIterations, v => defaults.SeamSmoothingIterations = v);
                    NumberRow(controls, "Smoothing strength", "attachment.smoothing_strength", () => defaults.SeamSmoothingFactor, v => defaults.SeamSmoothingFactor = v);
                });
                var computing = SettingsSection(panel, "Calculation");
                IntegerRow(computing, "Parallel NumCalc instances", "numcalc.parallel_instances", () => appPreferences.MaxInstances, v => appPreferences.MaxInstances = v);
                IntegerRow(computing, "CPU load limit (%)", "numcalc.cpu_limit", () => appPreferences.MaxCpuLoad, v => appPreferences.MaxCpuLoad = v);
                SwitchRow(computing, "Adaptive FMM expansion length", defaults.AdaptiveFmmLength, v => defaults.AdaptiveFmmLength = v);
                var sofa = SettingsSection(panel, "SOFA export");
                acousticExportDefaults = SettingsAdvanced(sofa, "Acoustic torso", controls => AcousticDefaultsExport(controls, defaults.AcousticTorso));
                acousticExportDefaults.Visibility = defaults.TorsoMode == "acoustic" ? Visibility.Visible : Visibility.Collapsed;
                SettingsOption(sofa, "Apply level offset", defaults.Normalize, v => defaults.Normalize = v, controls =>
                    NumberRow(controls, "Level offset (dB)", "postprocessing.level_offset", () => defaults.LevelOffsetDb, v => defaults.LevelOffsetDb = v));
                SettingsOption(sofa, "Resample HRIRs", defaults.ResampleHrirs, v => defaults.ResampleHrirs = v, controls =>
                    IntegerRow(controls, "Sampling rate (Hz)", "postprocessing.sampling_rate", () => defaults.SamplingRate, v => defaults.SamplingRate = v));
                SettingsOption(sofa, "Spatially upsample HRTFs", defaults.SpatialUpsampling, v => defaults.SpatialUpsampling = v, controls => {
                    IntegerRow(controls, "Subdivision level (0–5)", "postprocessing.spatial_subdivisions", () => defaults.SpatialSubdivisions, v => defaults.SpatialSubdivisions = v);
                    SwitchRow(controls, "Normalize to frontal reference", defaults.SpatialNormalize, v => defaults.SpatialNormalize = v);
                });
            }
            else if (name == names[1])
            {
                var status = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Informational };
                void RefreshNotificationStatus()
                {
                    var available = notificationsRegistered;
                    try { available &= Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Setting == Microsoft.Windows.AppNotifications.AppNotificationSetting.Enabled; }
                    catch { available = false; }
                    status.IsOpen = !available;
                    status.Message = notificationsRegistered
                        ? "Notifications are turned off or unavailable in Windows."
                        : "Windows notifications are unavailable for this app session.";
                }
                refreshAppSettingsStatus = RefreshNotificationStatus;
                RefreshNotificationStatus();
                panel.Children.Add(status);
                var notifications = new SettingsExpander {
                    Header = "Notifications", Description = "Choose which workflow updates to receive.", IsExpanded = true
                };
                var master = new ToggleSwitch { IsOn = appPreferences.NotifyAll };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(master, "Notifications");
                var completion = new CheckBox { Content = "When a workflow step completes", IsChecked = appPreferences.NotifyCompletion,
                    IsEnabled = appPreferences.NotifyAll, Margin = new Thickness(16, 8, 16, 4) };
                var failure = new CheckBox { Content = "When a workflow step fails", IsChecked = appPreferences.NotifyFailure,
                    IsEnabled = appPreferences.NotifyAll, Margin = new Thickness(16, 4, 16, 12) };
                master.Toggled += (_, _) => {
                    appPreferences.NotifyAll = master.IsOn;
                    completion.IsEnabled = failure.IsEnabled = master.IsOn;
                    SaveAppPreferences();
                };
                completion.Click += (_, _) => { appPreferences.NotifyCompletion = completion.IsChecked == true; SaveAppPreferences(); };
                failure.Click += (_, _) => { appPreferences.NotifyFailure = failure.IsChecked == true; SaveAppPreferences(); };
                notifications.Content = master;
                notifications.Items.Add(new SettingsCard { Content = completion, ContentAlignment = CommunityToolkit.WinUI.Controls.ContentAlignment.Left });
                notifications.Items.Add(new SettingsCard { Content = failure, ContentAlignment = CommunityToolkit.WinUI.Controls.ContentAlignment.Left });
                panel.Children.Add(notifications);
                var windows = new SettingsCard {
                    Header = "Windows notification settings", Description = "Manage banners, sound and Do not disturb in Windows.",
                    IsClickEnabled = true, ActionIcon = new FontIcon { Glyph = "\uE8A7" }
                };
                windows.Click += async (_, _) => await Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
                panel.Children.Add(windows);
            }
            else
            {
                var developer = new StackPanel { Spacing = 4 };
                SwitchRow(developer, "Developer mode", appPreferences.DeveloperMode, v => {
                    appPreferences.DeveloperMode = v; ApplyAppEnvironment(); ShowCategory(name);
                }, "Override bundled tool paths. Changes apply to newly started operations.");
                panel.Children.Add(developer);
                var tools = SettingsSection(panel, "Tools");
                ComponentRow(tools, "NumCalc", environment.NumCalcExecutable, false,
                    () => appPreferences.NumCalc, v => appPreferences.NumCalc = v);
                ComponentRow(tools, "Mesh grading", environment.MeshGradingExecutable, false,
                    () => appPreferences.MeshGrading, v => appPreferences.MeshGrading = v);
                ComponentRow(tools, "Python", BundledPythonExecutable() ?? "", false,
                    () => appPreferences.Python, v => appPreferences.Python = v);
                if (appPreferences.DeveloperMode || DefaultPythonExecutable() == null)
                    ComponentRow(tools, "uv", environment.UvExecutable, false,
                        () => appPreferences.Uv, v => appPreferences.Uv = v);
                ComponentRow(tools, "Mesh2HRTF", environment.EffectiveMesh2HrtfPath, true,
                    () => appPreferences.Mesh2Hrtf, v => appPreferences.Mesh2Hrtf = v);
                if (appPreferences.DeveloperMode)
                {
                    PathCard(tools, "External dependencies", () => environment.ExternalDir, true,
                        () => appPreferences.ExternalDirectory, v => appPreferences.ExternalDirectory = v, component: true);
                    ToolTipService.SetToolTip(tools.Children[^1], "Dependency bundle containing native libraries in bin and default Mesh2HRTF resources in src. Python packages are managed by the selected Python environment.");
                }
            }
        }
    }

    static StackPanel SettingsSection(StackPanel parent, string title)
    {
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var cards = new StackPanel { Spacing = 4 };
        section.Children.Add(cards);
        parent.Children.Add(section);
        return cards;
    }

    async Task<bool> ResetProjectDefaultsAsync()
    {
        var confirmation = new ContentDialog {
            Title = "Reset Project Defaults?",
            Content = "Restore the default location, input handling and workflow settings for new projects? Existing projects, notifications and tool settings will stay unchanged.",
            PrimaryButtonText = "Reset", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot
        };
        if (await ShowDialogAsync(confirmation) != ContentDialogResult.Primary) return false;
        SetProjectDefaults(new AppPreferences());
        return true;
    }

    void SetProjectDefaults(AppPreferences defaults)
    {
        appPreferences.ProjectDirectory = defaults.ProjectDirectory;
        appPreferences.InputHandling = defaults.InputHandling;
        appPreferences.EvaluationGrid = defaults.EvaluationGrid;
        appPreferences.MinimumFrequency = defaults.MinimumFrequency;
        appPreferences.MaximumFrequency = defaults.MaximumFrequency;
        appPreferences.FrequencySteps = defaults.FrequencySteps;
        appPreferences.MaxInstances = defaults.MaxInstances;
        appPreferences.MaxCpuLoad = defaults.MaxCpuLoad;
        appPreferences.Workflow = defaults.Workflow;
        SaveAppPreferences();
    }

    static readonly JsonSerializerOptions SnakeCase = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    static JsonObject DefaultsPayload(AppPreferences preferences) => new()
    {
        ["project_directory"] = preferences.ProjectDirectory,
        ["input_handling"] = preferences.InputHandling == InputHandling.Reference ? "reference" : "copy",
        ["evaluation_grid"] = preferences.EvaluationGrid,
        ["minimum_frequency"] = preferences.MinimumFrequency, ["maximum_frequency"] = preferences.MaximumFrequency,
        ["frequency_steps"] = preferences.FrequencySteps, ["max_instances"] = preferences.MaxInstances, ["max_cpu_load"] = preferences.MaxCpuLoad,
        ["workflow"] = JsonSerializer.SerializeToNode(preferences.Workflow, SnakeCase)
    };

    static AppPreferences PreferencesFromDefaults(JsonObject values) => new()
    {
        ProjectDirectory = (string)values["project_directory"]!,
        InputHandling = (string?)values["input_handling"] == "reference" ? InputHandling.Reference : InputHandling.Copy,
        EvaluationGrid = (string)values["evaluation_grid"]!,
        MinimumFrequency = (int)values["minimum_frequency"]!, MaximumFrequency = (int)values["maximum_frequency"]!,
        FrequencySteps = (int)values["frequency_steps"]!, MaxInstances = (int)values["max_instances"]!, MaxCpuLoad = (int)values["max_cpu_load"]!,
        Workflow = values["workflow"]!.Deserialize<WorkflowPreferences>(SnakeCase)!
    };

    async Task SaveDefaultsFileAsync()
    {
        try
        {
            var picker = new FileSavePicker { SuggestedFileName = "Pinna2HRTF-project-defaults", SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            picker.FileTypeChoices.Add("Pinna2HRTF project defaults", new List<string> { ".json" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSaveFileAsync();
            if (file == null || shutdownCleanupDone) return;
            await RequestPythonAsync("project", new { action = "save-defaults", path = file.Path, defaults = DefaultsPayload(appPreferences) });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            await ShowDialogAsync(new ContentDialog { Title = "Unable to save defaults", Content = error.Message, CloseButtonText = "Close", XamlRoot = Root.XamlRoot });
        }
    }

    async Task<bool> LoadDefaultsFileAsync()
    {
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            picker.FileTypeFilter.Add(".json");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSingleFileAsync();
            if (file == null || shutdownCleanupDone) return false;
            var reply = await RequestPythonAsync("project", new { action = "read-defaults", path = file.Path });
            var defaults = PreferencesFromDefaults(JsonNode.Parse(reply.GetProperty("defaults").GetRawText())!.AsObject());
            var confirmation = new ContentDialog {
                Title = "Load Project Defaults?", Content = "Replace Project Defaults with " + Path.GetFileName(file.Path) + "? Existing projects, notifications and tool settings will stay unchanged.",
                PrimaryButtonText = "Load", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot
            };
            if (await ShowDialogAsync(confirmation) != ContentDialogResult.Primary) return false;
            SetProjectDefaults(defaults);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or FormatException or System.Runtime.InteropServices.COMException)
        {
            await ShowDialogAsync(new ContentDialog { Title = "Unable to load defaults", Content = error.Message, CloseButtonText = "Close", XamlRoot = Root.XamlRoot });
            return false;
        }
    }

    FrameworkElement DefaultsLabel(string title, string? id = null)
    {
        id ??= title switch {
            "Apply torso shadow" => "acoustic_torso.apply_shadow", "Normalize reflection mix" => "acoustic_torso.normalize_reflection_mix",
            "Project location" => "defaults.project_location", "Input source" => "defaults.input_source",
            "Ear modelling method" => "defaults.ear_model_method", "Mesh2PPM model" => "inference.model",
            "Ears to prepare from a full-head scan" => "defaults.prepared_ears", "Require ear review" => "defaults.require_review",
            "Evaluation grid" => "mesh2hrtf.evaluation_grid", "Adaptive FMM expansion length" => "numcalc.adaptive_fmm",
            "Apply level offset" => "postprocessing.normalize", "Resample HRIRs" => "postprocessing.resample_hrirs",
            "Spatially upsample HRTFs" => "postprocessing.spatial_upsampling", "Normalize to frontal reference" => "postprocessing.spatial_normalize",
            _ => null
        };
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        panel.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
        if (id != null && settingHelp.ContainsKey(id))
        {
            var info = InfoButton(id);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(info, "About " + title);
            panel.Children.Add(info);
        }
        return panel;
    }

    void SettingsOption(StackPanel parent, string title, bool value, Action<bool> write, Action<StackPanel> build)
    {
        var expander = SettingsAdvanced(parent, title, build);
        var toggle = new ToggleSwitch { IsOn = value };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, title);
        expander.Content = toggle;
        expander.IsExpanded = value;
        foreach (var item in expander.Items.OfType<Control>()) item.IsEnabled = value;
        toggle.Toggled += (_, _) => {
            write(toggle.IsOn);
            expander.IsExpanded = toggle.IsOn;
            foreach (var item in expander.Items.OfType<Control>()) item.IsEnabled = toggle.IsOn;
            SaveAppPreferences();
        };
    }

    SettingsExpander SettingsAdvanced(StackPanel parent, string title, Action<StackPanel> build)
    {
        var controls = new StackPanel();
        build(controls);
        var expander = new SettingsExpander { Header = DefaultsLabel(title) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(expander, title);
        foreach (var control in controls.Children.ToArray())
        {
            controls.Children.Remove(control);
            expander.Items.Add(control);
        }
        parent.Children.Add(expander);
        return expander;
    }

    void ChoiceRow(StackPanel parent, string title, string[] choices, int selected, Action<int> write, string? helpId = null)
    {
        var choice = new ComboBox { ItemsSource = choices, SelectedIndex = selected, MaxWidth = 280 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(choice, title);
        choice.SelectionChanged += (_, _) => {
            if (choice.SelectedIndex < 0) return;
            write(choice.SelectedIndex); SaveAppPreferences();
        };
        parent.Children.Add(new SettingsCard { Header = DefaultsLabel(title, helpId), Content = choice });
    }

    void NumberRow(StackPanel parent, string title, string id, Func<double> read, Action<double> write)
    {
        var box = new TextBox { Text = read().ToString("G", CultureInfo.CurrentCulture), Width = 144 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, title);
        void Commit()
        {
            var values = appPreferences.FormValues();
            var valid = double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value) && double.IsFinite(value);
            values[id] = valid ? value.ToString("R", CultureInfo.InvariantCulture) : box.Text;
            if (SettingsCatalog.Check(values, id) is string message) { box.Description = message; return; }
            write(value); SaveAppPreferences(); box.Description = null;
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => {
            if (args.Key == VirtualKey.Enter) { Commit(); args.Handled = true; }
            if (args.Key == VirtualKey.Escape) { box.Text = read().ToString("G", CultureInfo.CurrentCulture); box.Description = null; args.Handled = true; }
        };
        parent.Children.Add(new SettingsCard { Header = DefaultsLabel(title, id), Content = box });
    }

    void SwitchRow(StackPanel parent, string title, bool value, Action<bool> write, string? description = null)
    {
        var toggle = new ToggleSwitch { IsOn = value };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, title);
        toggle.Toggled += (_, _) => { write(toggle.IsOn); SaveAppPreferences(); };
        parent.Children.Add(new SettingsCard { Header = DefaultsLabel(title), Description = description ?? "", Content = toggle });
    }

    void CloseAppSettings()
    {
        if (appSettingsPage == null) return;
        Root.Children.Remove(appSettingsPage);
        if (settingsTitleBar != null) Root.Children.Remove(settingsTitleBar);
        settingsTitleBar = null;
        Title = settingsWorkspaceTitle ?? Title;
        settingsWorkspaceTitle = null;
        appSettingsPage = null;
        refreshToolSettings = null;
        refreshAppSettingsStatus = null;
        Root.RowDefinitions[0].Height = settingsWorkspaceTitleHeight;
        if (settingsWorkspaceHeader != null) settingsWorkspaceHeader.Visibility = Visibility.Visible;
        if (settingsWorkspaceDragRegion != null) SetTitleBar(settingsWorkspaceDragRegion);
        settingsWorkspaceHeader = null;
        settingsWorkspaceDragRegion = null;
        if (contentGrid != null) contentGrid.Visibility = Visibility.Visible;
        if (settingsReturnFocus?.Focus(FocusState.Programmatic) != true) projectList.Focus(FocusState.Programmatic);
        settingsReturnFocus = null;
    }

    void IntegerRow(StackPanel parent, string title, string id, Func<int> read, Action<int> write)
    {
        var box = new TextBox { Text = read().ToString(CultureInfo.CurrentCulture), Width = 144 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, title);
        void Commit()
        {
            var values = appPreferences.FormValues();
            var valid = int.TryParse(box.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var value);
            values[id] = valid ? value.ToString(CultureInfo.InvariantCulture) : box.Text;
            if (SettingsCatalog.Check(values, id) is string message) { box.Description = message; return; }
            write(value); SaveAppPreferences(); box.Description = null;
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => {
            if (args.Key == VirtualKey.Enter) { Commit(); args.Handled = true; }
            if (args.Key == VirtualKey.Escape) { box.Text = read().ToString(CultureInfo.CurrentCulture); box.Description = null; args.Handled = true; }
        };
        parent.Children.Add(new SettingsCard { Header = DefaultsLabel(title, id), Content = box });
    }

    void PathRow(StackPanel parent, string title, Func<string> read, Action<string> write, string fallback, bool directory,
        bool grid = false, bool tool = false)
    {
        PathCard(parent, title, () => read().Length > 0 ? read() : fallback, directory, read, write, grid, tool);
    }

    void ComponentRow(StackPanel parent, string title, string path, bool directory, Func<string>? read = null, Action<string>? write = null)
    {
        PathCard(parent, title, () => path, directory, appPreferences.DeveloperMode ? read : null,
            appPreferences.DeveloperMode ? write : null, component: true);
    }

    void PathCard(StackPanel parent, string title, Func<string> effective, bool directory, Func<string>? read = null,
        Action<string>? write = null, bool grid = false, bool tool = true, bool component = false)
    {
        var row = new StackPanel { Spacing = 8 };
        var description = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var reveal = new HyperlinkButton { Content = "Show path", Padding = new Thickness(4, 0, 4, 0) };
        var fullPath = new TextBox { IsReadOnly = true, Visibility = Visibility.Collapsed };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(fullPath, title + " full path");
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.OrangeRed) };
        var choose = new Button { Content = "Choose…" };
        var reset = new Button { Content = "Use default" };
        var open = new Button { Content = "Open" };
        ToolTipService.SetToolTip(open, directory ? "Open folder in File Explorer" : "Show in File Explorer");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, "Show " + title + " in File Explorer");
        var card = new SettingsCard { Header = DefaultsLabel(title), Description = description, Content = actions };
        if (title == "Mesh2HRTF") ToolTipService.SetToolTip(card, "Mesh2HRTF export resources: choose the mesh2hrtf folder containing Mesh2Input. The Python package used for SOFA export belongs to the selected Python environment.");
        actions.Children.Add(reveal);
        if (component) actions.Children.Add(open);
        if (write != null) { actions.Children.Add(choose); actions.Children.Add(reset); }
        row.Children.Add(card); row.Children.Add(fullPath); row.Children.Add(error);
        void Update()
        {
            var path = effective();
            var available = title == "Mesh2HRTF" ? File.Exists(Path.Combine(path, "Mesh2Input", "mesh2input.py")) : directory ? Directory.Exists(path) : File.Exists(path);
            var shortPath = path.Length == 0 ? "Not configured" : (directory ? @"\" : "") + Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
            var useDefault = read != null && read().Length == 0;
            description.Text = component ? (available ? "Available · " : "Missing · ") + shortPath
                : useDefault && grid ? "Default · ARI grid (91 directions)" : (useDefault ? "Default · " : "") + shortPath;
            fullPath.Text = path;
            reveal.IsEnabled = path.Length > 0;
            open.IsEnabled = available;
            reset.Visibility = read?.Invoke().Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        void Apply(string path)
        {
            write!(path);
            SaveAppPreferences();
            if (tool) ApplyAppEnvironment();
            Update();
            error.Visibility = Visibility.Collapsed;
            refreshToolSettings?.Invoke();
        }
        choose.Click += async (_, _) => {
            var path = directory ? await PickFolderAsync(effective()) : await PickFileAsync(effective());
            if (path == null) return;
            try
            {
                if (title == "Mesh2HRTF")
                {
                    if (File.Exists(Path.Combine(path, "mesh2hrtf", "Mesh2Input", "mesh2input.py"))) path = Path.Combine(path, "mesh2hrtf");
                    if (!File.Exists(Path.Combine(path, "Mesh2Input", "mesh2input.py"))) throw new IOException("Choose a Mesh2HRTF installation containing mesh2hrtf/Mesh2Input/mesh2input.py.");
                }
                if (grid) await RequestPythonAsync("project", new { action = "validate-grid", path });
                if (!(directory ? Directory.Exists(path) : File.Exists(path))) throw new IOException("The selected path is unavailable.");
                Apply(path);
            }
            catch (Exception failure) { error.Text = failure.Message; error.Visibility = Visibility.Visible; }
        };
        reset.Click += (_, _) => Apply("");
        reveal.Click += (_, _) => {
            fullPath.Visibility = fullPath.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            reveal.Content = fullPath.Visibility == Visibility.Visible ? "Hide path" : "Show path";
        };
        open.Click += (_, _) => {
            try {
                var info = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = true };
                info.ArgumentList.Add(directory ? effective() : "/select," + effective());
                System.Diagnostics.Process.Start(info);
            }
            catch (Exception failure) { error.Text = failure.Message; error.Visibility = Visibility.Visible; }
        };
        Update();
        parent.Children.Add(row);
    }
}
