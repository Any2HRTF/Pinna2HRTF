using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using CommunityToolkit.WinUI.Controls;
using Windows.System;

namespace Pinna2HRTF.Windows;

internal sealed class AppPreferences
{
    public int Version { get; set; } = 1;
    public string ProjectDirectory { get; set; } = "";
    public InputHandling InputHandling { get; set; } = InputHandling.Copy;
    public string EvaluationGrid { get; set; } = "";
    public int MinimumFrequency { get; set; }
    public int MaximumFrequency { get; set; } = 24000;
    public int FrequencySteps { get; set; } = 129;
    public int MaxInstances { get; set; } = 1;
    public int MaxCpuLoad { get; set; } = 90;
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
}

internal sealed class WorkflowPreferences
{
    public bool FullHeadScan { get; set; }
    public bool PrepareLeft { get; set; } = true;
    public bool PrepareRight { get; set; } = true;
    public bool RequireManualReview { get; set; }
    public string EarModelMethod { get; set; } = "none";
    public string InferenceModel { get; set; } = "Local 3 Views";
    public double TargetEdgeMm { get; set; } = .75;
    public double LeftMarginMm { get; set; } = 20;
    public double RightMarginMm { get; set; } = 10;
    public double SideMinMm { get; set; } = 30;
    public double SideMaxMm { get; set; } = 110;
    public int SourceAssignmentFaceCount { get; set; } = 6;
    public double MeshMinEdgeLength { get; set; } = .5;
    public double MeshMaxEdgeLength { get; set; } = 10;
    public double MeshMaxError { get; set; } = .5;
    public double MeshGamma { get; set; } = .2;
    public double MeshGammaOpposite { get; set; } = .1;
    public bool AdaptiveFmmLength { get; set; } = true;
    public bool Normalize { get; set; } = true;
    public double LevelOffsetDb { get; set; } = -30;
    public bool ResampleHrirs { get; set; }
    public int SamplingRate { get; set; } = 48000;
    public bool SpatialUpsampling { get; set; }
    public int SpatialSubdivisions { get; set; } = 3;
    public bool SpatialNormalize { get; set; }

    public bool Valid()
    {
        var positive = new[] { TargetEdgeMm, MeshMinEdgeLength, MeshMaxEdgeLength, MeshMaxError, MeshGamma, MeshGammaOpposite };
        return positive.All(v => double.IsFinite(v) && v is >= .000001 and <= 1000)
            && new[] { LeftMarginMm, RightMarginMm, SideMinMm, SideMaxMm }.All(v => double.IsFinite(v) && v is >= 0 and <= 1000)
            && SideMaxMm > SideMinMm && MeshMaxEdgeLength >= MeshMinEdgeLength && (PrepareLeft || PrepareRight)
            && SourceAssignmentFaceCount is >= 1 and <= 1000000 && SamplingRate is >= 10 and <= 384000 && SamplingRate % 10 == 0
            && SpatialSubdivisions is >= 0 and <= 5 && double.IsFinite(LevelOffsetDb) && LevelOffsetDb is >= -1000 and <= 1000
            && EarModelMethod is "none" or "manual" or "mesh2ppm" && !string.IsNullOrEmpty(InferenceModel);
    }
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
            if (value.Version != 1 || value.MinimumFrequency < 0 || value.MaximumFrequency > 96000 ||
                value.MinimumFrequency >= value.MaximumFrequency || value.FrequencySteps is < 2 or > 8193 ||
                value.MaxInstances is < 1 or > 1024 || value.MaxCpuLoad is < 1 or > 100 ||
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
        var reply = await RequestPythonAsync("project", new {
            action = "new-defaults", parent = preferences.ProjectDirectory.Length > 0 ? preferences.ProjectDirectory : Path.Combine(appData, "Projects"),
            index = index ?? projects.Count + 1, defaults = new {
                minimum_frequency = preferences.MinimumFrequency, maximum_frequency = preferences.MaximumFrequency,
                frequency_steps = preferences.FrequencySteps, max_instances = preferences.MaxInstances,
                max_cpu_load = preferences.MaxCpuLoad, evaluation_grid = preferences.EvaluationGrid,
                workflow = JsonSerializer.SerializeToNode(preferences.Workflow, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower })
            }
        });
        project.SaveLocation = reply.GetProperty("save_location").GetString()!;
        project.InputHandling = preferences.InputHandling;
        ProjectDocument.Restore(project, JsonNode.Parse(reply.GetProperty("settings").GetRawText())!.AsObject());
    }

    async Task InitializeInitialProjectAsync(ProjectRecord project)
    {
        var revision = StatusRevision(project);
        var prepared = Clone(project);
        await ApplyNewProjectDefaultsAsync(prepared, 1);
        if (!projects.Contains(project) || StatusRevision(project) != revision) return;
        project.SaveLocation = prepared.SaveLocation;
        project.InputHandling = prepared.InputHandling;
        project.Settings = prepared.Settings;
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
            heading.Children.Add(new TextBlock { Text = name, FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
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
                files.Children.Add(new SettingsCard { Header = "Input files", Content = handling });
                var defaults = appPreferences.Workflow;
                ChoiceRow(files, "Input source", ["Individual ear meshes", "Full-head scan"], defaults.FullHeadScan ? 1 : 0,
                    i => defaults.FullHeadScan = i == 1);
                var ears = SettingsSection(panel, "Ear preparation & modelling");
                ChoiceRow(ears, "Ear modelling method", ["Mesh2PPM", "Manual PPM fitting", "No ear model"],
                    Array.IndexOf(new[] { "mesh2ppm", "manual", "none" }, defaults.EarModelMethod),
                    i => defaults.EarModelMethod = new[] { "mesh2ppm", "manual", "none" }[i]);
                var models = modelPicker.Items.Cast<string>().ToArray();
                ChoiceRow(ears, "Mesh2PPM model", models, Array.IndexOf(models, defaults.InferenceModel), i => defaults.InferenceModel = models[i]);
                ChoiceRow(ears, "Ears to prepare from a full-head scan", ["Left and right", "Left only", "Right only"],
                    defaults.PrepareLeft && defaults.PrepareRight ? 0 : defaults.PrepareLeft ? 1 : 2,
                    i => { defaults.PrepareLeft = i != 2; defaults.PrepareRight = i != 1; });
                SettingsAdvanced(ears, "Advanced scan settings", controls => {
                    NumberRow(controls, "Target edge length (mm)", () => defaults.TargetEdgeMm, v => defaults.TargetEdgeMm = v, () => .000001, () => 1000);
                    NumberRow(controls, "Left crop margin (mm)", () => defaults.LeftMarginMm, v => defaults.LeftMarginMm = v, () => 0, () => 1000);
                    NumberRow(controls, "Right crop margin (mm)", () => defaults.RightMarginMm, v => defaults.RightMarginMm = v, () => 0, () => 1000);
                    NumberRow(controls, "Inner crop limit (mm)", () => defaults.SideMinMm, v => defaults.SideMinMm = v, () => 0, () => defaults.SideMaxMm - .000001);
                    NumberRow(controls, "Outer crop limit (mm)", () => defaults.SideMaxMm, v => defaults.SideMaxMm = v, () => defaults.SideMinMm + .000001, () => 1000);
                    SwitchRow(controls, "Require ear review", defaults.RequireManualReview, v => defaults.RequireManualReview = v);
                });
                var simulation = SettingsSection(panel, "Simulation setup");
                IntegerRow(simulation, "Microphone faces", () => defaults.SourceAssignmentFaceCount, v => defaults.SourceAssignmentFaceCount = v, () => 1, () => 1000000);
                PathRow(simulation, "Evaluation grid", () => appPreferences.EvaluationGrid, v => appPreferences.EvaluationGrid = v,
                    Path.Combine(packageRoot, "HRTFCalculation", "EvaluationGrids", ProjectDocument.DefaultEvaluationGrid), true, grid: true);
                IntegerRow(simulation, "Lowest frequency (Hz)", () => appPreferences.MinimumFrequency, v => appPreferences.MinimumFrequency = v,
                    () => 0, () => appPreferences.MaximumFrequency - 1);
                IntegerRow(simulation, "Highest frequency (Hz)", () => appPreferences.MaximumFrequency, v => appPreferences.MaximumFrequency = v,
                    () => appPreferences.MinimumFrequency + 1, () => 96000);
                IntegerRow(simulation, "Frequency steps", () => appPreferences.FrequencySteps, v => appPreferences.FrequencySteps = v, () => 2, () => 8193);
                SettingsAdvanced(simulation, "Advanced mesh grading", controls => {
                    NumberRow(controls, "Minimum edge length (mm)", () => defaults.MeshMinEdgeLength, v => defaults.MeshMinEdgeLength = v, () => .000001, () => defaults.MeshMaxEdgeLength);
                    NumberRow(controls, "Maximum edge length (mm)", () => defaults.MeshMaxEdgeLength, v => defaults.MeshMaxEdgeLength = v, () => defaults.MeshMinEdgeLength, () => 1000);
                    NumberRow(controls, "Maximum error (mm)", () => defaults.MeshMaxError, v => defaults.MeshMaxError = v, () => .000001, () => 1000);
                    NumberRow(controls, "Gamma", () => defaults.MeshGamma, v => defaults.MeshGamma = v, () => .000001, () => 1000);
                    NumberRow(controls, "Gamma opposite", () => defaults.MeshGammaOpposite, v => defaults.MeshGammaOpposite = v, () => .000001, () => 1000);
                });
                var computing = SettingsSection(panel, "Calculation");
                IntegerRow(computing, "Parallel NumCalc instances", () => appPreferences.MaxInstances, v => appPreferences.MaxInstances = v, () => 1, () => 1024);
                IntegerRow(computing, "CPU load limit (%)", () => appPreferences.MaxCpuLoad, v => appPreferences.MaxCpuLoad = v, () => 1, () => 100);
                SettingsAdvanced(computing, "Advanced calculation settings", controls =>
                    SwitchRow(controls, "Adaptive FMM expansion length", defaults.AdaptiveFmmLength, v => defaults.AdaptiveFmmLength = v));
                var sofa = SettingsSection(panel, "SOFA export");
                SwitchRow(sofa, "Apply level offset", defaults.Normalize, v => defaults.Normalize = v);
                NumberRow(sofa, "Level offset (dB)", () => defaults.LevelOffsetDb, v => defaults.LevelOffsetDb = v, () => -1000, () => 1000);
                SwitchRow(sofa, "Resample HRIRs", defaults.ResampleHrirs, v => defaults.ResampleHrirs = v);
                IntegerRow(sofa, "Sampling rate (Hz)", () => defaults.SamplingRate, v => defaults.SamplingRate = v, () => 10, () => 384000, multiple: 10);
                SwitchRow(sofa, "Spatially upsample HRTFs", defaults.SpatialUpsampling, v => defaults.SpatialUpsampling = v);
                SettingsAdvanced(sofa, "Advanced spatial upsampling", controls => {
                    IntegerRow(controls, "Subdivision level (0–5)", () => defaults.SpatialSubdivisions, v => defaults.SpatialSubdivisions = v, () => 0, () => 5);
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

    static void SettingsAdvanced(StackPanel parent, string title, Action<StackPanel> build)
    {
        var controls = new StackPanel();
        build(controls);
        var expander = new SettingsExpander { Header = title };
        foreach (var control in controls.Children.ToArray())
        {
            controls.Children.Remove(control);
            expander.Items.Add(control);
        }
        parent.Children.Add(expander);
    }

    void ChoiceRow(StackPanel parent, string title, string[] choices, int selected, Action<int> write)
    {
        var choice = new ComboBox { ItemsSource = choices, SelectedIndex = selected, MaxWidth = 280 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(choice, title);
        choice.SelectionChanged += (_, _) => {
            if (choice.SelectedIndex < 0) return;
            write(choice.SelectedIndex); SaveAppPreferences();
        };
        parent.Children.Add(new SettingsCard { Header = title, Content = choice });
    }

    void NumberRow(StackPanel parent, string title, Func<double> read, Action<double> write, Func<double> minimum, Func<double> maximum)
    {
        var box = new TextBox { Text = read().ToString("G", CultureInfo.CurrentCulture), Width = 144 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, title);
        void Commit()
        {
            if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value) || !double.IsFinite(value) || value < minimum() || value > maximum())
            { box.Description = $"Enter a number from {minimum():G} to {maximum():G}."; return; }
            write(value); SaveAppPreferences(); box.Description = null;
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => {
            if (args.Key == VirtualKey.Enter) { Commit(); args.Handled = true; }
            if (args.Key == VirtualKey.Escape) { box.Text = read().ToString("G", CultureInfo.CurrentCulture); box.Description = null; args.Handled = true; }
        };
        parent.Children.Add(new SettingsCard { Header = title, Content = box });
    }

    void SwitchRow(StackPanel parent, string title, bool value, Action<bool> write, string? description = null)
    {
        var toggle = new ToggleSwitch { IsOn = value };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, title);
        toggle.Toggled += (_, _) => { write(toggle.IsOn); SaveAppPreferences(); };
        parent.Children.Add(new SettingsCard { Header = title, Description = description ?? "", Content = toggle });
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

    void IntegerRow(StackPanel parent, string title, Func<int> read, Action<int> write, Func<int> minimum, Func<int> maximum, int multiple = 1)
    {
        var box = new TextBox { Text = read().ToString(CultureInfo.CurrentCulture), Width = 144 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, title);
        void Commit()
        {
            var lower = minimum();
            if (!int.TryParse(box.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var value) || value < lower || value > maximum() || value % multiple != 0)
            { box.Description = $"Enter a whole number from {lower} to {maximum()}." + (multiple > 1 ? $" Use multiples of {multiple}." : ""); return; }
            write(value); SaveAppPreferences(); box.Description = null;
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => {
            if (args.Key == VirtualKey.Enter) { Commit(); args.Handled = true; }
            if (args.Key == VirtualKey.Escape) { box.Text = read().ToString(CultureInfo.CurrentCulture); box.Description = null; args.Handled = true; }
        };
        parent.Children.Add(new SettingsCard { Header = title, Content = box });
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
        var card = new SettingsCard { Header = title, Description = description, Content = actions };
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
