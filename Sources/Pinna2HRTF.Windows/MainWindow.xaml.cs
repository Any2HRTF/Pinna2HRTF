using Microsoft.Win32;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Pinna2HRTF.Windows;

public partial class MainWindow : Window
{
    readonly ObservableCollection<ProjectRecord> projects = [];
    readonly ObservableCollection<Artifact> artifacts = [];
    readonly Dictionary<Guid, Process> runningProcesses = [];
    readonly Dictionary<Guid, Stage> runningStages = [];
    readonly Dictionary<Guid, Queue<Stage>> queuedStages = [];
    readonly Dictionary<Guid, HashSet<Stage>> failedStages = [];
    readonly Dictionary<Guid, string> projectLogs = [];
    readonly Dictionary<Guid, ProjectViewerState> viewerStates = [];
    readonly Dictionary<string, SettingHelpEntry> settingHelp = [];
    readonly JsonSerializerOptions jsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true, Converters = { new JsonStringEnumConverter() } };
    ProjectRegistry registry = new();
    EnvironmentConfig environment = new();
    bool loading;
    bool rotatingMesh;
    System.Windows.Point lastMeshPointer;
    double meshYaw;
    double meshPitch;
    double meshDistance;
    Point3D meshCenter;
    double meshMaximumDimension = 180;
    double meshFrontDirection = -1;
    string? selectedArtifactPath;
    string packageRoot = "";
    string appData = "";
    string registryPath = "";
    string viewerStatePath = "";
    bool refreshingArtifacts;
    readonly DispatcherTimer statusTimer = new() { Interval = TimeSpan.FromSeconds(2) };

    public MainWindow()
    {
        InitializeComponent();
        ProjectList.ItemsSource = projects;
        ArtifactPicker.ItemsSource = artifacts;
        SystemEvents.UserPreferenceChanged += UserPreferenceChanged;
        statusTimer.Tick += (_, _) =>
        {
            RefreshNumCalcStatus();
            RefreshPipelineStatus();
        };
    }

    void WindowLoaded(object sender, RoutedEventArgs e)
    {
        packageRoot = FindPackageRoot();
        LoadSettingHelp();
        appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinna2HRTF");
        registryPath = Path.Combine(appData, "projects.json");
        viewerStatePath = Path.Combine(appData, "viewer-state.json");
        Directory.CreateDirectory(appData);
        Directory.CreateDirectory(Path.Combine(appData, "Cache", "matplotlib"));
        Directory.CreateDirectory(Path.Combine(appData, "Cache", "python"));
        Directory.CreateDirectory(Path.Combine(appData, "Blender", "config"));
        Directory.CreateDirectory(Path.Combine(appData, "Blender", "scripts"));
        Directory.CreateDirectory(Path.Combine(appData, "Blender", "datafiles"));
        if (BundledPythonExecutable() != null)
        {
            var obsoleteUvCache = Path.Combine(appData, "Cache", "uv");
            if (Directory.Exists(obsoleteUvCache))
                Directory.Delete(obsoleteUvCache, true);
        }
        LoadRegistry();
        LoadViewerStates();
        foreach (var project in projects)
        {
            project.Settings.Preprocessing.FrequencyStepCount = Math.Max(int.TryParse(project.Settings.Preprocessing.FrequencyStepCount, out var steps) ? steps : 129, 2).ToString();
            if (project.Settings.Inference.TargetLeftFolder == "Target STL Left") project.Settings.Inference.TargetLeftFolder = "Input/Left";
            if (project.Settings.Inference.TargetRightFolder == "Target STL Right") project.Settings.Inference.TargetRightFolder = "Input/Right";
            if (project.Settings.Inference.PredictionLeftFolder == "Prediction STL Left") project.Settings.Inference.PredictionLeftFolder = "Intermediates/Left";
            if (project.Settings.Inference.PredictionRightFolder == "Prediction STL Right") project.Settings.Inference.PredictionRightFolder = "Intermediates/Right";
            if (project.Settings.Inference.PredictionLeftFolder == "Intermediates/Prediction STL Left") project.Settings.Inference.PredictionLeftFolder = "Intermediates/Left";
            if (project.Settings.Inference.PredictionRightFolder == "Intermediates/Prediction STL Right") project.Settings.Inference.PredictionRightFolder = "Intermediates/Right";
            var projectDirectories = Directory.Exists(project.SaveLocation) ? Directory.EnumerateDirectories(project.SaveLocation).ToArray() : Array.Empty<string>();
            var legacyIntermediates = projectDirectories.FirstOrDefault(path => Path.GetFileName(path) == "intermediates");
            var currentIntermediates = projectDirectories.FirstOrDefault(path => Path.GetFileName(path) == "Intermediates");
            if (legacyIntermediates != null && currentIntermediates == null)
            {
                var migrationPath = Path.Combine(project.SaveLocation, ".pinna2hrtf-intermediates-migration");
                Directory.Move(legacyIntermediates, migrationPath);
                Directory.Move(migrationPath, Path.Combine(project.SaveLocation, "Intermediates"));
            }
        }
        if (BundledPythonExecutable() != null)
        {
            environment = DefaultEnvironment();
            var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
            foreach (var project in projects)
            {
                var bundledConfig = Path.Combine(resources, Path.GetFileName(project.Settings.Inference.ModelConfig));
                var bundledCheckpoint = Path.Combine(resources, Path.GetFileName(project.Settings.Inference.ModelCheckpoint));
                if ((project.Settings.Inference.ModelConfig.Contains("HRTFCalculation", StringComparison.OrdinalIgnoreCase) || !File.Exists(project.Settings.Inference.ModelConfig)) && File.Exists(bundledConfig))
                    project.Settings.Inference.ModelConfig = bundledConfig;
                if ((project.Settings.Inference.ModelCheckpoint.Contains("HRTFCalculation", StringComparison.OrdinalIgnoreCase) || !File.Exists(project.Settings.Inference.ModelCheckpoint)) && File.Exists(bundledCheckpoint))
                    project.Settings.Inference.ModelCheckpoint = bundledCheckpoint;
            }
            Persist();
        }
        RefreshModelOptions();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
        UpdateViewerAppearance();
        statusTimer.Start();
        RefreshNumCalcStatus();
        RefreshPipelineStatus();
    }

    bool projectsExpanded = true;

    void ProjectsExpanded(object sender, RoutedEventArgs e) => SetProjectsExpanded(true);
    void ProjectsCollapsed(object sender, RoutedEventArgs e) => SetProjectsExpanded(false);
    void SetProjectsExpanded(bool expanded)
    {
        if (ProjectsColumn == null || ProjectList == null) return;
        projectsExpanded = expanded;
        ProjectList.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        ProjectsColumn.Width = expanded ? new GridLength(280) : new GridLength(40);
        ProjectsHeaderGrid.Margin = expanded ? new Thickness(10, 8, 10, 8) : new Thickness(0, 8, 0, 8);
        ProjectsTitle.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        NewProjectButton.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        ImportProjectButton.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        DuplicateProjectButton.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        DeleteProjectButton.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        ProjectsToggle.ToolTip = expanded ? "Collapse projects" : "Expand projects";
    }

    bool liveLogExpanded = true;

    void LiveLogExpanded(object sender, RoutedEventArgs e) => SetLiveLogExpanded(true);
    void LiveLogCollapsed(object sender, RoutedEventArgs e) => SetLiveLogExpanded(false);
    void SetLiveLogExpanded(bool expanded)
    {
        if (LiveLogPanel == null || LiveLogContent == null) return;
        liveLogExpanded = expanded;
        LiveLogContent.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        if (LiveLogPanel.Parent is Grid grid && grid.RowDefinitions.Count > 2) grid.RowDefinitions[2].Height = expanded ? new GridLength(170) : GridLength.Auto;
    }

    void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (runningProcesses.Count > 0)
        {
            var result = System.Windows.MessageBox.Show(this, "A pipeline task is still running. Quitting will stop it and may leave incomplete outputs. Quit anyway?", "Quit Pinna2HRTF", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (result != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }
        statusTimer.Stop();
        SystemEvents.UserPreferenceChanged -= UserPreferenceChanged;
        foreach (var process in runningProcesses.Values.ToList())
            TryTerminate(process);
        Persist();
    }

    void LoadSettingHelp()
    {
        var path = Path.Combine(packageRoot, "ProjectSettingHelp.json");
        if (!File.Exists(path))
            return;
        try
        {
            var entries = JsonSerializer.Deserialize<List<SettingHelpEntry>>(File.ReadAllText(path), jsonOptions) ?? [];
            foreach (var entry in entries)
                settingHelp[entry.Id] = entry;
        }
        catch
        {
            settingHelp.Clear();
        }
    }

    void SettingInfoClicked(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button button || button.Tag is not string id || !settingHelp.TryGetValue(id, out var entry))
            return;
        SettingHelpTitle.Text = entry.Title;
        SettingHelpDescription.Text = entry.Description;
        SettingHelpPublications.ItemsSource = entry.Publications;
        SettingHelpPublicationsLabel.Visibility = entry.Publications.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        SettingHelpPopup.PlacementTarget = button;
        SettingHelpPopup.IsOpen = true;
        button.Focus();
    }

    void PublicationClicked(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button button && button.Tag is string url)
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }

    void UserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e) => Dispatcher.BeginInvoke(() => UpdateViewerAppearance());

    void WindowPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape && SettingHelpPopup.IsOpen)
        {
            SettingHelpPopup.IsOpen = false;
            e.Handled = true;
        }
    }

    void UpdateViewerAppearance()
    {
        var darkMode = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue("AppsUseLightTheme") is int value && value == 0;
        UpdateTitleBar(darkMode);
        SetThemeBrush("AppBackgroundBrush", darkMode ? "#191919" : "#f3f6f5");
        SetThemeBrush("PanelBackgroundBrush", darkMode ? "#202020" : "#ffffff");
        SetThemeBrush("SettingsBackgroundBrush", darkMode ? "#191919" : "#fbfbfc");
        SetThemeBrush("InputBackgroundBrush", darkMode ? "#2f2f2f" : "#ffffff");
        SetThemeBrush("PrimaryTextBrush", darkMode ? "#e6e6e6" : "#1a1a1a");
        SetThemeBrush("SecondaryTextBrush", darkMode ? "#9b9b9b" : "#69717d");
        SetThemeBrush("BorderBrush", darkMode ? "#3a3a3a" : "#d9dee8");
        SetThemeBrush("ComboSelectedBrush", darkMode ? "#3a3a3a" : "#d9eaf0");
        SetThemeBrush("ComboHoverBrush", darkMode ? "#333333" : "#edf3f5");
        MeshViewerBackground.Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#1f1f1f" : "#edf3f2"));
        Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#202020" : "#f3f6f5"));
        var panelBrush = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#2b2b2b" : "#ffffff"));
        ProjectsPane.Background = panelBrush; ArtifactCard.Background = panelBrush; LiveLogHeader.Background = panelBrush; LiveLogContent.Background = panelBrush;
        LogText.Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#202020" : "#ffffff"));
        LogText.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#e6e6e6" : "#1a1a1a"));
        var inputBackground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#2f2f2f" : "#ffffff"));
        var inputForeground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#e6e6e6" : "#1a1a1a"));
        foreach (var input in new[] { ProjectNameBox, LeftEarBox, RightEarBox, SaveLocationBox, EvaluationGridBox, HeadRadiusBox, MinFrequencyBox, MaxFrequencyBox, FrequencyStepsBox, SourceAssignmentFaceCountBox, MeshMinEdgeBox, MeshMaxEdgeBox, MeshMaxErrorBox, MeshGammaBox, MeshGammaOppositeBox, MaxInstancesBox, MaxCpuLoadBox, LevelOffsetBox })
        {
            input.Background = inputBackground; input.Foreground = inputForeground;
        }
        SettingsPane.Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#252525" : "#fbfbfc"));
        Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#f2f2f2" : "#1a1a1a"));
        MeshViewerBackground.BorderBrush = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#3b3b3b" : "#dbe5e3"));
        ViewerPlaceholder.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#c8c8c8" : "#69717d"));
        MeshControlsHint.Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#cc2b2b2b" : "#ccffffff"));
        MeshControlsHintText.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#c8c8c8" : "#69717d"));
        SettingHelpCard.Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#2b2b2b" : "#ffffff"));
        SettingHelpCard.BorderBrush = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#505050" : "#cfd6df"));
        SettingHelpTitle.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#f0f0f0" : "#20242a"));
        SettingHelpDescription.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#d0d0d0" : "#3f4854"));
        SettingHelpPublicationsLabel.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(darkMode ? "#c8c8c8" : "#69717d"));
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, uint attribute, ref int value, uint size);
    void UpdateTitleBar(bool darkMode)
    {
        var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var value = darkMode ? 1 : 0;
        _ = DwmSetWindowAttribute(hwnd, 20, ref value, sizeof(int));
    }

    void SetThemeBrush(string key, string hex)
    {
        Resources[key] = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
    }

    void LoadRegistry()
    {
        if (File.Exists(registryPath))
        {
            try
            {
                registry = JsonSerializer.Deserialize<ProjectRegistry>(File.ReadAllText(registryPath), jsonOptions) ?? new ProjectRegistry();
            }
            catch
            {
                registry = new ProjectRegistry();
            }
        }
        environment = registry.Environment.IsEmpty ? DefaultEnvironment() : registry.Environment;
        projects.Clear();
        foreach (var project in registry.Projects)
            projects.Add(project);
        if (projects.Count == 0)
            CreateProject();
        var selected = projects.FirstOrDefault(p => p.Id == registry.SelectedProjectID) ?? projects.FirstOrDefault();
        ProjectList.SelectedItem = selected;
    }

    void Persist()
    {
        registry = new ProjectRegistry { Projects = projects.ToList(), SelectedProjectID = SelectedProject?.Id, Environment = environment };
        Directory.CreateDirectory(appData);
        File.WriteAllText(registryPath, JsonSerializer.Serialize(registry, jsonOptions));
    }

    void LoadViewerStates()
    {
        if (!File.Exists(viewerStatePath))
            return;
        try
        {
            var loaded = JsonSerializer.Deserialize<Dictionary<Guid, ProjectViewerState>>(File.ReadAllText(viewerStatePath), jsonOptions);
            if (loaded != null)
                foreach (var pair in loaded)
                    viewerStates[pair.Key] = pair.Value;
        }
        catch
        {
            viewerStates.Clear();
        }
    }

    void SaveViewerStates()
    {
        if (string.IsNullOrWhiteSpace(viewerStatePath))
            return;
        File.WriteAllText(viewerStatePath, JsonSerializer.Serialize(viewerStates, jsonOptions));
    }

    string FindPackageRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            if (File.Exists(Path.Combine(current.FullName, "pyproject.toml")) && Directory.Exists(Path.Combine(current.FullName, "HRTFCalculation")))
                return current.FullName;
            current = current.Parent;
        }
        current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            var candidate = Path.Combine(current.FullName, "Pinna2HRTF");
            if (File.Exists(Path.Combine(candidate, "pyproject.toml")) && Directory.Exists(Path.Combine(candidate, "HRTFCalculation")))
                return candidate;
            current = current.Parent;
        }
        return AppContext.BaseDirectory;
    }

    EnvironmentConfig DefaultEnvironment()
    {
        var external = Directory.Exists(Path.Combine(packageRoot, "External")) ? Path.Combine(packageRoot, "External") : Path.Combine(appData, "External");
        var bin = Path.Combine(external, "bin");
        return new EnvironmentConfig
        {
            UvExecutable = FirstExecutable(Path.Combine(bin, "uv.exe"), "uv.exe"),
            NumCalcExecutable = FirstExecutable(Path.Combine(bin, "NumCalc.exe"), "NumCalc.exe"),
            MeshGradingExecutable = FirstExecutable(Path.Combine(bin, "hrtf_mesh_grading.exe"), "hrtf_mesh_grading.exe"),
            ExternalDir = external
        };
    }

    string FirstExecutable(string bundled, string name)
    {
        if (File.Exists(bundled))
            return bundled;
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var entry in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(entry.Trim(), name);
            if (File.Exists(candidate))
                return candidate;
        }
        return bundled;
    }

    ProjectRecord? SelectedProject => ProjectList.SelectedItem as ProjectRecord;

    void RefreshProjectList()
    {
        foreach (var project in projects)
        {
            project.IsRunning = runningProcesses.ContainsKey(project.Id);
            project.StatusText = NextStageSummary(project);
        }
        ProjectList.Items.Refresh();
        DuplicateProjectButton.IsEnabled = SelectedProject != null;
    }

    void LoadSelectedProject()
    {
        loading = true;
        var project = SelectedProject;
        ProjectNameBox.Text = project?.Name ?? "";
        LeftEarBox.Text = project?.LeftEar ?? "";
        RightEarBox.Text = project?.RightEar ?? "";
        SaveLocationBox.Text = project?.SaveLocation ?? "";
        UsePredictionsBox.IsChecked = project?.Settings.Inference.UsePredictionsForPreprocessing ?? true;
        EvaluationGridBox.Text = project?.Settings.Preprocessing.EvaluationGrid ?? "";
        UseHeadRadiusBox.IsChecked = project?.Settings.Preprocessing.UseCustomHeadRadius ?? project?.Settings.Preprocessing.HeadRadius != null;
        HeadRadiusBox.Text = project?.Settings.Preprocessing.HeadRadius ?? "0";
        MinFrequencyBox.Text = project?.Settings.Preprocessing.MinFrequency ?? "0";
        MaxFrequencyBox.Text = project?.Settings.Preprocessing.MaxFrequency ?? "24000";
        FrequencyStepsBox.Text = project?.Settings.Preprocessing.FrequencyStepCount ?? "129";
        SourceAssignmentFaceCountBox.Text = project?.Settings.Preprocessing.SourceAssignmentFaceCount ?? "6";
        MeshMinEdgeBox.Text = project?.Settings.Preprocessing.MeshMinEdgeLength ?? "0.5";
        MeshMaxEdgeBox.Text = project?.Settings.Preprocessing.MeshMaxEdgeLength ?? "10.0";
        MeshMaxErrorBox.Text = project?.Settings.Preprocessing.MeshMaxError ?? "0.5";
        MeshGammaBox.Text = project?.Settings.Preprocessing.MeshGamma ?? "0.2";
        MeshGammaOppositeBox.Text = project?.Settings.Preprocessing.MeshGammaOpposite ?? "0.1";
        MaxInstancesBox.Text = project?.Settings.NumCalc.MaxInstances ?? "1";
        MaxCpuLoadBox.Text = project?.Settings.NumCalc.MaxCpuLoad ?? "90";
        AdaptiveFmmLengthBox.IsChecked = project?.Settings.NumCalc.AdaptiveFmmLength ?? true;
        NormalizeHrtfsBox.IsChecked = project?.Settings.Postprocessing?.Normalize ?? true;
        LevelOffsetBox.Text = project?.Settings.Postprocessing?.LevelOffsetDB ?? "-30";
        LevelOffsetBox.IsEnabled = NormalizeHrtfsBox.IsChecked == true;
        SelectModel(project);
        loading = false;
        RefreshPipelineStatus();
    }

    void RefreshModelOptions()
    {
        ModelPicker.Items.Clear();
        var resourceDir = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        if (Directory.Exists(resourceDir))
        {
            foreach (var file in Directory.GetFiles(resourceDir, "*.y*ml").OrderBy(Path.GetFileName))
                ModelPicker.Items.Add(ModelName(file));
        }
    }

    void SelectModel(ProjectRecord? project)
    {
        if (project == null)
            return;
        var name = ModelName(project.Settings.Inference.ModelConfig);
        ModelPicker.SelectedItem = ModelPicker.Items.Cast<string>().FirstOrDefault(x => x == name) ?? ModelPicker.Items.Cast<string>().FirstOrDefault();
    }

    string ModelName(string path)
    {
        var stem = Path.GetFileNameWithoutExtension(path);
        return stem.StartsWith("Local ", StringComparison.OrdinalIgnoreCase) ? stem[6..] : stem;
    }

    void ProjectSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        Persist();
        LoadSelectedProjectLog();
        LoadSelectedProject();
        RefreshArtifacts();
    }

    void LoadSelectedProjectLog()
    {
        var project = SelectedProject;
        LogText.Text = project != null && projectLogs.TryGetValue(project.Id, out var log) ? log : "";
        LogText.ScrollToEnd();
    }

    void ProjectEdited(object sender, RoutedEventArgs e)
    {
        if (loading || SelectedProject == null)
            return;
        var project = SelectedProject;
        project.Name = ProjectNameBox.Text;
        project.LeftEar = LeftEarBox.Text;
        project.RightEar = RightEarBox.Text;
        project.SaveLocation = SaveLocationBox.Text;
        project.Settings.Inference.UsePredictionsForPreprocessing = UsePredictionsBox.IsChecked == true;
        project.Settings.Preprocessing.EvaluationGrid = string.IsNullOrWhiteSpace(EvaluationGridBox.Text) ? null : EvaluationGridBox.Text;
        project.Settings.Preprocessing.UseCustomHeadRadius = UseHeadRadiusBox.IsChecked == true;
        project.Settings.Preprocessing.HeadRadius = string.IsNullOrWhiteSpace(HeadRadiusBox.Text) ? null : HeadRadiusBox.Text;
        project.Settings.Preprocessing.MinFrequency = MinFrequencyBox.Text;
        project.Settings.Preprocessing.MaxFrequency = MaxFrequencyBox.Text;
        project.Settings.Preprocessing.FrequencyStepCount = FrequencyStepsBox.Text;
        project.Settings.Preprocessing.SourceAssignmentFaceCount = SourceAssignmentFaceCountBox.Text;
        project.Settings.Preprocessing.MeshMinEdgeLength = MeshMinEdgeBox.Text;
        project.Settings.Preprocessing.MeshMaxEdgeLength = MeshMaxEdgeBox.Text;
        project.Settings.Preprocessing.MeshMaxError = MeshMaxErrorBox.Text;
        project.Settings.Preprocessing.MeshGamma = MeshGammaBox.Text;
        project.Settings.Preprocessing.MeshGammaOpposite = MeshGammaOppositeBox.Text;
        project.Settings.NumCalc.MaxInstances = MaxInstancesBox.Text;
        project.Settings.NumCalc.MaxCpuLoad = MaxCpuLoadBox.Text;
        project.Settings.NumCalc.AdaptiveFmmLength = AdaptiveFmmLengthBox.IsChecked == true;
        project.Settings.Postprocessing ??= new PostprocessingSettings();
        project.Settings.Postprocessing.Normalize = NormalizeHrtfsBox.IsChecked == true;
        project.Settings.Postprocessing.LevelOffsetDB = LevelOffsetBox.Text;
        LevelOffsetBox.IsEnabled = NormalizeHrtfsBox.IsChecked == true;
        Persist();
        RefreshProjectList();
        RefreshArtifacts();
        RefreshPipelineStatus();
    }

    void ModelSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || SelectedProject == null || ModelPicker.SelectedItem is not string model)
            return;
        var resourceDir = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        SelectedProject.Settings.Inference.ModelConfig = Path.Combine(resourceDir, $"Local {model}.yaml");
        SelectedProject.Settings.Inference.ModelCheckpoint = Path.Combine(resourceDir, $"Local {model}.pth");
        Persist();
        RefreshPipelineStatus();
    }

    void CreateProjectClicked(object sender, RoutedEventArgs e) => CreateProject();

    void ImportProjectClicked(object sender, RoutedEventArgs e) => ImportProject();

    void DuplicateProjectClicked(object sender, RoutedEventArgs e) => DuplicateProject();

    void ImportProject()
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "Choose an existing Pinna2HRTF project folder.",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false
        };
        if (dialog.ShowDialog() == Forms.DialogResult.OK)
            ImportProject(dialog.SelectedPath);
    }

    void ImportProject(string folder)
    {
        var project = NewProject(projects.Count + 1);
        project.Name = new DirectoryInfo(folder).Name;
        project.LeftEar = ImportedMesh(folder, "Left");
        project.RightEar = ImportedMesh(folder, "Right");
        project.SaveLocation = folder;
        project.InputHandling = InputHandling.Reference;
        var legacyIntermediates = Directory.EnumerateDirectories(folder).FirstOrDefault(path => Path.GetFileName(path) == "intermediates");
        var currentIntermediates = Directory.EnumerateDirectories(folder).FirstOrDefault(path => Path.GetFileName(path) == "Intermediates");
        if (legacyIntermediates != null && currentIntermediates == null)
        {
            var migrationPath = Path.Combine(folder, ".pinna2hrtf-intermediates-migration");
            Directory.Move(legacyIntermediates, migrationPath);
            Directory.Move(migrationPath, Path.Combine(folder, "Intermediates"));
        }
        foreach (var configName in new[] { "Project Settings.yaml", ".pinna2hrtf_native_run.yaml", "pipeline.yaml" })
        {
            var configPath = Path.Combine(folder, configName);
            if (!File.Exists(configPath))
                continue;
            var section = "";
            foreach (var line in File.ReadLines(configPath))
            {
                if (!line.StartsWith(" ") && line.EndsWith(":"))
                    section = line[..^1];
                var setting = line.Trim();
                if (section == "inference" && (setting == "enabled: false" || setting == "use_predictions_for_preprocessing: false"))
                    project.Settings.Inference.UsePredictionsForPreprocessing = false;
            }
        }
        projects.Add(project);
        failedStages[project.Id] = [];
        ProjectList.SelectedItem = project;
        Persist();
        RefreshProjectList();
        RefreshArtifacts();
        var completed = Stage.GetValues().Where(stage => StageIsComplete(stage, project)).Select(stage => stage.Title).ToList();
        AppendLog($"Imported project folder {folder}. Completed stages: {(completed.Count == 0 ? "none detected" : string.Join(", ", completed))}");
    }

    string ImportedMesh(string folder, string side)
    {
        var candidates = new[]
        {
            Path.Combine(folder, "Input", side),
            Path.Combine(folder, "Intermediates", side),
            Path.Combine(folder, "Intermediates", $"Prediction STL {side}"),
            Path.Combine(folder, "Intermediates", $"ICP STL {side}"),
            Path.Combine(folder, $"Target STL {side}"),
            Path.Combine(folder, $"ICP STL {side}"),
            Path.Combine(folder, $"Prediction STL {side}")
        };
        foreach (var candidate in candidates)
        {
            if (!Directory.Exists(candidate))
                continue;
            var files = Directory.EnumerateFiles(candidate).Where(IsMesh).OrderBy(path => path).ToList();
            var exact = files.FirstOrDefault(path => string.Equals(Path.GetFileNameWithoutExtension(path), side, StringComparison.OrdinalIgnoreCase));
            if (exact != null)
                return exact;
            if (files.Count > 0)
                return files[0];
        }
        foreach (var extension in new[] { ".stl", ".ply" })
        {
            var candidate = Path.Combine(folder, side + extension);
            if (File.Exists(candidate))
                return candidate;
        }
        return "";
    }

    void CreateProject()
    {
        var project = NewProject(projects.Count + 1);
        projects.Add(project);
        failedStages[project.Id] = [];
        ProjectList.SelectedItem = project;
        Persist();
        RefreshProjectList();
    }

    void DuplicateProject()
    {
        var selected = SelectedProject;
        if (selected == null)
            return;
        var duplicate = Clone(selected);
        duplicate.Id = Guid.NewGuid();
        duplicate.Name = $"{selected.Name} Copy";
        if (!string.IsNullOrWhiteSpace(selected.SaveLocation))
        {
            var original = new DirectoryInfo(selected.SaveLocation);
            var parent = original.Parent?.FullName ?? selected.SaveLocation;
            var baseName = string.IsNullOrWhiteSpace(original.Name) ? "Project" : original.Name;
            var duplicateLocation = Path.Combine(parent, $"{baseName} Copy");
            var suffix = 2;
            while (Directory.Exists(duplicateLocation))
            {
                duplicateLocation = Path.Combine(parent, $"{baseName} Copy {suffix}");
                suffix++;
            }
            duplicate.SaveLocation = duplicateLocation;
        }
        projects.Add(duplicate);
        failedStages[duplicate.Id] = [];
        ProjectList.SelectedItem = duplicate;
        Persist();
        RefreshProjectList();
        RefreshArtifacts();
    }

    ProjectRecord NewProject(int index)
    {
        var resourceDir = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        return new ProjectRecord
        {
            Name = $"Project {index}",
            Settings = new ProjectSettings
            {
                Inference = new InferenceSettings
                {
                    ModelConfig = Path.Combine(resourceDir, "Local 3 Views.yaml"),
                    ModelCheckpoint = Path.Combine(resourceDir, "Local 3 Views.pth")
                }
            }
        };
    }

    void RemoveProjectClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedProject == null)
            return;
        StopProject(SelectedProject);
        projectLogs.Remove(SelectedProject.Id);
        projects.Remove(SelectedProject);
        if (projects.Count == 0)
            CreateProject();
        else
            ProjectList.SelectedIndex = 0;
        Persist();
        RefreshProjectList();
    }

    void BrowseLeftEarClicked(object sender, RoutedEventArgs e) => BrowseFile(LeftEarBox, "Mesh files|*.stl;*.ply|All files|*.*");
    void BrowseRightEarClicked(object sender, RoutedEventArgs e) => BrowseFile(RightEarBox, "Mesh files|*.stl;*.ply|All files|*.*");
    void BrowseSaveLocationClicked(object sender, RoutedEventArgs e) => BrowseFolder(SaveLocationBox);
    void BrowseEvaluationGridClicked(object sender, RoutedEventArgs e) => BrowseFolder(EvaluationGridBox);

    void BrowseFile(System.Windows.Controls.TextBox box, string filter)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = filter, CheckFileExists = false };
        if (dialog.ShowDialog(this) == true)
            box.Text = dialog.FileName;
    }

    void BrowseFolder(System.Windows.Controls.TextBox box)
    {
        using var dialog = new Forms.FolderBrowserDialog { SelectedPath = Directory.Exists(box.Text) ? box.Text : "" };
        if (dialog.ShowDialog() == Forms.DialogResult.OK)
            box.Text = dialog.SelectedPath;
    }

    void RefreshArtifacts()
    {
        var selectedPath = SelectedProject != null && viewerStates.TryGetValue(SelectedProject.Id, out var state) ? state.SelectedArtifactPath : null;
        refreshingArtifacts = true;
        artifacts.Clear();
        if (SelectedProject != null)
        {
            foreach (var artifact in ArtifactsFor(SelectedProject).Where(a => a.Exists))
                artifacts.Add(artifact);
        }
        ArtifactPicker.SelectedItem = artifacts.FirstOrDefault(artifact => artifact.Path == selectedPath);
        refreshingArtifacts = false;
        RefreshProjectList();
        if (ArtifactPicker.SelectedItem is Artifact selectedArtifact)
            OpenArtifact(selectedArtifact);
        else
            ResetViewer();
    }

    List<Artifact> ArtifactsFor(ProjectRecord project)
    {
        var output = project.SaveLocation;
        var settings = project.Settings.Inference;
        var list = new List<Artifact>();
        var hrtfFolder = Path.Combine(output, "HRTF");
        if (Directory.Exists(hrtfFolder))
            foreach (var plot in Directory.EnumerateFiles(hrtfFolder).Where(path => new[] { ".jpeg", ".jpg", ".png" }.Contains(Path.GetExtension(path).ToLowerInvariant())).OrderBy(path => Path.GetFileName(path)))
            {
                var name = Path.GetFileNameWithoutExtension(plot);
                list.Add(new(name.Contains("horizontal", StringComparison.OrdinalIgnoreCase) ? "Horizontal HRTF plot" : name.Contains("median", StringComparison.OrdinalIgnoreCase) ? "Median HRTF plot" : name, plot));
            }
        if (!string.IsNullOrWhiteSpace(project.LeftEar))
        {
            list.Add(new("Input left ear", project.LeftEar));
            list.Add(new("Left simulation mesh", Path.Combine(output, "Intermediates", "Left", "graded_head.ply")));
        }
        if (!string.IsNullOrWhiteSpace(project.RightEar))
        {
            list.Add(new("Input right ear", project.RightEar));
            list.Add(new("Right simulation mesh", Path.Combine(output, "Intermediates", "Right", "graded_head.ply")));
        }
        if (!string.IsNullOrWhiteSpace(project.LeftEar))
            AddMeshFolder(list, "Predicted left ear", Path.Combine(output, settings.PredictionLeftFolder), true);
        if (!string.IsNullOrWhiteSpace(project.RightEar))
            AddMeshFolder(list, "Predicted right ear", Path.Combine(output, settings.PredictionRightFolder), true);
        return list;
    }

    void AddMeshFolder(List<Artifact> list, string title, string folder, bool predictionsOnly = false)
    {
        if (!Directory.Exists(folder))
            return;
        var files = Directory.GetFiles(folder).Where(path => IsMesh(path) && (!predictionsOnly || Path.GetFileName(path).StartsWith("Prediction_", StringComparison.OrdinalIgnoreCase))).OrderBy(x => x).ToList();
        if (files.Count == 1)
        {
            list.Add(new Artifact(title, files[0]));
            return;
        }
        foreach (var file in files)
            list.Add(new Artifact($"{title} - {Path.GetFileNameWithoutExtension(file)}", file));
    }

    void ArtifactSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (refreshingArtifacts)
            return;
        if (ArtifactPicker.SelectedItem is not Artifact artifact)
            return;
        OpenArtifact(artifact);
    }

    void OpenArtifact(Artifact artifact)
    {
        ResetViewer();
        selectedArtifactPath = artifact.Path;
        RememberSelectedArtifact(artifact.Path);
        SelectedArtifactText.Text = artifact.Path;
        if (artifact.IsImage)
        {
            ImagePreview.Source = new BitmapImage(new Uri(artifact.Path));
            ImagePreview.Visibility = Visibility.Visible;
            ViewerPlaceholder.Visibility = Visibility.Collapsed;
        }
        else if (artifact.IsMesh)
        {
            try
            {
                var model = MeshLoader.Load(artifact.Path, out var originalCenter, out var meshScale);
                var bounds = model.Bounds;
                meshCenter = new Point3D((bounds.X + bounds.SizeX / 2), (bounds.Y + bounds.SizeY / 2), (bounds.Z + bounds.SizeZ / 2));
                meshMaximumDimension = Math.Max(bounds.SizeX, Math.Max(bounds.SizeY, bounds.SizeZ));
                meshFrontDirection = artifact.Path.Contains("left", StringComparison.OrdinalIgnoreCase) ? 1 : -1;
                MeshViewport.Children.Add(new ModelVisual3D { Content = model });
                if (MicrophonePosition(artifact.Path) is Point3D microphone)
                {
                    var transformedMicrophone = new Point3D(
                        (microphone.X - originalCenter.X) * meshScale,
                        (microphone.Y - originalCenter.Y) * meshScale,
                        (microphone.Z - originalCenter.Z) * meshScale);
                    var markerMaterial = new MaterialGroup();
                    markerMaterial.Children.Add(new DiffuseMaterial(new SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 149, 0))));
                    markerMaterial.Children.Add(new EmissiveMaterial(new SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 149, 0))));
                    MeshViewport.Children.Add(new ModelVisual3D { Content = new GeometryModel3D(MeshLoader.CreateSphere(transformedMicrophone, Math.Max(meshMaximumDimension * 0.006, 0.35)), markerMaterial) { BackMaterial = markerMaterial } });
                }
                ResetMeshCamera();
                MeshControlsHint.Visibility = Visibility.Visible;
                ViewerPlaceholder.Visibility = Visibility.Collapsed;
            }
            catch (Exception error)
            {
                AppendLog($"Cannot open mesh: {error.Message}");
            }
        }
        else
        {
            if (artifact.IsText)
            {
                try
                {
                    LogText.Text = File.ReadAllText(artifact.Path);
                    ViewerPlaceholder.Text = Path.GetFileName(artifact.Path);
                }
                catch (Exception error)
                {
                    AppendLog($"Cannot open artifact: {error.Message}");
                }
            }
            else
            {
                ViewerPlaceholder.Text = $"{Path.GetFileName(artifact.Path)} selected";
            }
        }
    }

    void ResetViewer()
    {
        while (MeshViewport.Children.Count > 4)
            MeshViewport.Children.RemoveAt(4);
        ImagePreview.Source = null;
        ImagePreview.Visibility = Visibility.Collapsed;
        MeshControlsHint.Visibility = Visibility.Collapsed;
        ViewerPlaceholder.Text = "No artifact selected";
        ViewerPlaceholder.Visibility = Visibility.Visible;
        SelectedArtifactText.Text = "Select an artifact";
        selectedArtifactPath = null;
    }

    void MeshViewportMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (MeshViewport.Children.Count <= 4)
            return;
        rotatingMesh = true;
        lastMeshPointer = e.GetPosition(MeshViewport);
        MeshViewport.CaptureMouse();
        e.Handled = true;
    }

    void MeshViewportMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        StopMeshRotation();
        e.Handled = true;
    }

    void MeshViewportMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
            StopMeshRotation();
    }

    void MeshViewportMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!rotatingMesh || e.LeftButton != MouseButtonState.Pressed)
            return;

        var pointer = e.GetPosition(MeshViewport);
        meshYaw += (pointer.X - lastMeshPointer.X) * 0.45;
        meshPitch = Math.Clamp(meshPitch - (pointer.Y - lastMeshPointer.Y) * 0.45, -89, 89);
        lastMeshPointer = pointer;
        UpdateMeshCamera();
    }

    void MeshViewportMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (MeshViewport.Children.Count <= 4)
            return;
        meshDistance = Math.Clamp(meshDistance * Math.Pow(0.88, e.Delta / 120.0), 80, 1200);
        UpdateMeshCamera();
        SaveMeshCamera();
        e.Handled = true;
    }

    void StopMeshRotation()
    {
        rotatingMesh = false;
        if (MeshViewport.IsMouseCaptured)
            MeshViewport.ReleaseMouseCapture();
        SaveMeshCamera();
    }

    void ResetMeshCamera()
    {
        if (SelectedProject != null && selectedArtifactPath != null && viewerStates.TryGetValue(SelectedProject.Id, out var projectState) && projectState.CameraByArtifact.TryGetValue(selectedArtifactPath, out var cameraState))
        {
            meshYaw = cameraState.Yaw;
            meshPitch = cameraState.Pitch;
            meshDistance = cameraState.Distance;
        }
        else
        {
            meshYaw = meshFrontDirection > 0 ? 180 : 0;
            meshDistance = Math.Max(meshMaximumDimension * 1.7, 1);
            meshPitch = Math.Atan2(meshMaximumDimension * 0.12, meshDistance) * 180 / Math.PI;
        }
        UpdateMeshCamera();
    }

    void RememberSelectedArtifact(string path)
    {
        if (SelectedProject == null)
            return;
        if (!viewerStates.TryGetValue(SelectedProject.Id, out var state))
        {
            state = new ProjectViewerState();
            viewerStates[SelectedProject.Id] = state;
        }
        state.SelectedArtifactPath = path;
        SaveViewerStates();
    }

    void SaveMeshCamera()
    {
        if (SelectedProject == null || selectedArtifactPath == null || MeshViewport.Children.Count <= 4)
            return;
        if (!viewerStates.TryGetValue(SelectedProject.Id, out var state))
        {
            state = new ProjectViewerState();
            viewerStates[SelectedProject.Id] = state;
        }
        state.CameraByArtifact[selectedArtifactPath] = new MeshCameraState { Yaw = meshYaw, Pitch = meshPitch, Distance = meshDistance };
        SaveViewerStates();
    }

    void UpdateMeshCamera()
    {
        var yaw = meshYaw * Math.PI / 180;
        var pitch = meshPitch * Math.PI / 180;
        var horizontalDistance = meshDistance * Math.Cos(pitch);
        var position = new Point3D(
            meshCenter.X + horizontalDistance * Math.Sin(yaw),
            meshCenter.Y - horizontalDistance * Math.Cos(yaw),
            meshCenter.Z + meshDistance * Math.Sin(pitch));
        MeshCamera.Position = position;
        MeshCamera.LookDirection = new Vector3D(meshCenter.X - position.X, meshCenter.Y - position.Y, meshCenter.Z - position.Z);
        MeshCamera.UpDirection = new Vector3D(0, 0, 1);
    }

    Point3D? MicrophonePosition(string meshPath)
    {
        if (!string.Equals(Path.GetFileName(meshPath), "graded_head.ply", StringComparison.OrdinalIgnoreCase) || SelectedProject == null)
            return null;
        var side = meshPath.Contains("left", StringComparison.OrdinalIgnoreCase) ? "Left" : meshPath.Contains("right", StringComparison.OrdinalIgnoreCase) ? "Right" : "";
        if (side.Length == 0)
            return null;
        var parametersPath = Path.Combine(SelectedProject.SaveLocation, "Projects", side, "parameters.json");
        if (!File.Exists(parametersPath))
            return null;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(parametersPath));
            if (!document.RootElement.TryGetProperty("sourceCenter", out var values) || values.ValueKind != JsonValueKind.Array || values.GetArrayLength() != 3)
                return null;
            var coordinates = values.EnumerateArray().Select(value => value.GetDouble() * 1000).ToArray();
            return new Point3D(coordinates[0], coordinates[1], coordinates[2]);
        }
        catch
        {
            return null;
        }
    }

    void RunInferenceClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Inference);
    void RunPreprocessingClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Preprocessing);
    void RunNumCalcClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Numcalc);
    void RunPostprocessingClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Postprocessing);

    void RunOrStop(Stage stage)
    {
        var project = SelectedProject;
        if (project != null && runningStages.TryGetValue(project.Id, out var active) && active == stage)
            StopProject(project);
        else
            RunStage(stage);
    }

    void RunNextClicked(object sender, RoutedEventArgs e)
    {
        var project = SelectedProject;
        if (project == null)
            return;
        var stage = AutomaticStages(project).FirstOrDefault(stage => !StageIsComplete(stage, project));
        if (stage == null)
        {
            AppendLog($"All pipeline steps are complete for {project.Name}.", project.Id);
            return;
        }
        RunStage(stage, project);
    }

    void RunAllClicked(object sender, RoutedEventArgs e)
    {
        var project = SelectedProject;
        if (project == null)
        {
            AppendLog("Create or select a project before running.");
            return;
        }
        if (runningProcesses.ContainsKey(project.Id))
        {
            AppendLog($"{project.Name} already has a running task.", project.Id);
            return;
        }
        var stages = AutomaticStages(project).Where(stage => !StageIsComplete(stage, project)).ToList();
        if (stages.Count == 0)
        {
            AppendLog($"All pipeline steps are complete for {project.Name}.", project.Id);
            return;
        }
        queuedStages[project.Id] = new Queue<Stage>(stages.Skip(1));
        AppendLog($"Run All queued for {project.Name}: {string.Join(" → ", stages.Select(stage => stage.Title))}", project.Id);
        RunStage(stages[0], project, true);
    }

    void RunStage(Stage stage, ProjectRecord? targetProject = null, bool continueQueued = false)
    {
        var project = targetProject ?? SelectedProject;
        if (project == null)
        {
            AppendLog("Create or select a project before running.");
            return;
        }
        if (runningProcesses.ContainsKey(project.Id))
        {
            AppendLog($"{project.Name} already has a running task.", project.Id);
            return;
        }
        if (!continueQueued)
            queuedStages.Remove(project.Id);
        if ((string.IsNullOrWhiteSpace(project.LeftEar) && string.IsNullOrWhiteSpace(project.RightEar)) || string.IsNullOrWhiteSpace(project.SaveLocation))
        {
            queuedStages.Remove(project.Id);
            AppendLog("Select at least one ear mesh and a save location before running.", project.Id);
            return;
        }
        if ((!string.IsNullOrWhiteSpace(project.LeftEar) && !File.Exists(project.LeftEar)) || (!string.IsNullOrWhiteSpace(project.RightEar) && !File.Exists(project.RightEar)))
        {
            queuedStages.Remove(project.Id);
            AppendLog("One or more configured ear mesh files are missing.", project.Id);
            RefreshPipelineStatus();
            return;
        }
        if (stage == Stage.Preprocessing && PreprocessingBlocked(project))
        {
            queuedStages.Remove(project.Id);
            AppendLog("Run BezierPPM Inference before preprocessing when Use BezierPPM is enabled.", project.Id);
            RefreshPipelineStatus();
            return;
        }
        if (stage == Stage.Preprocessing && !File.Exists(environment.MeshGradingExecutable))
        {
            queuedStages.Remove(project.Id);
            AppendLog("Mesh grading is required. Set up or select hrtf_mesh_grading.exe before preprocessing.", project.Id);
            RefreshPipelineStatus();
            return;
        }
        if (stage == Stage.Preprocessing && !Directory.Exists(Path.Combine(environment.ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf")))
        {
            queuedStages.Remove(project.Id);
            AppendLog("Mesh2HRTF sources are missing. Set up the environment before preprocessing.", project.Id);
            RefreshPipelineStatus();
            return;
        }
        if (stage == Stage.Inference && (!File.Exists(project.Settings.Inference.ModelConfig) || !File.Exists(project.Settings.Inference.ModelCheckpoint)))
        {
            queuedStages.Remove(project.Id);
            AppendLog("The selected inference model files are missing.", project.Id);
            RefreshPipelineStatus();
            return;
        }
        if (stage == Stage.Numcalc && !File.Exists(environment.NumCalcExecutable))
        {
            queuedStages.Remove(project.Id);
            AppendLog("NumCalc is missing. Set up or select NumCalc.exe before running NumCalc.", project.Id);
            RefreshPipelineStatus();
            return;
        }
        try
        {
            Directory.CreateDirectory(project.SaveLocation);
            var config = PrepareConfig(project);
            var executable = Directory.GetFiles(Path.Combine(packageRoot, "Python"), "python.exe", SearchOption.AllDirectories).FirstOrDefault() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
            var arguments = $"-m HRTFCalculation.CLI {stage.Value} --config {QuoteArgument(config)}";
            var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments,
                WorkingDirectory = packageRoot,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            ApplyProcessEnvironment(process.StartInfo);
            process.OutputDataReceived += (_, args) => AppendLog(args.Data, project.Id);
            process.ErrorDataReceived += (_, args) => AppendLog(args.Data, project.Id);
            process.EnableRaisingEvents = true;
            runningProcesses[project.Id] = process;
            runningStages[project.Id] = stage;
            FailedStages(project.Id).Remove(stage);
            AppendLog($"Started {stage.Title} for {project.Name}", project.Id);
            RefreshPipelineStatus();
            process.Exited += (_, _) => Dispatcher.BeginInvoke(() =>
            {
                var code = process.ExitCode;
                if (code != 0)
                    FailedStages(project.Id).Add(stage);
                runningProcesses.Remove(project.Id);
                runningStages.Remove(project.Id);
                AppendLog(code == 0 ? $"{stage.Title} finished for {project.Name}" : $"{stage.Title} for {project.Name} exited with status {code}", project.Id);
                process.Dispose();
                RefreshArtifacts();
                RefreshPipelineStatus();
                if (code == 0 && queuedStages.TryGetValue(project.Id, out var queue) && queue.Count > 0)
                {
                    var next = queue.Dequeue();
                    RunStage(next, project, true);
                }
                else
                {
                    if (code != 0 && queuedStages.TryGetValue(project.Id, out var stoppedQueue) && stoppedQueue.Count > 0)
                        AppendLog($"Run All stopped after {stage.Title} failed.", project.Id);
                    queuedStages.Remove(project.Id);
                    RefreshPipelineStatus();
                }
            });
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception error)
        {
            FailedStages(project.Id).Add(stage);
            runningProcesses.Remove(project.Id);
            runningStages.Remove(project.Id);
            queuedStages.Remove(project.Id);
            AppendLog($"Could not start {stage.Title}: {error.Message}", project.Id);
            RefreshArtifacts();
            RefreshPipelineStatus();
        }
    }

    void ApplyProcessEnvironment(ProcessStartInfo startInfo)
    {
        startInfo.Environment["PINNA2HRTF_ROOT"] = Directory.GetParent(packageRoot)?.FullName ?? packageRoot;
        startInfo.Environment["MPLCONFIGDIR"] = Path.Combine(appData, "Cache", "matplotlib");
        startInfo.Environment["PYTHONPYCACHEPREFIX"] = Path.Combine(appData, "Cache", "python");
        startInfo.Environment["PYTHONNOUSERSITE"] = "1";
        startInfo.Environment["BLENDER_USER_CONFIG"] = Path.Combine(appData, "Blender", "config");
        startInfo.Environment["BLENDER_USER_SCRIPTS"] = Path.Combine(appData, "Blender", "scripts");
        startInfo.Environment["BLENDER_USER_DATAFILES"] = Path.Combine(appData, "Blender", "datafiles");
        if (BundledPythonExecutable() == null)
            startInfo.Environment["UV_CACHE_DIR"] = Path.Combine(appData, "Cache", "uv");
        startInfo.Environment["PYTHONPATH"] = packageRoot + Path.PathSeparator + Path.Combine(packageRoot, ".venv", "Lib", "site-packages");
        startInfo.Environment["PATH"] = Path.Combine(environment.ExternalDir, "bin") + Path.PathSeparator + (startInfo.Environment.TryGetValue("PATH", out var path) ? path : "");
    }

    string? BundledPythonExecutable()
    {
        var candidate = Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        return File.Exists(candidate) ? candidate : null;
    }

    string PrepareConfig(ProjectRecord project)
    {
        var prepared = Clone(project);
        if (prepared.InputHandling == InputHandling.Copy)
        {
            if (!string.IsNullOrWhiteSpace(project.LeftEar))
                prepared.LeftEar = CopyInput(project.LeftEar, Path.Combine(project.SaveLocation, "Input", "Left"));
            if (!string.IsNullOrWhiteSpace(project.RightEar))
                prepared.RightEar = CopyInput(project.RightEar, Path.Combine(project.SaveLocation, "Input", "Right"));
        }
        var config = Path.Combine(project.SaveLocation, "Project Settings.yaml");
        File.WriteAllText(config, Yaml(prepared), Encoding.UTF8);
        return config;
    }

    ProjectRecord Clone(ProjectRecord project) => JsonSerializer.Deserialize<ProjectRecord>(JsonSerializer.Serialize(project, jsonOptions), jsonOptions) ?? project;

    string CopyInput(string path, string folder)
    {
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, Path.GetFileName(path));
        if (Path.GetFullPath(path) == Path.GetFullPath(target))
            return path;
        File.Copy(path, target, true);
        return target;
    }

    string Yaml(ProjectRecord project)
    {
        var output = project.SaveLocation;
        var inference = project.Settings.Inference;
        var preprocessing = project.Settings.Preprocessing;
        var numcalc = project.Settings.NumCalc;
        var postprocessing = project.Settings.Postprocessing ?? new PostprocessingSettings();
        var evaluationGrid = string.IsNullOrWhiteSpace(preprocessing.EvaluationGrid) ? "Default" : preprocessing.EvaluationGrid;
        var frequencyStepCount = Math.Max(int.TryParse(preprocessing.FrequencyStepCount, out var steps) ? steps : 129, 2);
        var sourceAssignmentFaceCount = Math.Clamp(int.TryParse(preprocessing.SourceAssignmentFaceCount, out var faces) ? faces : 6, 1, 100);
        var headRadius = preprocessing.UseCustomHeadRadius == true ? $"  head_radius: {YamlNumber(preprocessing.HeadRadius) ?? "0"}\n" : "";
        var levelOffsetDB = YamlNumber(postprocessing.LevelOffsetDB) ?? "-30";
        return $"""
paths:
  left_ear: {YamlPath(project.LeftEar)}
  right_ear: {YamlPath(project.RightEar)}
  output_dir: {YamlScalar(project.SaveLocation)}
  external_deps_dir: {YamlScalar(environment.ExternalDir)}
  numcalc_executable: {YamlScalar(environment.NumCalcExecutable)}
  mesh_grading_executable: {YamlScalar(environment.MeshGradingExecutable)}
  evaluation_grid: {YamlScalar(evaluationGrid)}
inference:
  enabled: true
  model_config_file: {YamlScalar(inference.ModelConfig)}
  model_checkpoint: {YamlScalar(inference.ModelCheckpoint)}
  target_left_folder: {YamlScalar(inference.TargetLeftFolder)}
  target_right_folder: {YamlScalar(inference.TargetRightFolder)}
  prediction_left_folder: {YamlScalar(inference.PredictionLeftFolder)}
  prediction_right_folder: {YamlScalar(inference.PredictionRightFolder)}
  prediction_parameters_left_folder: Intermediates/Left
  prediction_parameters_right_folder: Intermediates/Right
  use_predictions_for_preprocessing: {Bool(inference.UsePredictionsForPreprocessing)}
preprocessing:
  enabled: true
  write_intermediates: true
  head_radius_scale: 1.01
  head_width_scale: 1.5
  head_height_scale: 1.5
  head_adaptive_ovalness: true
  head_ovalness_strength: 0.08
  head_min_width_scale: 1.48
  head_max_height_scale: 1.53
  head_y_deformation: 0.0
  ear_cut_clearance_scale: 1.3
  ear_cut_mode: ellipse
  projected_cut_margin: 10.0
{headRadius}  seam_smoothing_iterations: 5
  seam_smoothing_factor: 0.35
  mesh_min_edge_length: {preprocessing.MeshMinEdgeLength}
  mesh_max_edge_length: {preprocessing.MeshMaxEdgeLength}
  mesh_max_error: {preprocessing.MeshMaxError}
  mesh_gamma: {preprocessing.MeshGamma}
  mesh_gamma_opposite: {preprocessing.MeshGammaOpposite}
  skip_mesh_grading: false
  source_type_left: Left ear
  source_type_right: Right ear
  title: {YamlScalar(project.Name)}
  method: ML-FMM BEM
  min_frequency: {preprocessing.MinFrequency}
  max_frequency: {preprocessing.MaxFrequency}
  frequency_vector_type: Num steps
  frequency_step_count: {frequencyStepCount}
  compute_hrirs: true
  pictures: false
  reference: true
  unit: mm
  speed_of_sound: "346.18"
  air_density: "1.1839"
  material_search_paths: None
  source_assignment_tolerance: 2.0
  source_assignment_face_count: {sourceAssignmentFaceCount}
numcalc:
  enabled: false
  mode: local
  max_instances: {numcalc.MaxInstances}
  max_cpu_load: {numcalc.MaxCpuLoad}
  adaptive_fmm_length: {Bool(numcalc.AdaptiveFmmLength)}
postprocessing:
  enabled: false
  output_sofa_dir: {YamlScalar(Path.Combine(output, "HRTF"))}
  overwrite: true
  normalize: {Bool(postprocessing.Normalize)}
  level_offset_db: {levelOffsetDB}
ui:
  mesh_background: white
  show_axes: true
""";
    }

    string YamlScalar(string value) => $"'{value.Replace("'", "''")}'";
    string YamlPath(string value) => string.IsNullOrWhiteSpace(value) ? "null" : YamlScalar(value);
    string Bool(bool value) => value ? "true" : "false";
    string? YamlNumber(string? value) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _) ? value : null;
    string QuoteArgument(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    void StopClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedProject != null)
            StopProject(SelectedProject);
    }

    void StopProject(ProjectRecord project)
    {
        queuedStages.Remove(project.Id);
        if (runningProcesses.TryGetValue(project.Id, out var process))
        {
            TryTerminate(process);
            AppendLog("Termination requested.", project.Id);
        }
        RefreshPipelineStatus();
    }

    void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(true);
        }
        catch
        {
        }
    }

    void RefreshClicked(object sender, RoutedEventArgs e) => RefreshArtifacts();

    void ResetOutputsClicked(object sender, RoutedEventArgs e)
    {
        var project = SelectedProject;
        if (project == null || runningProcesses.ContainsKey(project.Id))
            return;
        var names = new[]
        {
            project.Settings.Inference.TargetLeftFolder,
            project.Settings.Inference.TargetRightFolder,
            project.Settings.Inference.PredictionLeftFolder,
            project.Settings.Inference.PredictionRightFolder,
            "Prediction Parameters Left",
            "Prediction Parameters Right",
            "Intermediates",
            "Target STL Left",
            "Target STL Right",
            "ICP STL Left",
            "ICP STL Right",
            "Prediction STL Left",
            "Prediction STL Right",
            "Prediction Parameters Left",
            "Prediction Parameters Right",
            "intermediates",
            "Projects",
            "HRTF",
            "Results Inference.csv",
            ".pinna2hrtf_native_run.yaml",
            "Project Settings.yaml"
        };
        foreach (var name in names)
        {
            var path = Path.Combine(project.SaveLocation, name);
            if (ContainsPath(path, project.LeftEar) || ContainsPath(path, project.RightEar))
            {
                AppendLog($"Skipped reset of {path} because it contains a configured input mesh.", project.Id);
                continue;
            }
            try
            {
                if (Directory.Exists(path))
                    Directory.Delete(path, true);
                else if (File.Exists(path))
                    File.Delete(path);
            }
            catch (Exception error)
            {
                AppendLog($"Could not reset {path}: {error.Message}", project.Id);
            }
        }
        failedStages[project.Id] = [];
        ResetViewer();
        RefreshArtifacts();
        AppendLog($"Reset generated outputs in {project.SaveLocation}", project.Id);
        RefreshPipelineStatus();
    }

    bool ContainsPath(string parent, string child)
    {
        if (string.IsNullOrWhiteSpace(parent) || string.IsNullOrWhiteSpace(child))
            return false;
        var parentPath = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var childPath = Path.GetFullPath(child);
        return childPath.Equals(parentPath, StringComparison.OrdinalIgnoreCase) || childPath.StartsWith(parentPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    void ClearLogClicked(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (SelectedProject != null)
            projectLogs[SelectedProject.Id] = "";
        LogText.Text = "";
    }

    void AppendLog(string? text, Guid? projectId = null)
    {
        if (string.IsNullOrWhiteSpace(text))
            return;
        var targetProjectID = projectId ?? SelectedProject?.Id;
        if (targetProjectID == null)
            return;
        void Append()
        {
            var current = projectLogs.TryGetValue(targetProjectID.Value, out var log) ? log : "";
            var updated = current.Length == 0 ? text : current + Environment.NewLine + text;
            projectLogs[targetProjectID.Value] = updated;
            if (SelectedProject?.Id == targetProjectID)
            {
                LogText.Text = updated;
                LogText.ScrollToEnd();
            }
        }
        if (Dispatcher.CheckAccess())
            Append();
        else
            Dispatcher.BeginInvoke(Append);
    }

    void RefreshNumCalcStatus()
    {
        var project = SelectedProject;
        NumCalcStatusText.Text = project == null ? "No project selected" : NextStageSummary(project);
    }

    void RefreshPipelineStatus()
    {
        var project = SelectedProject;
        if (project == null)
        {
            RefreshStageStatus(null);
            RefreshProjectList();
            return;
        }
        RefreshStageStatus(project);
        RefreshProjectList();
    }
    void RefreshStageStatus(ProjectRecord? project)
    {
        var controls = new[] { InferenceStatusText, PreprocessingStatusText, NumCalcStageStatusText, PostprocessingStatusText };
        var stages = Stage.GetValues();
        for (var index = 0; index < stages.Length; index++)
        {
            if (project == null)
            {
                controls[index].Text = "—";
                controls[index].Foreground = System.Windows.Media.Brushes.Gray;
                continue;
            }
            var stage = stages[index];
            var skipped = stage == Stage.Inference && !InferenceIsAutomatic(project);
            var running = runningStages.TryGetValue(project.Id, out var active) && active == stage;
            var failed = FailedStages(project.Id).Contains(stage);
            controls[index].Text = skipped ? "Skipped" : running ? "Running…" : failed ? "Failed" : StageIsComplete(stage, project) ? "Done" : "Ready";
            controls[index].Foreground = skipped ? System.Windows.Media.Brushes.Gray : running ? System.Windows.Media.Brushes.DarkOrange : failed ? System.Windows.Media.Brushes.Firebrick : StageIsComplete(stage, project) ? System.Windows.Media.Brushes.ForestGreen : System.Windows.Media.Brushes.Gray;
        }
        UpdateRunButtons(project);
    }

    void UpdateRunButtons(ProjectRecord? project)
    {
        var buttons = new[] { RunInferenceButton, RunPreprocessingButton, RunNumCalcButton, RunPostprocessingButton };
        var stages = Stage.GetValues();
        var active = project != null && runningStages.TryGetValue(project.Id, out var stage) ? stage : (Stage?)null;
        for (var i = 0; i < buttons.Length; i++)
        {
            buttons[i].Content = active == stages[i] ? "Stop" : "Run";
            buttons[i].IsEnabled = active == stages[i] || (active == null && StageCanRun(stages[i], project));
        }
        var pending = project == null ? new List<Stage>() : AutomaticStages(project).Where(stage => !StageIsComplete(stage, project)).ToList();
        RunAllButton.IsEnabled = active == null && project != null && pending.Count > 0 && StageCanRun(pending[0], project);
    }

    bool InferenceIsAutomatic(ProjectRecord project) => project.Settings.Inference.UsePredictionsForPreprocessing && !string.IsNullOrWhiteSpace(project.LeftEar) && !string.IsNullOrWhiteSpace(project.RightEar);
    bool PreprocessingBlocked(ProjectRecord project) => InferenceIsAutomatic(project) && !StageIsComplete(Stage.Inference, project);
    bool StageCanRun(Stage stage, ProjectRecord? project)
    {
        if (project == null || runningProcesses.ContainsKey(project.Id) || string.IsNullOrWhiteSpace(project.SaveLocation) || (string.IsNullOrWhiteSpace(project.LeftEar) && string.IsNullOrWhiteSpace(project.RightEar)))
            return false;
        if ((!string.IsNullOrWhiteSpace(project.LeftEar) && !File.Exists(project.LeftEar)) || (!string.IsNullOrWhiteSpace(project.RightEar) && !File.Exists(project.RightEar)))
            return false;
        if (stage == Stage.Inference)
            return InferenceIsAutomatic(project) && File.Exists(project.Settings.Inference.ModelConfig) && File.Exists(project.Settings.Inference.ModelCheckpoint);
        if (stage == Stage.Preprocessing)
            return !PreprocessingBlocked(project) && File.Exists(environment.MeshGradingExecutable) && Directory.Exists(Path.Combine(environment.ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf"));
        if (stage == Stage.Numcalc)
            return StageIsComplete(Stage.Preprocessing, project) && File.Exists(environment.NumCalcExecutable);
        if (stage == Stage.Postprocessing)
            return StageIsComplete(Stage.Numcalc, project);
        return false;
    }
    Stage[] AutomaticStages(ProjectRecord project) => InferenceIsAutomatic(project) ? Stage.GetValues() : [Stage.Preprocessing, Stage.Numcalc, Stage.Postprocessing];

    string NumCalcStatus(ProjectRecord project)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(project.LeftEar))
            parts.Add($"Left {NumCalcCompleted(project, "Left")}/{NumCalcTotal(project, "Left")}");
        if (!string.IsNullOrWhiteSpace(project.RightEar))
            parts.Add($"Right {NumCalcCompleted(project, "Right")}/{NumCalcTotal(project, "Right")}");
        return parts.Count == 0 ? "NumCalc: no ear selected" : "NumCalc: " + string.Join(" · ", parts);
    }

    int NumCalcCompleted(ProjectRecord project, string side)
    {
        var folder = Path.Combine(project.SaveLocation, "Projects", side, "NumCalc", "source_1", "be.out");
        if (!Directory.Exists(folder))
            return ContainsOutput2HRTF(Path.Combine(project.SaveLocation, "Projects", side, "Output2HRTF")) ? NumCalcTotal(project, side) : 0;
        var completed = Directory.GetDirectories(folder, "be.*").Count(path => int.TryParse(Path.GetFileName(path)[3..], out _));
        return completed > 0 ? completed : ContainsOutput2HRTF(Path.Combine(project.SaveLocation, "Projects", side, "Output2HRTF")) ? NumCalcTotal(project, side) : 0;
    }

    int NumCalcTotal(ProjectRecord project, string side)
    {
        var parameters = Path.Combine(project.SaveLocation, "Projects", side, "parameters.json");
        if (!File.Exists(parameters))
            return 0;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(parameters));
            return document.RootElement.TryGetProperty("numFrequencies", out var value) && value.TryGetInt32(out var total) ? total : 0;
        }
        catch
        {
            return 0;
        }
    }

    string ArtifactSummary(ProjectRecord project)
    {
        if (StageIsComplete(Stage.Postprocessing, project))
            return "Postprocessed";
        if (StageIsComplete(Stage.Numcalc, project))
            return "Solved";
        if (StageIsComplete(Stage.Preprocessing, project))
            return "Projects ready";
        if (!project.Settings.Inference.UsePredictionsForPreprocessing)
            return "BezierPPM Inference skipped";
        if (StageIsComplete(Stage.Inference, project))
            return "BezierPPM Inference ready";
        return NextStageSummary(project);
    }

    string NextStageSummary(ProjectRecord project)
    {
        var running = runningStages.TryGetValue(project.Id, out var active) ? active : null;
        if (running != null)
            return $"{running.Title}: Running";
        var next = AutomaticStages(project).FirstOrDefault(stage => !StageIsComplete(stage, project));
        return next == null ? "Complete" : $"{next.Title}: Ready";
    }

    bool StageIsComplete(Stage stage, ProjectRecord project)
    {
        var output = project.SaveLocation;
        if (stage == Stage.Inference)
            return !project.Settings.Inference.UsePredictionsForPreprocessing || (InferenceIsAutomatic(project) && ContainsMesh(Path.Combine(output, project.Settings.Inference.PredictionLeftFolder)) && ContainsMesh(Path.Combine(output, project.Settings.Inference.PredictionRightFolder)));
        if (stage == Stage.Preprocessing)
            return (string.IsNullOrWhiteSpace(project.LeftEar) || (File.Exists(Path.Combine(output, "Projects", "Left", "parameters.json")) && File.Exists(Path.Combine(output, "Intermediates", "Left", "graded_head.ply")))) && (string.IsNullOrWhiteSpace(project.RightEar) || (File.Exists(Path.Combine(output, "Projects", "Right", "parameters.json")) && File.Exists(Path.Combine(output, "Intermediates", "Right", "graded_head.ply"))));
        if (stage == Stage.Numcalc)
        {
            var leftTotal = NumCalcTotal(project, "Left");
            var rightTotal = NumCalcTotal(project, "Right");
            var leftDone = string.IsNullOrWhiteSpace(project.LeftEar) || (leftTotal > 0 && NumCalcCompleted(project, "Left") >= leftTotal) || ContainsOutput2HRTF(Path.Combine(output, "Projects", "Left", "Output2HRTF"));
            var rightDone = string.IsNullOrWhiteSpace(project.RightEar) || (rightTotal > 0 && NumCalcCompleted(project, "Right") >= rightTotal) || ContainsOutput2HRTF(Path.Combine(output, "Projects", "Right", "Output2HRTF"));
            return leftDone && rightDone;
        }
        if (stage == Stage.Postprocessing)
            return Directory.Exists(Path.Combine(output, "HRTF")) && Directory.GetFiles(Path.Combine(output, "HRTF"), "*.sofa").Any();
        return false;
    }

    bool ContainsMesh(string folder) => Directory.Exists(folder) && Directory.GetFiles(folder).Any(IsMesh);
    bool ContainsOutput2HRTF(string folder) => Directory.Exists(folder) && Directory.GetFiles(folder, "*.sofa").Any();
    bool IsMesh(string path) => string.Equals(Path.GetExtension(path), ".stl", StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetExtension(path), ".ply", StringComparison.OrdinalIgnoreCase);

    HashSet<Stage> FailedStages(Guid id)
    {
        if (!failedStages.TryGetValue(id, out var set))
        {
            set = [];
            failedStages[id] = set;
        }
        return set;
    }
}

record Artifact(string Title, string Path)
{
    public bool Exists => File.Exists(Path);
    public bool IsMesh => string.Equals(System.IO.Path.GetExtension(Path), ".stl", StringComparison.OrdinalIgnoreCase) || string.Equals(System.IO.Path.GetExtension(Path), ".ply", StringComparison.OrdinalIgnoreCase);
    public bool IsImage => new[] { ".jpg", ".jpeg", ".png", ".bmp", ".gif" }.Contains(System.IO.Path.GetExtension(Path).ToLowerInvariant());
    public bool IsText => new[] { ".txt", ".csv", ".json", ".yaml", ".yml", ".log", ".out" }.Contains(System.IO.Path.GetExtension(Path).ToLowerInvariant());
}

record Stage(string Value, string Title)
{
    public static readonly Stage Inference = new("inference", "BezierPPM Inference");
    public static readonly Stage Preprocessing = new("preprocessing", "Preprocessing");
    public static readonly Stage Numcalc = new("numcalc", "NumCalc");
    public static readonly Stage Postprocessing = new("postprocessing", "Postprocess");
    public static Stage[] GetValues() => [Inference, Preprocessing, Numcalc, Postprocessing];
}

enum InputHandling { Copy, Reference }

class ProjectRegistry
{
    public List<ProjectRecord> Projects { get; set; } = [];
    public Guid? SelectedProjectID { get; set; }
    public EnvironmentConfig Environment { get; set; } = new();
}

class ProjectViewerState
{
    public string? SelectedArtifactPath { get; set; }
    public Dictionary<string, MeshCameraState> CameraByArtifact { get; set; } = [];
}

class MeshCameraState
{
    public double Yaw { get; set; }
    public double Pitch { get; set; }
    public double Distance { get; set; }
}

class SettingHelpEntry
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";
    public List<SettingHelpPublication> Publications { get; set; } = [];
}

class SettingHelpPublication
{
    public string Title { get; set; } = "";
    public string Url { get; set; } = "";
}

class EnvironmentConfig
{
    public string UvExecutable { get; set; } = "";
    public string NumCalcExecutable { get; set; } = "";
    public string MeshGradingExecutable { get; set; } = "";
    public string ExternalDir { get; set; } = "";
    [JsonIgnore] public bool IsEmpty => string.IsNullOrWhiteSpace(UvExecutable) && string.IsNullOrWhiteSpace(NumCalcExecutable) && string.IsNullOrWhiteSpace(MeshGradingExecutable) && string.IsNullOrWhiteSpace(ExternalDir);
}

class ProjectRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string LeftEar { get; set; } = "";
    public string RightEar { get; set; } = "";
    public string SaveLocation { get; set; } = "";
    public InputHandling InputHandling { get; set; } = InputHandling.Copy;
    public ProjectSettings Settings { get; set; } = new();
    [JsonIgnore] public string DisplayTitle { get; set; } = "";
    [JsonIgnore] public string StatusText { get; set; } = "";
    [JsonIgnore] public bool IsRunning { get; set; }
}

class ProjectSettings
{
    public InferenceSettings Inference { get; set; } = new();
    public PreprocessingSettings Preprocessing { get; set; } = new();
    public NumCalcSettings NumCalc { get; set; } = new();
    public PostprocessingSettings? Postprocessing { get; set; } = new();
}

class InferenceSettings
{
    public string ModelConfig { get; set; } = "";
    public string ModelCheckpoint { get; set; } = "";
    public string TargetLeftFolder { get; set; } = "Input/Left";
    public string TargetRightFolder { get; set; } = "Input/Right";
    public string PredictionLeftFolder { get; set; } = "Intermediates/Left";
    public string PredictionRightFolder { get; set; } = "Intermediates/Right";
    public bool UsePredictionsForPreprocessing { get; set; } = true;
}

class PreprocessingSettings
{
    public string MinFrequency { get; set; } = "0";
    public string MaxFrequency { get; set; } = "24000";
    public string FrequencyStepCount { get; set; } = "129";
    public string? EvaluationGrid { get; set; }
    public string? HeadRadius { get; set; }
    public bool? UseCustomHeadRadius { get; set; }
    public string SourceAssignmentFaceCount { get; set; } = "6";
    public string MeshMinEdgeLength { get; set; } = "0.5";
    public string MeshMaxEdgeLength { get; set; } = "10.0";
    public string MeshMaxError { get; set; } = "0.5";
    public string MeshGamma { get; set; } = "0.2";
    public string MeshGammaOpposite { get; set; } = "0.1";
}

class PostprocessingSettings
{
    public bool Normalize { get; set; } = true;
    public string LevelOffsetDB { get; set; } = "-30";
}

class NumCalcSettings
{
    public string MaxInstances { get; set; } = "1";
    public string MaxCpuLoad { get; set; } = "90";
    public bool AdaptiveFmmLength { get; set; } = true;
}

static class MeshLoader
{
    public static Model3D Load(string path, out Point3D center, out double scale)
    {
        var mesh = string.Equals(Path.GetExtension(path), ".ply", StringComparison.OrdinalIgnoreCase) ? LoadPly(path) : LoadStl(path);
        Center(mesh, out center, out scale);
        var material = new MaterialGroup();
        material.Children.Add(new DiffuseMaterial(new SolidColorBrush(System.Windows.Media.Color.FromRgb(96, 145, 144))));
        material.Children.Add(new SpecularMaterial(new SolidColorBrush(System.Windows.Media.Color.FromRgb(205, 225, 224)), 28));
        material.Children.Add(new EmissiveMaterial(new SolidColorBrush(System.Windows.Media.Color.FromRgb(16, 28, 28))));
        return new GeometryModel3D(mesh, material) { BackMaterial = material };
    }

    public static Model3D Load(string path) => Load(path, out _, out _);

    public static MeshGeometry3D CreateSphere(Point3D center, double radius)
    {
        var mesh = new MeshGeometry3D();
        const int slices = 16;
        const int stacks = 8;
        for (var stack = 0; stack <= stacks; stack++)
        {
            var phi = Math.PI * stack / stacks;
            var z = Math.Cos(phi);
            var ringRadius = Math.Sin(phi);
            for (var slice = 0; slice <= slices; slice++)
            {
                var theta = 2 * Math.PI * slice / slices;
                mesh.Positions.Add(new Point3D(center.X + radius * ringRadius * Math.Cos(theta), center.Y + radius * ringRadius * Math.Sin(theta), center.Z + radius * z));
            }
        }
        for (var stack = 0; stack < stacks; stack++)
            for (var slice = 0; slice < slices; slice++)
            {
                var first = stack * (slices + 1) + slice;
                var second = first + slices + 1;
                mesh.TriangleIndices.Add(first);
                mesh.TriangleIndices.Add(second);
                mesh.TriangleIndices.Add(first + 1);
                mesh.TriangleIndices.Add(first + 1);
                mesh.TriangleIndices.Add(second);
                mesh.TriangleIndices.Add(second + 1);
            }
        return mesh;
    }

    static MeshGeometry3D LoadStl(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (LooksBinaryStl(bytes))
            return LoadBinaryStl(bytes);
        return LoadAsciiStl(File.ReadLines(path));
    }

    static bool LooksBinaryStl(byte[] bytes)
    {
        if (bytes.Length < 84)
            return false;
        var triangles = BitConverter.ToUInt32(bytes, 80);
        return 84L + triangles * 50L == bytes.Length;
    }

    static MeshGeometry3D LoadBinaryStl(byte[] bytes)
    {
        var mesh = new MeshGeometry3D();
        var count = checked((int)BitConverter.ToUInt32(bytes, 80));
        var offset = 84;
        for (var i = 0; i < count; i++)
        {
            offset += 12;
            var start = mesh.Positions.Count;
            for (var v = 0; v < 3; v++)
            {
                var x = BitConverter.ToSingle(bytes, offset);
                var y = BitConverter.ToSingle(bytes, offset + 4);
                var z = BitConverter.ToSingle(bytes, offset + 8);
                offset += 12;
                mesh.Positions.Add(new Point3D(x, y, z));
            }
            mesh.TriangleIndices.Add(start);
            mesh.TriangleIndices.Add(start + 1);
            mesh.TriangleIndices.Add(start + 2);
            offset += 2;
        }
        return mesh;
    }

    static MeshGeometry3D LoadAsciiStl(IEnumerable<string> lines)
    {
        var mesh = new MeshGeometry3D();
        var vertices = new List<Point3D>();
        foreach (var line in lines)
        {
            var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 4 && parts[0].Equals("vertex", StringComparison.OrdinalIgnoreCase))
            {
                vertices.Add(new Point3D(Parse(parts[1]), Parse(parts[2]), Parse(parts[3])));
                if (vertices.Count == 3)
                {
                    var start = mesh.Positions.Count;
                    foreach (var vertex in vertices)
                        mesh.Positions.Add(vertex);
                    mesh.TriangleIndices.Add(start);
                    mesh.TriangleIndices.Add(start + 1);
                    mesh.TriangleIndices.Add(start + 2);
                    vertices.Clear();
                }
            }
        }
        return mesh;
    }

    static MeshGeometry3D LoadPly(string path)
    {
        using var reader = new StreamReader(path);
        var vertexCount = 0;
        var faceCount = 0;
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 3 && parts[0] == "element" && parts[1] == "vertex")
                vertexCount = int.Parse(parts[2], CultureInfo.InvariantCulture);
            if (parts.Length == 3 && parts[0] == "element" && parts[1] == "face")
                faceCount = int.Parse(parts[2], CultureInfo.InvariantCulture);
            if (line == "end_header")
                break;
        }
        var vertices = new List<Point3D>();
        for (var i = 0; i < vertexCount; i++)
        {
            line = reader.ReadLine() ?? "";
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            vertices.Add(new Point3D(Parse(parts[0]), Parse(parts[1]), Parse(parts[2])));
        }
        var mesh = new MeshGeometry3D();
        foreach (var vertex in vertices)
            mesh.Positions.Add(vertex);
        for (var i = 0; i < faceCount; i++)
        {
            line = reader.ReadLine() ?? "";
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => int.Parse(x, CultureInfo.InvariantCulture)).ToArray();
            if (parts.Length < 4)
                continue;
            for (var j = 2; j < parts[0]; j++)
            {
                mesh.TriangleIndices.Add(parts[1]);
                mesh.TriangleIndices.Add(parts[j]);
                mesh.TriangleIndices.Add(parts[j + 1]);
            }
        }
        return mesh;
    }

    static void Center(MeshGeometry3D mesh, out Point3D center, out double scale)
    {
        if (mesh.Positions.Count == 0)
        {
            center = new Point3D();
            scale = 1;
            return;
        }
        var minX = mesh.Positions.Min(p => p.X);
        var maxX = mesh.Positions.Max(p => p.X);
        var minY = mesh.Positions.Min(p => p.Y);
        var maxY = mesh.Positions.Max(p => p.Y);
        var minZ = mesh.Positions.Min(p => p.Z);
        var maxZ = mesh.Positions.Max(p => p.Z);
        center = new Point3D((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
        scale = 180 / Math.Max(Math.Max(maxX - minX, maxY - minY), Math.Max(maxZ - minZ, 1));
        for (var i = 0; i < mesh.Positions.Count; i++)
        {
            var p = mesh.Positions[i] - center;
            mesh.Positions[i] = new Point3D(p.X * scale, p.Y * scale, p.Z * scale);
        }
    }

    static double Parse(string value) => double.Parse(value, CultureInfo.InvariantCulture);
}
