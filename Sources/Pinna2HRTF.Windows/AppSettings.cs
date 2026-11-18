using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
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
}

public partial class MainWindow
{
    AppPreferences appPreferences = new();
    Grid? appSettingsPage;
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
                value.NumCalc == null || value.MeshGrading == null || value.Python == null || value.Uv == null || value.ExternalDirectory == null)
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
                max_cpu_load = preferences.MaxCpuLoad, evaluation_grid = preferences.EvaluationGrid
            }
        });
        project.SaveLocation = reply.GetProperty("save_location").GetString()!;
        project.InputHandling = preferences.InputHandling;
        project.Settings.Preprocessing.MinFrequency = preferences.MinimumFrequency.ToString(CultureInfo.InvariantCulture);
        project.Settings.Preprocessing.MaxFrequency = preferences.MaximumFrequency.ToString(CultureInfo.InvariantCulture);
        project.Settings.Preprocessing.FrequencyStepCount = preferences.FrequencySteps.ToString(CultureInfo.InvariantCulture);
        project.Settings.Preprocessing.EvaluationGrid = preferences.EvaluationGrid;
        project.Settings.NumCalc.MaxInstances = preferences.MaxInstances.ToString(CultureInfo.InvariantCulture);
        project.Settings.NumCalc.MaxCpuLoad = preferences.MaxCpuLoad.ToString(CultureInfo.InvariantCulture);
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
        var page = new Grid { Background = appBackgroundBrush };
        page.RowDefinitions.Add(new() { Height = GridLength.Auto });
        page.RowDefinitions.Add(new());
        var back = new Button { Content = "Back", Margin = new Thickness(16) };
        back.Click += (_, _) => CloseAppSettings();
        page.Children.Add(back);
        var navigation = new NavigationView { IsSettingsVisible = false, IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            PaneDisplayMode = NavigationViewPaneDisplayMode.Auto, OpenPaneLength = 200,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
        var names = new[] { "New projects", "Computing", "Notifications", "Tools" };
        var icons = new[] { "\uE8B7", "\uE950", "\uEA8F", "\uE90F" };
        for (var i = 0; i < names.Length; i++) navigation.MenuItems.Add(new NavigationViewItem { Content = names[i], Tag = names[i], Icon = new FontIcon { Glyph = icons[i] } });
        Grid.SetRow(navigation, 1); page.Children.Add(navigation);
        navigation.SelectionChanged += (_, args) => ShowCategory((args.SelectedItem as NavigationViewItem)?.Tag as string ?? names[0]);
        Grid.SetRow(page, 1);
        Root.Children.Add(page);
        appSettingsPage = page;
        if (contentGrid != null) contentGrid.Visibility = Visibility.Collapsed;
        navigation.SelectedItem = navigation.MenuItems[0];

        void ShowCategory(string name)
        {
            refreshToolSettings = name == "Tools" ? () => ShowCategory(name) : null;
            var panel = new StackPanel { Spacing = 16, MaxWidth = 1000, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(24) };
            panel.Children.Add(new TextBlock { Text = name, FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            if (preferencesLoadError != null) panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = preferencesLoadError });
            var scroller = new ScrollViewer { Content = panel, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Top };
            panel.HorizontalAlignment = HorizontalAlignment.Left;
            scroller.SizeChanged += (_, _) => panel.Width = Math.Max(0, Math.Min(1000, scroller.ActualWidth - 48));
            navigation.Content = scroller;
            if (name == names[0])
            {
                PathRow(panel, "Project location", () => appPreferences.ProjectDirectory, value => appPreferences.ProjectDirectory = value, Path.Combine(appData, "Projects"), true);
                var handling = new ComboBox { Header = "Input files", ItemsSource = new[] { "Copy into project", "Reference original files" }, SelectedIndex = (int)appPreferences.InputHandling, HorizontalAlignment = HorizontalAlignment.Stretch };
                handling.SelectionChanged += (_, _) => { appPreferences.InputHandling = (InputHandling)handling.SelectedIndex; SaveAppPreferences(); };
                panel.Children.Add(handling);
                PathRow(panel, "Evaluation grid", () => appPreferences.EvaluationGrid, value => appPreferences.EvaluationGrid = value, "Default · ARI grid (91 directions)", true, grid: true);
                IntegerRow(panel, "Lowest frequency (Hz)", () => appPreferences.MinimumFrequency, v => appPreferences.MinimumFrequency = v, () => 0, () => appPreferences.MaximumFrequency - 1);
                IntegerRow(panel, "Highest frequency (Hz)", () => appPreferences.MaximumFrequency, v => appPreferences.MaximumFrequency = v, () => appPreferences.MinimumFrequency + 1, () => 96000);
                IntegerRow(panel, "Frequency steps", () => appPreferences.FrequencySteps, v => appPreferences.FrequencySteps = v, () => 2, () => 8193);
            }
            else if (name == names[1])
            {
                panel.Children.Add(new TextBlock { Text = "Defaults for new projects", Foreground = mutedTextBrush });
                IntegerRow(panel, "Parallel NumCalc instances", () => appPreferences.MaxInstances, v => appPreferences.MaxInstances = v, () => 1, () => 1024);
                IntegerRow(panel, "CPU load limit (%)", () => appPreferences.MaxCpuLoad, v => appPreferences.MaxCpuLoad = v, () => 1, () => 100);
            }
            else if (name == names[2])
            {
                if (!notificationsRegistered) panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Message = "Windows notifications are unavailable for this session. Processing is unaffected." });
                SwitchRow(panel, "Allow notifications", appPreferences.NotifyAll, v => { appPreferences.NotifyAll = v; ShowCategory(name); });
                var events = new StackPanel { Spacing = 16 };
                SwitchRow(events, "A stage completes", appPreferences.NotifyCompletion, v => appPreferences.NotifyCompletion = v);
                SwitchRow(events, "A stage fails", appPreferences.NotifyFailure, v => appPreferences.NotifyFailure = v);
                foreach (var toggle in events.Children.OfType<ToggleSwitch>()) toggle.IsEnabled = appPreferences.NotifyAll;
                panel.Children.Add(events);
                var systemSettings = new HyperlinkButton { Content = "Windows notification settings" };
                systemSettings.Click += async (_, _) => await Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
                panel.Children.Add(systemSettings);
            }
            else
            {
                foreach (var (title, path, folder) in new[] {
                    ("NumCalc", environment.NumCalcExecutable, false), ("Mesh grading", environment.MeshGradingExecutable, false),
                    ("Python", PythonOverride ?? BundledPythonExecutable() ?? "", false),
                    ("Mesh2HRTF", Path.Combine(environment.ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf"), true) })
                    ComponentRow(panel, title, path, folder);
                SwitchRow(panel, "Developer mode", appPreferences.DeveloperMode, v => { appPreferences.DeveloperMode = v; ApplyAppEnvironment(); ShowCategory(name); });
                panel.Children.Add(new TextBlock { Text = "Changes apply to newly started operations. Open editors keep their current tools.", TextWrapping = TextWrapping.Wrap, Foreground = mutedTextBrush });
                if (appPreferences.DeveloperMode || BundledPythonExecutable() == null)
                {
                    ComponentRow(panel, "uv", environment.UvExecutable, false);
                }
                if (appPreferences.DeveloperMode)
                {
                    PathRow(panel, "NumCalc override", () => appPreferences.NumCalc, v => appPreferences.NumCalc = v, DefaultEnvironment().NumCalcExecutable, false);
                    PathRow(panel, "Mesh grading override", () => appPreferences.MeshGrading, v => appPreferences.MeshGrading = v, DefaultEnvironment().MeshGradingExecutable, false);
                    PathRow(panel, "Python override", () => appPreferences.Python, v => appPreferences.Python = v, DefaultPythonExecutable() ?? "", false);
                    PathRow(panel, "uv override", () => appPreferences.Uv, v => appPreferences.Uv = v, DefaultEnvironment().UvExecutable, false);
                    PathRow(panel, "External dependencies", () => appPreferences.ExternalDirectory, v => appPreferences.ExternalDirectory = v, DefaultEnvironment().ExternalDir, true);
                }
            }
        }
    }

    void SwitchRow(StackPanel parent, string title, bool value, Action<bool> write)
    {
        var toggle = new ToggleSwitch { Header = title, IsOn = value };
        toggle.Toggled += (_, _) => { write(toggle.IsOn); SaveAppPreferences(); };
        parent.Children.Add(toggle);
    }

    void CloseAppSettings()
    {
        if (appSettingsPage == null) return;
        Root.Children.Remove(appSettingsPage);
        appSettingsPage = null;
        refreshToolSettings = null;
        if (contentGrid != null) contentGrid.Visibility = Visibility.Visible;
    }

    void IntegerRow(StackPanel parent, string title, Func<int> read, Action<int> write, Func<int> minimum, Func<int> maximum)
    {
        var box = new TextBox { Header = title, Text = read().ToString(CultureInfo.CurrentCulture) };
        void Commit()
        {
            var currentMinimum = minimum();
            if (!int.TryParse(box.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var value) || value < currentMinimum || value > maximum())
            { box.Description = $"Enter a whole number from {currentMinimum} to {maximum()}."; return; }
            write(value); SaveAppPreferences(); box.Description = null;
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => {
            if (args.Key == VirtualKey.Enter) { Commit(); args.Handled = true; }
            if (args.Key == VirtualKey.Escape) { box.Text = read().ToString(CultureInfo.CurrentCulture); box.Description = null; args.Handled = true; }
        };
        parent.Children.Add(box);
    }

    void PathRow(StackPanel parent, string title, Func<string> read, Action<string> write, string fallback, bool directory, bool grid = false)
    {
        var row = new StackPanel { Spacing = 6 };
        row.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var label = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Microsoft.UI.Colors.OrangeRed) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var choose = new Button { Content = "Choose…" };
        var reset = new Button { Content = "Use default" };
        var reveal = new HyperlinkButton { Content = "Show path", Padding = new Thickness(0) };
        var pathBox = new TextBox { IsReadOnly = true, Visibility = Visibility.Collapsed };
        void Update()
        {
            var path = read();
            var effective = path.Length > 0 ? path : grid ? Path.Combine(packageRoot, "HRTFCalculation", "EvaluationGrids", ProjectDocument.DefaultEvaluationGrid) : fallback;
            label.Text = path.Length == 0 && grid ? fallback : (path.Length == 0 ? "Default · " : "") + (directory ? @"\" : "") + Path.GetFileName(Path.TrimEndingDirectorySeparator(effective));
            pathBox.Text = effective;
            reset.IsEnabled = path.Length > 0;
        }
        choose.Click += async (_, _) => {
            var path = directory ? await PickFolderAsync(pathBox.Text) : await PickFileAsync(pathBox.Text);
            if (path == null) return;
            try
            {
                if (grid) await RequestPythonAsync("project", new { action = "validate-grid", path });
                if (!(directory ? Directory.Exists(path) : File.Exists(path))) throw new IOException("The selected path is unavailable.");
                write(path); SaveAppPreferences(); ApplyAppEnvironment(); Update(); error.Text = "";
                refreshToolSettings?.Invoke();
            }
            catch (Exception failure) { error.Text = failure.Message; }
        };
        reset.Click += (_, _) => { write(""); SaveAppPreferences(); ApplyAppEnvironment(); Update(); error.Text = ""; refreshToolSettings?.Invoke(); };
        reveal.Click += (_, _) => pathBox.Visibility = pathBox.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        buttons.Children.Add(choose); buttons.Children.Add(reset);
        row.Children.Add(label); row.Children.Add(buttons); row.Children.Add(reveal); row.Children.Add(pathBox); row.Children.Add(error);
        Update(); parent.Children.Add(row);
    }

    void ComponentRow(StackPanel parent, string title, string path, bool directory)
    {
        var available = directory ? Directory.Exists(path) : File.Exists(path);
        var row = new StackPanel { Spacing = 6 };
        row.Children.Add(new TextBlock { Text = title + " · " + (available ? "Available" : "Missing") });
        var show = new Button { Content = "Show in File Explorer", IsEnabled = available };
        ToolTipService.SetToolTip(show, path);
        show.Click += (_, _) => {
            var info = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = true };
            info.ArgumentList.Add("/select,"); info.ArgumentList.Add(path);
            System.Diagnostics.Process.Start(info);
        };
        row.Children.Add(show); parent.Children.Add(row);
        var reveal = new HyperlinkButton { Content = "Show path", Padding = new Thickness(0) };
        var fullPath = new TextBox { IsReadOnly = true, Text = path, Visibility = Visibility.Collapsed };
        reveal.Click += (_, _) => fullPath.Visibility = fullPath.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        row.Children.Add(reveal); row.Children.Add(fullPath);
    }
}
