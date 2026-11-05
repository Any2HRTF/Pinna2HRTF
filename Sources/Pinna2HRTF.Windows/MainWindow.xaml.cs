using HelixToolkit.Maths;
using HelixToolkit;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Text;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Windows.Foundation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using WinRT.Interop;

namespace Pinna2HRTF.Windows;

public partial class MainWindow : Window
{
    WindowChrome? windowChrome;
    SharedNavigation? meshNavigation;
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeLibrary(IntPtr hModule);
    const uint LoadLibrarySearchDllLoadDir = 0x00000100;
    const uint LoadLibrarySearchDefaultDirs = 0x00001000;
    const double MicrophoneMarkerRadiusMeshUnits = 0.5;
    readonly ObservableCollection<ProjectRecord> projects = [];
    readonly ObservableCollection<Artifact> artifacts = [];
    sealed record PipelineRun(Process Process, Stage Stage, PipelineLogCapture? Capture)
    {
        public GeneratedOutputManifest? Outputs { get; set; }
        public OwnedProcess? Owned { get; init; }
        public IDisposable? Reservation { get; init; }
        public bool StopRequested { get; set; }
    }
    readonly Dictionary<Guid, PipelineRun> runs = [];
    readonly Dictionary<Guid, Queue<Stage>> queuedStages = [];
    readonly Dictionary<Guid, HashSet<Stage>> failedStages = [];
    readonly Dictionary<string, GeneratedOutputManifest> outputStores = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<Guid, HashSet<GeneratedOutputManifest.OutputStage>> knownOutputs = [];
    readonly ActivityCounter outputOperations = new();
    readonly ProjectOperations projectOperations = new();
    bool ProjectBusy(Guid id) => runs.ContainsKey(id) || outputOperations.Contains(id) || projectOperations.Contains(id) || OwnedProcess.HasProjectActivity(id) || scanAlignmentMode && alignmentSessionProject == id;
    readonly ActivityCounter outputScans = new();
    readonly Dictionary<Guid, DateTime> lastOutputScan = [];
    readonly Dictionary<Guid, string> projectLogs = [];
    readonly Dictionary<Guid, string> legacyProjectLogs = [];
    readonly Dictionary<Guid, string> technicalLogPaths = [];
    readonly Dictionary<Guid, Dictionary<string, int>> projectLogKeyIndices = [];
    readonly HashSet<Guid> projectsBeingRemoved = [];
    readonly Dictionary<Guid, ProjectRowUi> projectRows = [];
    readonly Dictionary<Guid, ProjectViewerState> viewerStates = [];
    readonly Dictionary<string, SettingHelpEntry> settingHelp = [];
    readonly JsonSerializerOptions jsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true, Converters = { new JsonStringEnumConverter() } };
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer statusTimer;
    readonly Dictionary<string, Control> settingControls = [];
    readonly Dictionary<string, TextSetting> textSettings;
    readonly List<Button> stageButtons = [];
    readonly List<Expander> settingSections = [];
    readonly List<Element3D> sceneLights = [];
    readonly List<MeshGeometryModel3D> meshVisuals = [];
    ProjectRegistry registry = new();
    EnvironmentConfig environment = new();
    ProjectRecord? selectedProject;
    MeshGeometryModel3D? meshVisual;
    MeshGeometryModel3D? microphoneVisual;
    MeshData? currentMesh;
    string? selectedArtifactPath;
    string? selectedArtifactSide;
    string packageRoot = "";
    string appData = "";
    string registryPath = "";
    string viewerStatePath = "";
    string uiStatePath = "";
    string logsPath = "";
    double projectsExpandedWidth = 280;
    double liveLogExpandedHeight = 170;
    double settingsExpandedWidth = 390;
    readonly SolidColorBrush appBackgroundBrush = new();
    readonly SolidColorBrush surfaceBrush = new();
    readonly SolidColorBrush secondarySurfaceBrush = new();
    readonly SolidColorBrush inputBackgroundBrush = new();
    readonly SolidColorBrush borderBrush = new();
    readonly SolidColorBrush primaryTextBrush = new();
    readonly SolidColorBrush mutedTextBrush = new();
    readonly SolidColorBrush viewerBackgroundBrush = new();
    readonly SolidColorBrush viewerHintBackgroundBrush = new();
    readonly SolidColorBrush viewerHintTextBrush = new();
    bool loading;
    bool registryNeedsPersist;
    bool refreshingArtifacts;
    bool rotatingMesh;
    bool pointerMoved;
    Point lastPointer;
    uint activeMeshPointerId = uint.MaxValue;
    string? placementSide;
    Guid? placementProjectId;
    string? placementMeshPath;
    string? placementMeshIdentity;
    CancellationTokenSource? placementCancellation;
    bool calculatingAutomaticPosition;
    ManualMicrophonePosition? pendingMicrophonePosition;
    bool closingConfirmed;
    bool shutdownCleanupDone;
    bool scanAlignmentMode;
    readonly List<System.Numerics.Vector3> scanAlignmentLandmarks = [];
    readonly List<MeshGeometryModel3D> scanAlignmentMarkerVisuals = [];
    Grid? contentGrid;
    ColumnDefinition? projectsColumn;
    ColumnDefinition? settingsColumn;
    ListView projectList = new();
    ComboBox artifactPicker = new();
    TextBlock selectedArtifactText = new();
    Image imagePreview = new();
    TextBlock viewerPlaceholder = new();
    Border viewerInteractionHint = new();
    Border resetViewButtonHost = new();
    Viewport3DX meshViewport = new();
    Border meshViewerBackground = new();
    CursorGrid? meshViewportHost;
    Border? projectsPaneBorder;
    Border? previewPanelBorder;
    Border? logPanelBorder;
    Button? technicalLogButton;
    Border? settingsPaneBorder;
    TextBlock? projectsHeaderText;
    FrameworkElement? projectsBody;
    StackPanel? projectsActions;
    Grid? projectsHeader;
    Button? projectsToggle;
    ColumnDefinition? projectsSplitterColumn;
    FrameworkElement? projectsSplitter;
    Button? logToggle;
    StackPanel? logHeaderActions;
    Border? logContentHost;
    RowDefinition? centerLogRow;
    RowDefinition? logSplitterRow;
    FrameworkElement? logSplitter;
    bool projectsCollapsed;
    bool logCollapsed;

    ScrollViewer? logScrollViewer;
    bool logFollowTail = true;
    bool logProgrammaticScroll;
    bool logTailScrollPending;
    bool logTailUserInteraction;
    const double LogHeaderHeight = 48;
    // Header content + native header border + enclosing border + top margin.
    const double CollapsedLogHeaderHeight = LogHeaderHeight + 2 + 2 + 3;
    bool viewportReady;
    CancellationTokenSource? meshLoadCancellation;
    int meshLoadGeneration;
    enum MeshPointerMode { None, Rotate, Pan }
    MeshPointerMode meshPointerMode;
    TextBox logText = new();
    TextBlock numCalcStatusText = new();
    TextBlock pipelineHintText = new();
    TextBlock placementCoordinates = new();
    StackPanel placementPanel = new();
    Border placementBorder = new();
    Border scanAlignmentBorder = new();
    TextBlock scanAlignmentStatus = new();
    Button placeLeftButton = new();
    Button placeRightButton = new();
    Border placeLeftButtonHost = new();
    Border placeRightButtonHost = new();
    Button automaticPositionButton = new();
    Button donePositionButton = new();
    Button cancelPositionButton = new();
    Button runAllButton = new();
    readonly TextBox projectNameBox = new();
    readonly TextBox leftEarBox = new();
    readonly TextBox rightEarBox = new();
    readonly TextBox scanPathBox = new();
    readonly TextBox saveLocationBox = new();
    readonly TextBox evaluationGridBox = new();
    readonly TextBox minFrequencyBox = new();
    readonly TextBox maxFrequencyBox = new();
    readonly TextBox frequencyStepsBox = new();
    readonly TextBox samplingRateBox = new();
    readonly TextBox microphoneFacesBox = new();
    readonly TextBox meshMinEdgeBox = new();
    readonly TextBox meshMaxEdgeBox = new();
    readonly TextBox meshMaxErrorBox = new();
    readonly TextBox meshGammaBox = new();
    readonly TextBox meshGammaOppositeBox = new();
    readonly TextBox maxInstancesBox = new();
    readonly TextBox maxCpuLoadBox = new();
    readonly TextBox levelOffsetBox = new();
    readonly CheckBox usePredictionsBox = new();
    readonly CheckBox scanPreparationEnabledBox = new();
    readonly CheckBox prepareLeftEarBox = new() { IsChecked = true };
    readonly CheckBox prepareRightEarBox = new() { IsChecked = true };
    readonly Button alignScanButton = new() { Content = "Align scan…" };
    readonly Button applyScanAlignmentButton = new() { Content = "Apply Alignment", IsEnabled = false };
    readonly CheckBox adaptiveFmmLengthBox = new();
    readonly CheckBox normalizeHrtfsBox = new();
    readonly CheckBox resampleHrirsBox = new();
    readonly ComboBox modelPicker = new();
    readonly TextBlock[] stageStatus = [new(), new(), new(), new(), new()];

    public MainWindow()
    {
        FileFingerprints.UiThread = Environment.CurrentManagedThreadId;
        FileFingerprints.Ready = () => DispatcherQueue.TryEnqueue(() => { if (!shutdownCleanupDone) RefreshPipelineStatus(); });
        InitializeComponent();
        textSettings = CreateTextSettings();
        AddV2TextSettings(textSettings);
        var cancelInteraction=new KeyboardAccelerator{Key=VirtualKey.Escape};
        cancelInteraction.Invoked+=(_,args)=>{if(placementSide!=null){EndPlacement();args.Handled=true;}else if(scanAlignmentMode){EndScanAlignment();args.Handled=true;}};
        Root.KeyboardAccelerators.Add(cancelInteraction);
        Root.Loaded += WindowLoaded;
        Root.ActualThemeChanged += (_, _) => UpdateViewerAppearance();
        statusTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        statusTimer.Interval = TimeSpan.FromSeconds(2);
        statusTimer.Tick += (_, _) => RefreshPipelineStatus();
        ExtendsContentIntoTitleBar = true;
        Activated += (_, _) => UpdateViewerAppearance();
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(id);
        appWindow.Title = "Pinna2HRTF " + ReviewVersion;
        try
        {
            var icon = Path.Combine(AppContext.BaseDirectory, "app_icon.ico");
            if (!File.Exists(icon)) icon = Path.Combine(AppContext.BaseDirectory, "Resources", "app_icon.ico");
            if (File.Exists(icon)) appWindow.SetIcon(icon);
        }
        catch { }
        appWindow.Closing += AppWindowClosing;

    }

    static string SafeProcessName(Process process)
    {
        try { return process.ProcessName; } catch { return "pipeline process"; }
    }

    void WindowLoaded(object sender, RoutedEventArgs e)
    {
        if (MacLayout) { projectsExpandedWidth = 240; settingsExpandedWidth = 360; logCollapsed = true; }
        BuildInterface();
        packageRoot = FindPackageRoot();
        appData = Environment.GetEnvironmentVariable("PINNA2HRTF_APP_DATA") is string overrideData && Path.IsPathFullyQualified(overrideData) ? overrideData : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), MacReviewStorage ? "Pinna2HRTF-v2-review-macimitation" : "Pinna2HRTF-v2-review");
#if PINNA2HRTF_REVIEW
        appData = Path.Combine(AppContext.BaseDirectory, ".appdata");
#endif
        registryPath = Path.Combine(appData, "projects.json");
        viewerStatePath = Path.Combine(appData, "viewer-state.json");
        uiStatePath = Path.Combine(appData, "ui-state.json");
        logsPath = Path.Combine(appData, "logs.json");
        EnsureStateDirectory(appData);
        WriteRuntimeInfo();
        EnsureStateDirectory(Path.Combine(appData, "Cache", "matplotlib"));
        EnsureStateDirectory(Path.Combine(appData, "Cache", "python"));
        EnsureStateDirectory(Path.Combine(appData, "Blender", "config"));
        EnsureStateDirectory(Path.Combine(appData, "Blender", "scripts"));
        EnsureStateDirectory(Path.Combine(appData, "Blender", "datafiles"));
        LoadSettingHelp();
        LoadRegistry();
        LoadProjectLogs();
        LoadViewerStates();
        LoadUiState();
        SetProjectsCollapsed(projectsCollapsed, false);
        SetLogCollapsed(logCollapsed, false);
        if (settingsColumn != null) settingsColumn.Width = new GridLength(Math.Clamp(settingsExpandedWidth, 320, 560));
        environment = DefaultEnvironment();
        foreach (var project in projects)
        {
            if (int.TryParse(project.Settings.Preprocessing.FrequencyStepCount, out var steps))
                project.Settings.Preprocessing.FrequencyStepCount = Math.Max(steps, 2).ToString(CultureInfo.InvariantCulture);
            InvalidateManualPositions(project);
        }
        if (registryNeedsPersist)
        {
            Persist();
            registryNeedsPersist = false;
        }
        RefreshModelOptions();
        RefreshProjectList();
        if (selectedProject != null && projectRows.TryGetValue(selectedProject.Id, out var selectedRow))
            projectList.SelectedItem = selectedRow.Root;
        LoadSelectedProject();
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => RefreshArtifacts());
        UpdateViewerAppearance();
        statusTimer.Start();
        RefreshPipelineStatus();
    }

    void BuildInterface()
    {
        Root.Children.Clear();
        Root.RowDefinitions.Clear();
        Root.ColumnDefinitions.Clear();
        Root.UseLayoutRounding = true;
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(54) });
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var titleBar = BuildTitleBar();
        Grid.SetRow(titleBar, 0);
        Root.Children.Add(titleBar);

        contentGrid = new Grid { Background = appBackgroundBrush };
        projectsColumn = new ColumnDefinition
        {
            Width = new GridLength(projectsExpandedWidth), MinWidth = 200, MaxWidth = 550
        };
        contentGrid.ColumnDefinitions.Add(projectsColumn);
        projectsSplitterColumn = new ColumnDefinition { Width = new GridLength(12) };
        contentGrid.ColumnDefinitions.Add(projectsSplitterColumn);
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 420 });
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12), MinWidth = 12, MaxWidth = 12 });
        settingsColumn = new ColumnDefinition { Width = new GridLength(settingsExpandedWidth), MinWidth = 300, MaxWidth = 600 };
        contentGrid.ColumnDefinitions.Add(settingsColumn);
        contentGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(contentGrid, 1);
        Root.Children.Add(contentGrid);
        var projectsPane = BuildProjectsPane();
        Grid.SetColumn(projectsPane, 0);
        contentGrid.Children.Add(projectsPane);
        projectsSplitter = BuildSplitter(true, ProjectSplitterDragged);
        Grid.SetColumn(projectsSplitter, 1);
        contentGrid.Children.Add(projectsSplitter);
        var center = BuildCenterPane();
        Grid.SetColumn(center, 2);
        contentGrid.Children.Add(center);
        var settingsSplitter = BuildSplitter(true, SettingsSplitterDragged);
        macSettingsDivider = settingsSplitter;
        Grid.SetColumn(settingsSplitter, 3);
        contentGrid.Children.Add(settingsSplitter);
        var settings = BuildSettingsPane();
        Grid.SetColumn(settings, 4);
        contentGrid.Children.Add(settings);
        SetProjectsCollapsed(projectsCollapsed, false);
        if (MacLayout) ApplyMacWorkspace();
    }

    Grid BuildSplitter(bool vertical, DragDeltaEventHandler handler)
    {
        var host = new CursorGrid(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth)
        {
            Background = new SolidColorBrush(Colors.Transparent),
            IsHitTestVisible = true
        };

        if (vertical)
        {
            host.VerticalAlignment = VerticalAlignment.Stretch;
        }
        else
        {
            host.HorizontalAlignment = HorizontalAlignment.Stretch;
        }

        var line = new Border
        {
            Width = vertical ? 1 : double.NaN,
            Height = vertical ? double.NaN : 1,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Background = borderBrush,
            IsHitTestVisible = false
        };

        var thumb = new Thumb
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent),
            IsHitTestVisible = true
        };

        thumb.DragDelta += handler;
        host.Children.Add(line);
        host.Children.Add(thumb);

        return host;
    }

    Grid BuildTitleBar()
    {
        var titleBar = new Grid { Height = 54, Background = new SolidColorBrush(Colors.Transparent), HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
        titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var logo = new Image { Width = 20, Height = 20, Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        var titleIcon = Path.Combine(AppContext.BaseDirectory, "app_icon.png");
        if (File.Exists(titleIcon)) logo.Source = new BitmapImage(new Uri(titleIcon));
        titleBar.Children.Add(logo);
        var menu = BuildMenu();
        menu.Height = 36;
        menu.VerticalAlignment = VerticalAlignment.Stretch;
        menu.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(menu, 1);
        titleBar.Children.Add(menu);
        if (!MacLayout) {
            titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            workflowCompact.Click += (_, _) => PerformWorkflowAction();
            workflowCompact.Margin = new Thickness(4, 8, 8, 8);
            Grid.SetColumn(workflowCompact, 2); titleBar.Children.Add(workflowCompact);
        }
        windowChrome?.Dispose(); windowChrome = new WindowChrome(this, Root, titleBar, titleBar);
        return titleBar;
    }

    void ProjectSplitterDragged(object sender, DragDeltaEventArgs e)
    {
        if (projectsCollapsed || projectsColumn == null) return;
        projectsExpandedWidth = Math.Clamp(projectsExpandedWidth + e.HorizontalChange, MacLayout ? 180 : 280, MacLayout ? 320 : 520);
        projectsColumn.Width = new GridLength(projectsExpandedWidth);
        SaveUiState();
    }

    void SettingsSplitterDragged(object sender, DragDeltaEventArgs e)
    {
        if (settingsColumn == null) return;
        settingsExpandedWidth = Math.Clamp(settingsExpandedWidth - e.HorizontalChange, 320, 560);
        settingsColumn.Width = new GridLength(settingsExpandedWidth);
        SaveUiState();
    }

    void SetProjectsCollapsed(bool collapsed, bool persist)
    {
        if (MacLayout && macSidebarReady) { SetMacSidebar(collapsed); if (persist) SaveUiState(); return; }
        projectsCollapsed = collapsed;
        if (projectsHeader != null) projectsHeader.ColumnSpacing = collapsed ? 0 : 8;
        if (projectsToggle != null)
        {
            projectsToggle.Content = new FontIcon { Glyph = collapsed ? "\uE76C" : "\uE76B", FontSize = 12 };
            var label = collapsed ? "Expand Projects" : "Collapse Projects";
            ToolTipService.SetToolTip(projectsToggle, label);
            AutomationProperties.SetName(projectsToggle, label);
        }
        if (projectsHeaderText != null) projectsHeaderText.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (projectsActions != null)
        {
            projectsActions.Orientation = collapsed ? Orientation.Vertical : Orientation.Horizontal;
            projectsActions.HorizontalAlignment = collapsed ? HorizontalAlignment.Center : HorizontalAlignment.Right;
            projectsActions.Margin = collapsed ? new Thickness(0, 0, 0, 10) : new Thickness(0);
            Grid.SetRow(projectsActions, collapsed ? 1 : 0);
            Grid.SetColumn(projectsActions, collapsed ? 0 : 1);
            Grid.SetColumnSpan(projectsActions, collapsed ? 3 : 1);
        }
        if (projectsBody != null) projectsBody.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (projectsColumn != null)
        {
            projectsColumn.MinWidth = collapsed ? 0 : 280;
            projectsColumn.Width = new GridLength(collapsed ? 49 : Math.Clamp(projectsExpandedWidth, 280, 520));
        }
        if (projectsSplitterColumn != null) projectsSplitterColumn.Width = new GridLength(collapsed ? 0 : 12);
        if (projectsSplitter != null) projectsSplitter.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (persist) SaveUiState();
    }

    MenuBar BuildMenu()
    {
        var bar = new MenuBar { Background = new SolidColorBrush(Colors.Transparent) };
        var project = new MenuBarItem { Title = "Project", VerticalAlignment = VerticalAlignment.Center };
        project.Items.Add(MenuItem("New Project", CreateProjectClicked, "Ctrl+N"));
        project.Items.Add(MenuItem("Import Project", ImportProjectClicked, "Ctrl+O"));
        project.Items.Add(MenuItem("Duplicate Project", DuplicateProjectClicked, "Ctrl+D"));
        project.Items.Add(new MenuFlyoutSeparator());
        project.Items.Add(MenuItem("Delete Project", RemoveProjectClicked, "Delete"));
        var pipeline = new MenuBarItem { Title = "Pipeline", VerticalAlignment = VerticalAlignment.Center };
        pipeline.Items.Add(MenuItem("Run All", RunAllClicked));
        pipeline.Items.Add(MenuItem("Run Next Step", RunNextClicked, "Ctrl+R"));
        var run = new MenuFlyoutSubItem { Text = "Run", VerticalAlignment = VerticalAlignment.Center };
        run.Items.Add(MenuItem("Mesh2PPM Inference", RunInferenceClicked));
        run.Items.Add(MenuItem("Preprocessing", RunPreprocessingClicked));
        run.Items.Add(MenuItem("NumCalc", RunNumCalcClicked));
        run.Items.Add(MenuItem("Postprocessing", RunPostprocessingClicked));
        pipeline.Items.Add(run);
        pipeline.Items.Add(new MenuFlyoutSeparator());
        pipeline.Items.Add(MenuItem("Stop", StopClicked, "Esc"));
        pipeline.Items.Add(MenuItem("Reset Outputs", ResetOutputsClicked));
        var help = new MenuBarItem { Title = "Help", VerticalAlignment = VerticalAlignment.Center };
        help.Items.Add(MenuItem("Pinna2HRTF Help", OpenDocumentationClicked, "F1"));
        help.Items.Add(MenuItem("Online Documentation", (_, _) => OpenExternal("https://any2hrtf.github.io/Pinna2HRTF/docs/")));
        help.Items.Add(new MenuFlyoutSeparator());
        help.Items.Add(MenuItem("About Pinna2HRTF", ShowAboutClicked));
        bar.Items.Add(project);
        bar.Items.Add(pipeline);
        var view = new MenuBarItem { Title = "View" };
        view.Items.Add(MenuItem("Show/hide workflow", (_, _) => ToggleMacInspector()));
        view.Items.Add(MenuItem("Show/hide activity", (_, _) => SetLogCollapsed(!logCollapsed, true)));
        bar.Items.Add(view);
        bar.Items.Add(help);
        return bar;
    }

    MenuFlyoutItem MenuItem(string text, RoutedEventHandler handler, string? shortcut = null)
    {
        var item = new MenuFlyoutItem { Text = text, KeyboardAcceleratorTextOverride = shortcut ?? "" };
        item.Click += handler;
        if (shortcut is not null && TryCreateKeyboardAccelerator(shortcut) is { } accelerator)
            item.KeyboardAccelerators.Add(accelerator);
        return item;
    }

    static KeyboardAccelerator? TryCreateKeyboardAccelerator(string shortcut)
    {
        var parts = shortcut.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;
        var key = parts[^1].ToUpperInvariant() switch
        {
            "N" => VirtualKey.N,
            "O" => VirtualKey.O,
            "D" => VirtualKey.D,
            "R" => VirtualKey.R,
            "DELETE" => VirtualKey.Delete,
            "F1" => VirtualKey.F1,
            "ESC" or "ESCAPE" => VirtualKey.Escape,
            _ => VirtualKey.None
        };
        if (key == VirtualKey.None) return null;
        var modifiers = VirtualKeyModifiers.None;
        foreach (var modifier in parts.Take(parts.Length - 1))
        {
            if (modifier.Equals("Ctrl", StringComparison.OrdinalIgnoreCase) || modifier.Equals("Control", StringComparison.OrdinalIgnoreCase)) modifiers |= VirtualKeyModifiers.Control;
            else if (modifier.Equals("Shift", StringComparison.OrdinalIgnoreCase)) modifiers |= VirtualKeyModifiers.Shift;
            else if (modifier.Equals("Alt", StringComparison.OrdinalIgnoreCase)) modifiers |= VirtualKeyModifiers.Menu;
        }
        return new KeyboardAccelerator { Key = key, Modifiers = modifiers };
    }

    Border BuildProjectsPane()
    {
        projectsPaneBorder = new Border { CornerRadius = new CornerRadius(8), Background = surfaceBrush, BorderBrush = borderBrush, BorderThickness = new Thickness(0, 0, 1, 0) };
        var pane = projectsPaneBorder;
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(10, 0, 10, 0), ColumnSpacing = 8 };
        header.RowDefinitions.Add(new RowDefinition { Height = new GridLength(48) });
        header.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        projectsHeader = header;
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        projectsHeaderText = new TextBlock { Text = "Projects", FontSize = 18, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Foreground = primaryTextBrush };
        header.Children.Add(projectsHeaderText);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        projectsActions = buttons;
        buttons.Children.Add(ProjectButton("\uE710", "New project", CreateProjectClicked));
        buttons.Children.Add(ProjectButton("\uE8B7", "New project folder", CreateProjectFolderClicked));
        buttons.Children.Add(ProjectButton("\uE896", "Import project", ImportProjectClicked));
        buttons.Children.Add(ProjectButton("\uE8C8", "Duplicate selected project", DuplicateProjectClicked));
        buttons.Children.Add(ProjectButton("\uE74D", "Delete selected project", RemoveProjectClicked));
        Grid.SetColumn(buttons, 1);
        header.Children.Add(buttons);
        projectsToggle = new Button { Width = 28, Height = 28, MinWidth = 0, MinHeight = 0, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        projectsToggle.Click += (_, _) => SetProjectsCollapsed(!projectsCollapsed, true);
        Grid.SetColumn(projectsToggle, 2);
        header.Children.Add(projectsToggle);
        grid.Children.Add(header);
        projectList.SelectionChanged += ProjectSelectionChanged;
        projectList.KeyDown += RenameFocusedFolder;
        projectList.Background = new SolidColorBrush(Colors.Transparent);
        projectList.ItemContainerTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection();
        projectList.BorderThickness = new Thickness(0);
        projectList.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        projectList.VerticalContentAlignment = VerticalAlignment.Stretch;
        projectList.Margin = new Thickness(10, 0, 10, 10);
        Grid.SetRow(projectList, 1);
        grid.Children.Add(projectList);
        projectsBody = projectList;
        pane.Child = grid;
        return pane;
    }

    Button ProjectButton(string glyph, string tip, RoutedEventHandler handler)
    {
        var fontIcon = new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = glyph, FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var button = new Button { Content = fontIcon, Width = 28, Height = 28, MinWidth = 0, MinHeight = 0, Padding = new Thickness(0) };
        ToolTipService.SetToolTip(button, tip);
        AutomationProperties.SetName(button, tip);
        button.Click += handler;
        return button;
    }

    Grid BuildCenterPane()
    {
        var grid = new Grid { Margin = new Thickness(2, 0, 2, 0) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        logSplitterRow = new RowDefinition { Height = new GridLength(12) };
        grid.RowDefinitions.Add(logSplitterRow);
        centerLogRow = new RowDefinition { Height = new GridLength(Math.Clamp(liveLogExpandedHeight, 100, 600)) };
        grid.RowDefinitions.Add(centerLogRow);
        previewPanelBorder = new Border { CornerRadius = new CornerRadius(8), BorderBrush = borderBrush, BorderThickness = new Thickness(1, 0, 1, 1), Background = surfaceBrush };
        var preview = previewPanelBorder;
        var previewGrid = new Grid();
        previewGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(57) });
        previewGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(12, 7, 12, 7) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titlePanel = new StackPanel();
        titlePanel.Children.Add(new TextBlock { Text = "Viewing", FontSize = 18, FontWeight = FontWeights.SemiBold });
        selectedArtifactText = new TextBlock { Text = "Select a file to preview", FontSize = 12, Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)), TextTrimming = TextTrimming.CharacterEllipsis };
        titlePanel.Children.Add(selectedArtifactText);
        header.Children.Add(titlePanel);
        var pickerPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        placeLeftButton = new Button { Content = "Place Left Mic", MinWidth = 108, MinHeight = 30 };
        placeRightButton = new Button { Content = "Place Right Mic", MinWidth = 112, MinHeight = 30 };
        placeLeftButtonHost = MicButtonHost(placeLeftButton);
        placeRightButtonHost = MicButtonHost(placeRightButton);
        placeLeftButton.Click += (_, _) => BeginPlacement("left");
        placeRightButton.Click += (_, _) => BeginPlacement("right");



        AutomationProperties.SetName(artifactPicker, "Viewing");
        artifactPicker.Width = 230;
        artifactPicker.MinHeight = 30;
        artifactPicker.ItemsSource = artifacts;
        artifactPicker.DisplayMemberPath = "Title";
        artifactPicker.SelectionChanged += ArtifactSelectionChanged;
        pickerPanel.Children.Add(artifactPicker);
        Grid.SetColumn(pickerPanel, 1);
        header.Children.Add(pickerPanel);
        previewGrid.Children.Add(header);
        meshViewerBackground = new Border { Background = viewerBackgroundBrush };
        Grid.SetRow(meshViewerBackground, 1);
        var viewerGrid = new Grid();
        meshViewport = new Viewport3DX
        {
            IsRotationEnabled = true,
            IsPanEnabled = true,
            IsMoveEnabled = false,
            IsZoomEnabled = true,
            UseDefaultGestures = true,
            InputController = new MeshInputController(),
            EnableMouseButtonHitTest = true,
            ShowCoordinateSystem = false,
            ShowViewCube = false,
            ModelUpDirection = new System.Numerics.Vector3(0, 0, 1),
            BackgroundColor = ColorHelper.FromArgb(255, 237, 243, 242),
            EffectsManager = new DefaultEffectsManager()
        };
        meshViewport.Loaded += (_, _) =>
        {
            viewportReady = true;
            EnsureSceneLighting();
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, RefreshArtifacts);
        };
        meshNavigation?.Dispose(); meshNavigation = new SharedNavigation(meshViewport, ResetMeshPointerState, SaveMeshCamera);
        meshViewport.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(MeshViewportPointerPressed), true);
        meshViewport.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(MeshViewportPointerMoved), true);
        meshViewport.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(MeshViewportPointerReleased), true);
        meshViewport.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler(MeshViewportPointerCanceled), true);
        meshViewport.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(MeshViewportPointerCaptureLost), true);
        meshViewport.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(MeshViewportPointerWheelChanged), true);
        meshViewportHost = new CursorGrid(InputSystemCursorShape.Arrow);
        meshViewportHost.Children.Add(meshViewport);
        viewerGrid.Children.Add(meshViewportHost);
        imagePreview = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(18), Visibility = Visibility.Collapsed };
        viewerGrid.Children.Add(imagePreview);
        viewerPlaceholder = new TextBlock { Text = "No preview selected", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 18, Foreground = mutedTextBrush };
        viewerGrid.Children.Add(viewerPlaceholder);
        viewerInteractionHint = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(16),
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(5),
            Background = new SolidColorBrush(Colors.Transparent),
            Visibility = Visibility.Collapsed,
            Child = NavigationHelp.Create()
        };
        viewerGrid.Children.Add(viewerInteractionHint);
        var resetViewButton = NavigationHelp.Command("Reset view");
        resetViewButton.Click += ResetViewClicked;
        resetViewButtonHost = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(16),
            CornerRadius = new CornerRadius(5),
            Background = new SolidColorBrush(Colors.Transparent),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = true,
            Child = resetViewButton
        };
        ToolTipService.SetToolTip(resetViewButton, "Reset this mesh view");
        viewerGrid.Children.Add(resetViewButtonHost);
        placementBorder = new Border { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(10, 12, 10, 0), Visibility = Visibility.Collapsed, Background = viewerHintBackgroundBrush, CornerRadius = new CornerRadius(5), Padding = new Thickness(10, 7, 10, 7) };
        placementPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        placementCoordinates = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Text = "Click the mesh to place the microphone" };
        automaticPositionButton = new Button { Content = "Use Automatic Position" };
        cancelPositionButton = new Button { Content = "Cancel" };
        donePositionButton = new Button { Content = "Done", IsEnabled = false };
        automaticPositionButton.Click += AutomaticPositionClicked;
        cancelPositionButton.Click += CancelPositionClicked;
        donePositionButton.Click += DonePositionClicked;
        placementPanel.Children.Add(placementCoordinates);
        placementPanel.Children.Add(automaticPositionButton);
        placementPanel.Children.Add(cancelPositionButton);
        placementPanel.Children.Add(donePositionButton);
        placementBorder.Child = placementPanel;
        viewerGrid.Children.Add(placementBorder);
        scanAlignmentBorder = new Border { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(10, 12, 10, 0), Visibility = Visibility.Collapsed, Background = viewerHintBackgroundBrush, CornerRadius = new CornerRadius(5), Padding = new Thickness(10, 7, 10, 7) };
        var alignmentPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        scanAlignmentStatus = new TextBlock { Text = "Click nose tip, then left and right ear-canal entrances", VerticalAlignment = VerticalAlignment.Center };
        applyScanAlignmentButton.Click += async (_, _) => await ApplyScanAlignmentAsync();
        var cancelAlignment = new Button { Content = "Cancel" };
        cancelAlignment.Click += (_, _) => EndScanAlignment();
        var restartAlignment = new Button { Content = "Restart picks" };
        restartAlignment.Click += (_, _) => ResetScanAlignmentPicks();
        alignmentPanel.Children.Add(scanAlignmentStatus);
        alignmentPanel.Children.Add(coordinateToggle);
        coordinateToggle.Click += (_, _) => UpdateAlignmentAxes();
        alignmentPanel.Children.Add(restartAlignment);
        alignmentPanel.Children.Add(applyScanAlignmentButton);
        alignmentPanel.Children.Add(cancelAlignment);
        scanAlignmentBorder.Child = alignmentPanel;
        viewerGrid.Children.Add(scanAlignmentBorder);
        previewGrid.Children.Add(meshViewerBackground);
        Grid.SetRow(viewerGrid, 1);
        previewGrid.Children.Add(viewerGrid);
        preview.Child = previewGrid;
        grid.Children.Add(preview);
        logSplitter = BuildSplitter(false, LogSplitterDragged);
        logSplitter.Margin = new Thickness(0);
        Grid.SetRow(logSplitter, 1);
        grid.Children.Add(logSplitter);
        var log = BuildLogPane();
        Grid.SetRow(log, 2);
        grid.Children.Add(log);
        SetLogCollapsed(logCollapsed, false);
        return grid;
    }

    void EnsureSceneLighting()
    {
        if (!viewportReady || meshViewport.Items == null || sceneLights.Count > 0)
            return;
        sceneLights.AddRange(EvenMeshLighting.Install(meshViewport));
    }

    void LogSplitterDragged(object sender, DragDeltaEventArgs e)
    {
        if (logCollapsed || centerLogRow == null) return;
        liveLogExpandedHeight = Math.Clamp(liveLogExpandedHeight - e.VerticalChange, 100, 600);
        centerLogRow.Height = new GridLength(liveLogExpandedHeight);
        SaveUiState();
    }

    Border BuildLogPane()
    {
        logPanelBorder = new Border { CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 3, 0, 0), Background = surfaceBrush, BorderBrush = borderBrush, BorderThickness = new Thickness(1) };
        var panel = new Grid(); panel.RowDefinitions.Add(new() { Height = GridLength.Auto }); panel.RowDefinitions.Add(new());
        var header = new Grid { Height = LogHeaderHeight, Padding = new Thickness(8, 0, 12, 0), ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new()); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new FontIcon { FontFamily = new FontFamily("Segoe Fluent Icons"), Glyph = "\uE76C", FontSize = 12 });
        title.Children.Add(new TextBlock { Text = "Live Log", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        logToggle = new Button { Content = title, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(6), MinHeight = 32 };
        logToggle.Click += (_, _) => SetLogCollapsed(!logCollapsed, true); header.Children.Add(logToggle);
        logHeaderActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        technicalLogButton = new Button { Content = "Technical Log", Padding = new Thickness(10, 4, 10, 4), MinHeight = 30, IsEnabled = false };
        technicalLogButton.Click += OpenTechnicalLogClicked; logHeaderActions.Children.Add(technicalLogButton);
        var clear = new Button { Content = "Clear", Padding = new Thickness(10, 4, 10, 4), MinHeight = 30, IsEnabled = false };
        ToolTipService.SetToolTip(clear, "Clear the activity shown here. Technical logs remain available."); clear.Click += ClearLogClicked; logHeaderActions.Children.Add(clear);
        Grid.SetColumn(logHeaderActions, 1); header.Children.Add(logHeaderActions); panel.Children.Add(header);
        logText = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), FontSize = 12, BorderThickness = new Thickness(0), Margin = new Thickness(10) };
        logText.TextChanged += (_, _) => clear.IsEnabled = !string.IsNullOrEmpty(logText.Text);
        ScrollViewer.SetVerticalScrollBarVisibility(logText, ScrollBarVisibility.Auto); logText.Loaded += (_, _) => AttachLogScrollViewer();
        logContentHost = new Border { Child = logText, BorderBrush = borderBrush, BorderThickness = new Thickness(0, 1, 0, 0) };
        Grid.SetRow(logContentHost, 1); panel.Children.Add(logContentHost); logPanelBorder.Child = panel;
        panel.Loaded += (_, _) => SetLogCollapsed(logCollapsed, false);
        return logPanelBorder;
    }

    void SetLogCollapsed(bool collapsed, bool persist)
    {
        logCollapsed = collapsed;
        if (logSplitterRow != null) logSplitterRow.Height = new GridLength(collapsed ? 0 : 12);
        if (logSplitter != null) logSplitter.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (centerLogRow != null) centerLogRow.Height = new GridLength(collapsed
            ? LogHeaderHeight + (logPanelBorder?.BorderThickness.Top ?? 0) + (logPanelBorder?.BorderThickness.Bottom ?? 0) + (logPanelBorder?.Margin.Top ?? 0)
            : Math.Clamp(liveLogExpandedHeight, 100, 600));
        if (logPanelBorder != null) logPanelBorder.Visibility = Visibility.Visible;
        if (logContentHost != null) logContentHost.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (logHeaderActions != null) logHeaderActions.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (logToggle != null)
        {
            ((FontIcon)((StackPanel)logToggle.Content).Children[0]).Glyph = collapsed ? "\uE76C" : "\uE70D";
            AutomationProperties.SetName(logToggle, collapsed ? "Expand Live Log" : "Collapse Live Log");
        }
        if (MacLayout) RefreshMacPresentation();
        if (!collapsed) RestoreLogScroll(0, true);
        if (persist) SaveUiState();
    }

    Border BuildSettingsPane() => BuildWorkflowPane();

    void AddSetting(StackPanel parent, string label, string id, Control control, string? checkBoxText = null)
    {
        parent.Children.Add(AddSettingPanel(label, id, control, checkBoxText));
    }

    Grid AddSettingPanel(string label, string id, Control control, string? checkBoxText = null)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        if (control is CheckBox checkBox)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            checkBox.Content = checkBoxText ?? label;
            checkBox.HorizontalAlignment = HorizontalAlignment.Left;
            row.Children.Add(checkBox);
            var info = InfoButton(id);
            Grid.SetColumn(info, 1);
            row.Children.Add(info);
        }
        else
        {
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var labelPanel = new StackPanel { Orientation = Orientation.Horizontal };
            labelPanel.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
            var info = InfoButton(id);
            labelPanel.Children.Add(info);
            row.Children.Add(labelPanel);
            Grid.SetRow(control, 1);
            row.Children.Add(control);
        }
        control.Tag = id;
        control.HorizontalAlignment = HorizontalAlignment.Stretch;
        control.MinHeight = 28;
        settingControls[id] = control;
        if (control is TextBox textBox)
        {
            AttachSettingInput(textBox);
        }
        if (control is CheckBox box)
        {
            if (ReferenceEquals(box, usePredictionsBox))
            {
                box.Checked += BezierPPMSettingChanged;
                box.Unchecked += BezierPPMSettingChanged;
            }
            else if (SettingResetStage(id) != null)
            {
                box.Checked += SettingChanged;
                box.Unchecked += SettingChanged;
            }
            else
            {
                box.Checked += ProjectEdited;
                box.Unchecked += ProjectEdited;
            }
        }
        if (control is ComboBox combo)
            combo.SelectionChanged += ModelSelectionChanged;
        return row;
    }

    void AddPathSetting(StackPanel parent, string label, string id, TextBox box, RoutedEventHandler handler, bool nested = false) => parent.Children.Add(PathSettingPanel(label, id, box, handler));

    Grid PathSettingPanel(string label, string id, TextBox box, RoutedEventHandler handler)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labelPanel = new StackPanel { Orientation = Orientation.Horizontal };
        labelPanel.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        var info = InfoButton(id);
        labelPanel.Children.Add(info);
        row.Children.Add(labelPanel);
        var browse = new Button { Content = "Choose…", HorizontalAlignment = HorizontalAlignment.Right, MinHeight = 28, Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(6, 0, 0, 0) };
        browse.Click += handler;
        Grid.SetColumn(browse, 1);
        Grid.SetRow(browse, 1);
        row.Children.Add(browse);
        var name = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = true };
        void UpdateName()
        {
            var path = box.Text.Trim();
            name.Text = path.Length == 0 ? "No path selected" : Path.GetFileName(Path.TrimEndingDirectorySeparator(path)) is { Length: > 0 } leaf ? leaf : path;
            ToolTipService.SetToolTip(name, path);
        }
        box.RegisterPropertyChangedCallback(TextBox.TextProperty, (_, _) => UpdateName()); UpdateName();
        var menu = new MenuFlyout(); var copy = new MenuFlyoutItem { Text = "Copy path" };
        copy.Click += (_, _) => { var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(box.Text); global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); };
        menu.Items.Add(copy); name.ContextFlyout = menu;
        Grid.SetRow(name, 1); row.Children.Add(name);
        box.HorizontalAlignment = HorizontalAlignment.Stretch;
        box.MinHeight = 28;
        box.Visibility = Visibility.Collapsed;
        var disclosure = new HyperlinkButton { Content = "Show path", FontSize = 12, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left };
        disclosure.Click += (_, _) => {
            var show = box.Visibility != Visibility.Visible;
            box.Visibility = show ? Visibility.Visible : Visibility.Collapsed; disclosure.Content = show ? "Hide path" : "Show path";
            if (show) { box.Focus(FocusState.Programmatic); box.SelectAll(); }
        };
        Grid.SetRow(disclosure, 2); Grid.SetColumnSpan(disclosure, 2); row.Children.Add(disclosure);
        Grid.SetRow(box, 3); Grid.SetColumnSpan(box, 2); row.Children.Add(box);
        if (id == "project.save_location")
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
            row.Children.Remove(browse); actions.Children.Add(browse);
            var open = new Button { Content = "Open", MinHeight = 28, Padding = new Thickness(8, 2, 8, 2) };
            open.Click += (_, _) => { if (Directory.Exists(box.Text)) OpenExternal(box.Text); };
            box.RegisterPropertyChangedCallback(TextBox.TextProperty, (_, _) => open.IsEnabled = Directory.Exists(box.Text));
            open.IsEnabled = Directory.Exists(box.Text); actions.Children.Add(open);
            Grid.SetRow(actions, 1); Grid.SetColumn(actions, 1); row.Children.Add(actions);
        }
        box.Tag = id;
        settingControls[id] = box;
        AttachSettingInput(box);
        return row;
    }

    Button InfoButton(string id)
    {
        var info = new Button
        {
            Content = new FontIcon
            {
                FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = "\uE946",
                FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            },
            Width = 20, Height = 20,
            Padding = new Thickness(0), Margin = new Thickness(4, 0, 0, 0),
            Tag = id.StartsWith("scan_preparation.", StringComparison.Ordinal)
                ? "scan." + (id == "scan_preparation.scan_path" ? "path" : id["scan_preparation.".Length..])
                : id, Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0), Foreground = mutedTextBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        ToolTipService.SetToolTip(info, "Show information");
        AutomationProperties.SetName(info, "Show information");
        info.Click += SettingInfoClicked;
        return info;
    }

    void AddExpander(StackPanel parent, string title, IEnumerable<FrameworkElement> children)
    {
        var panel = new StackPanel { Spacing = 3 };
        foreach (var child in children)
            panel.Children.Add(child);
        panel.HorizontalAlignment = HorizontalAlignment.Stretch;
        var expander = new Expander { Header = title, Content = panel, IsExpanded = false, Margin = new Thickness(0, 5, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        settingSections.Add(expander);
        parent.Children.Add(expander);
    }

    void RegisterSettingControls()
    {
        settingControls["project.name"] = projectNameBox;
        settingControls["project.left_ear"] = leftEarBox;
        settingControls["project.right_ear"] = rightEarBox;
        settingControls["project.save_location"] = saveLocationBox;
        settingControls["mesh2hrtf.evaluation_grid"] = evaluationGridBox;
    }

    void ProjectSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (reconcilingProjectRows) return;
        if (projectList.SelectedItem is Grid { Tag: ProjectRecord project } && !ReferenceEquals(selectedProject, project))
        {
            SaveMeshCamera();
            ResetViewer();
            selectedProject = project;
            LoadSelectedProject();
            RefreshArtifacts();
        }
    }

    void RenameProjectFromContext(ProjectRecord project)
    {
        SelectProjectFromContext(project);
        if (!macInspectorVisible) ToggleMacInspector();
        SelectWorkflowStep(0);
        DispatcherQueue.TryEnqueue(() => { projectNameBox.StartBringIntoView(); projectNameBox.Focus(FocusState.Keyboard); projectNameBox.SelectAll(); });
    }

    void SelectProjectFromContext(ProjectRecord project)
    {
        if (!projects.Contains(project)) return;
        if (!ReferenceEquals(selectedProject, project)) { SaveMeshCamera(); ResetViewer(); selectedProject = project; }
        if (projectRows.TryGetValue(project.Id, out var row) && !ReferenceEquals(projectList.SelectedItem, row.Root)) projectList.SelectedItem = row.Root;
        LoadSelectedProject(); RefreshArtifacts(); RefreshPipelineStatus(); Persist();
    }

    void LoadSelectedProject()
    {
        if (scanAlignmentMode && alignmentSessionProject != selectedProject?.Id) EndScanAlignment();
        if (placementSide != null) EndPlacement();
        loading = true;
        var project = selectedProject;
        projectNameBox.Text = project?.Name ?? "";
        leftEarBox.Text = project?.LeftEar ?? "";
        rightEarBox.Text = project?.RightEar ?? "";
        saveLocationBox.Text = project?.SaveLocation ?? "";
        scanPreparationEnabledBox.IsChecked = project?.Settings.ScanPreparation.Enabled ?? false;
        scanPathBox.Text = project?.Settings.ScanPreparation.ScanPath ?? "";
        prepareLeftEarBox.IsChecked = project?.Settings.ScanPreparation.PrepareLeft ?? true;
        prepareRightEarBox.IsChecked = project?.Settings.ScanPreparation.PrepareRight ?? true;
        requireReviewBox.IsChecked = project?.Settings.ScanPreparation.RequireManualReview ?? false;
        usePredictionsBox.IsChecked = project?.Settings.Inference.UsePredictionsForPreprocessing ?? false;
        evaluationGridBox.Text = project?.Settings.Preprocessing.EvaluationGrid ?? "";
        earDistanceBox.Text = "";
        minFrequencyBox.Text = project?.Settings.Preprocessing.MinFrequency ?? "0";
        maxFrequencyBox.Text = project?.Settings.Preprocessing.MaxFrequency ?? "24000";
        frequencyStepsBox.Text = project?.Settings.Preprocessing.FrequencyStepCount ?? "129";
        microphoneFacesBox.Text = project?.Settings.Preprocessing.SourceAssignmentFaceCount ?? "6";
        meshMinEdgeBox.Text = project?.Settings.Preprocessing.MeshMinEdgeLength ?? "0.5";
        meshMaxEdgeBox.Text = project?.Settings.Preprocessing.MeshMaxEdgeLength ?? "10.0";
        meshMaxErrorBox.Text = project?.Settings.Preprocessing.MeshMaxError ?? "0.5";
        meshGammaBox.Text = project?.Settings.Preprocessing.MeshGamma ?? "0.2";
        meshGammaOppositeBox.Text = project?.Settings.Preprocessing.MeshGammaOpposite ?? "0.1";
        maxInstancesBox.Text = project?.Settings.NumCalc.MaxInstances ?? "1";
        maxCpuLoadBox.Text = project?.Settings.NumCalc.MaxCpuLoad ?? "90";
        adaptiveFmmLengthBox.IsChecked = project?.Settings.NumCalc.AdaptiveFmmLength ?? true;
        normalizeHrtfsBox.IsChecked = project?.Settings.Postprocessing?.Normalize ?? true;
        resampleHrirsBox.IsChecked = project?.Settings.Postprocessing?.ResampleHrirs ?? false;
        spatialUpsamplingBox.IsChecked = project?.Settings.Postprocessing?.SpatialUpsampling ?? false;
        spatialNormalizeBox.IsChecked = project?.Settings.Postprocessing?.SpatialNormalize ?? false;
        foreach (var binding in textSettings.Values)
            binding.Control.Text = project == null ? binding.DefaultValue : binding.Read(project) ?? binding.DefaultValue;
        SelectModel(project);
        LoadSelectedProjectLog();
        loading = false;
        UpdatePostprocessingControls();
        UpdatePlacementButtons();
        RebaseSettingInputs();
        RestoreSettingDrafts(project);
        RefreshGeometry();
        RefreshWorkflow();
    }

    Stage? SettingResetStage(string id)
    {
        if (id.StartsWith("scan_preparation.")) return Stage.ScanPreparation;
        if (id == "project.use_bezierppm" || id.StartsWith("inference.", StringComparison.OrdinalIgnoreCase)) return Stage.Inference;
        if (id.StartsWith("mesh2hrtf.", StringComparison.OrdinalIgnoreCase) || id.StartsWith("mesh_grading.", StringComparison.OrdinalIgnoreCase)) return Stage.Preprocessing;
        if (id.StartsWith("postprocessing.", StringComparison.OrdinalIgnoreCase)) return Stage.Postprocessing;
        return null;
    }

    sealed record TextSetting(TextBox Control, Func<ProjectRecord, string?> Read,
        Action<ProjectRecord, string> Write, string DefaultValue);

    Dictionary<string, TextSetting> CreateTextSettings() => new()
    {
        ["mesh2hrtf.evaluation_grid"] = new(evaluationGridBox, p => p.Settings.Preprocessing.EvaluationGrid,
            (p, value) => p.Settings.Preprocessing.EvaluationGrid = value.Trim(), ""),

        ["mesh2hrtf.min_frequency"] = new(minFrequencyBox, p => p.Settings.Preprocessing.MinFrequency,
            (p, value) => p.Settings.Preprocessing.MinFrequency = value.Trim(), "0"),
        ["mesh2hrtf.max_frequency"] = new(maxFrequencyBox, p => p.Settings.Preprocessing.MaxFrequency,
            (p, value) => p.Settings.Preprocessing.MaxFrequency = value.Trim(), "24000"),
        ["mesh2hrtf.frequency_steps"] = new(frequencyStepsBox, p => p.Settings.Preprocessing.FrequencyStepCount,
            (p, value) => p.Settings.Preprocessing.FrequencyStepCount = value.Trim(), "129"),
        ["mesh2hrtf.microphone_faces"] = new(microphoneFacesBox, p => p.Settings.Preprocessing.SourceAssignmentFaceCount,
            (p, value) => p.Settings.Preprocessing.SourceAssignmentFaceCount = value.Trim(), "6"),
        ["mesh_grading.min_edge_length"] = new(meshMinEdgeBox, p => p.Settings.Preprocessing.MeshMinEdgeLength,
            (p, value) => p.Settings.Preprocessing.MeshMinEdgeLength = value.Trim(), "0.5"),
        ["mesh_grading.max_edge_length"] = new(meshMaxEdgeBox, p => p.Settings.Preprocessing.MeshMaxEdgeLength,
            (p, value) => p.Settings.Preprocessing.MeshMaxEdgeLength = value.Trim(), "10.0"),
        ["mesh_grading.max_error"] = new(meshMaxErrorBox, p => p.Settings.Preprocessing.MeshMaxError,
            (p, value) => p.Settings.Preprocessing.MeshMaxError = value.Trim(), "0.5"),
        ["mesh_grading.gamma"] = new(meshGammaBox, p => p.Settings.Preprocessing.MeshGamma,
            (p, value) => p.Settings.Preprocessing.MeshGamma = value.Trim(), "0.2"),
        ["mesh_grading.gamma_opposite"] = new(meshGammaOppositeBox, p => p.Settings.Preprocessing.MeshGammaOpposite,
            (p, value) => p.Settings.Preprocessing.MeshGammaOpposite = value.Trim(), "0.1"),
        ["numcalc.parallel_instances"] = new(maxInstancesBox, p => p.Settings.NumCalc.MaxInstances,
            (p, value) => p.Settings.NumCalc.MaxInstances = value.Trim(), "1"),
        ["numcalc.cpu_limit"] = new(maxCpuLoadBox, p => p.Settings.NumCalc.MaxCpuLoad,
            (p, value) => p.Settings.NumCalc.MaxCpuLoad = value.Trim(), "90"),
        ["postprocessing.level_offset"] = new(levelOffsetBox, p => p.Settings.Postprocessing?.LevelOffsetDB,
            (p, value) => p.Settings.Postprocessing!.LevelOffsetDB = value.Trim(), "-30"),
        ["postprocessing.sampling_rate"] = new(samplingRateBox, p => p.Settings.Postprocessing?.SamplingRate ?? "48000",
            (p, value) => p.Settings.Postprocessing!.SamplingRate = NormalizeSamplingRate(value), "48000"),
    };

    string CurrentSettingValue(string id) => textSettings.TryGetValue(id, out var binding) ? binding.Control.Text : id switch
    {
        "project.use_bezierppm" => (usePredictionsBox.IsChecked == true).ToString(),
        "scan_preparation.enabled" => (scanPreparationEnabledBox.IsChecked == true).ToString(),
        "scan_preparation.prepare_left" => (prepareLeftEarBox.IsChecked == true).ToString(),
        "scan_preparation.prepare_right" => (prepareRightEarBox.IsChecked == true).ToString(),
        "inference.model" => modelPicker.SelectedItem?.ToString() ?? "",
        "numcalc.adaptive_fmm" => (adaptiveFmmLengthBox.IsChecked == true).ToString(),
        "postprocessing.normalize" => (normalizeHrtfsBox.IsChecked == true).ToString(),
        "postprocessing.spatial_upsampling" => (spatialUpsamplingBox.IsChecked == true).ToString(),
        "postprocessing.spatial_normalize" => (spatialNormalizeBox.IsChecked == true).ToString(),
        "postprocessing.resample_hrirs" => (resampleHrirsBox.IsChecked == true).ToString(),
        _ => ""
    };

    string StoredSettingValue(ProjectRecord project, string id) => textSettings.TryGetValue(id, out var binding) ? binding.Read(project) ?? "" : id switch
    {
        "project.use_bezierppm" => project.Settings.Inference.UsePredictionsForPreprocessing.ToString(),
        "scan_preparation.enabled" => project.Settings.ScanPreparation.Enabled.ToString(),
        "scan_preparation.prepare_left" => project.Settings.ScanPreparation.PrepareLeft.ToString(),
        "scan_preparation.prepare_right" => project.Settings.ScanPreparation.PrepareRight.ToString(),
        "inference.model" => ModelName(project.Settings.Inference.ModelConfig),
        "numcalc.adaptive_fmm" => project.Settings.NumCalc.AdaptiveFmmLength.ToString(),
        "postprocessing.normalize" => (project.Settings.Postprocessing?.Normalize ?? true).ToString(),
        "postprocessing.spatial_upsampling" => (project.Settings.Postprocessing?.SpatialUpsampling ?? false).ToString(),
        "postprocessing.spatial_normalize" => (project.Settings.Postprocessing?.SpatialNormalize ?? false).ToString(),
        "postprocessing.resample_hrirs" => (project.Settings.Postprocessing?.ResampleHrirs ?? false).ToString(),
        _ => ""
    };

    static GeneratedOutputManifest.OutputStage OutputStageFor(Stage stage) => stage == Stage.ScanPreparation
        ? GeneratedOutputManifest.OutputStage.ScanPreparation : stage == Stage.Inference
        ? GeneratedOutputManifest.OutputStage.Inference : stage == Stage.Preprocessing
        ? GeneratedOutputManifest.OutputStage.Preprocessing : stage == Stage.Numcalc
        ? GeneratedOutputManifest.OutputStage.Numcalc : GeneratedOutputManifest.OutputStage.Postprocessing;

    GeneratedOutputManifest OutputsFor(ProjectRecord project)
    {
        var root = Path.GetFullPath(project.SaveLocation);
        // A shared or nested output root would allow one project to erase another's data.
        if (projects.Any(other => other.Id != project.Id && !string.IsNullOrWhiteSpace(other.SaveLocation) &&
            (ContainsPath(root, other.SaveLocation) || ContainsPath(other.SaveLocation, root))))
            throw new IOException("Choose a separate output folder for this project before resetting or running it.");
        var inputs = projects.SelectMany(p => ProtectedInputs(p, project.Id))
            .Where(p => !string.IsNullOrWhiteSpace(p)).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToArray();
        var key = root + "\n" + SofaDirectory(project) + "\n" + string.Join("\n", inputs);
        if (!outputStores.TryGetValue(key, out var store)) outputStores[key] = store = new GeneratedOutputManifest(root, inputs, SofaDirectory(project));
        return store;
    }

    async Task ReconcileOutputsAsync(ProjectRecord project, bool required = false)
    {
        if (shutdownCleanupDone || string.IsNullOrWhiteSpace(project.SaveLocation) || !Directory.Exists(project.SaveLocation) ||
            ProjectBusy(project.Id)) return;
        if (!required && (outputScans.Contains(project.Id) || lastOutputScan.TryGetValue(project.Id, out var previous) && DateTime.UtcNow - previous < TimeSpan.FromSeconds(10))) return;
        var root = project.SaveLocation;
        outputScans.Add(project.Id);
        try
        {
            var store = OutputsFor(project);
            var stages = await Task.Run(store.Reconcile);
            if (project.SaveLocation == root) knownOutputs[project.Id] = stages;
        }
        catch when (!required) { /* Busy/copied outputs are retried; explicit operations report errors. */ }
        finally { outputScans.Remove(project.Id); lastOutputScan[project.Id] = DateTime.UtcNow; }
    }

    bool HasOutputsFrom(Stage stage, ProjectRecord project) => knownOutputs.TryGetValue(project.Id, out var entries) &&
        entries.Any(s => s >= OutputStageFor(stage));

    void SettingChanged(object sender, RoutedEventArgs e)
    {
        if (loading || sender is not Control control || control.Tag is not string id) return;
        _ = ObserveUiTaskAsync(HandleSettingChangeAsync(id), "Change setting", selectedProject);
    }

    async Task HandleSettingChangeAsync(string id)
    {
        if (loading || selectedProject == null) return;
        if (id == "mesh2hrtf.ear_distance") { await EditGeometryAsync("ear", earDistanceBox.Text); return; }
        var project = selectedProject;
        var desired = CurrentSettingValue(id);
        if (desired == StoredSettingValue(project, id)) return;
        if (ProjectBusy(project.Id)) { LoadSelectedProject(); return; }
        var resetStage = SettingResetStage(id);
        if (resetStage != null)
        {
            try { await ReconcileOutputsAsync(project, true); }
            catch { LoadSelectedProject(); AppendLog("Could not inspect output ownership; setting was not changed.", project.Id); return; }
            if (selectedProject != project || shutdownCleanupDone) return;
        }
        var promptForReset = resetStage != null && HasOutputsFrom(resetStage, project);
        if (!promptForReset)
        {
            ApplySettingToProject(selectedProject!, id, desired);
            ProjectEdited(this, new RoutedEventArgs());
            return;
        }
        LoadSelectedProject();
        var dialog = new ContentDialog
        {
            Title = "Reset pipeline outputs?",
            Content = $"Changing this setting resets {resetStage!.Title} and all following outputs. Input meshes and project settings will be kept.",
            PrimaryButtonText = "Reset and apply",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Root.XamlRoot
        };
        if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;
        if (selectedProject != project || !await ResetProjectOutputsAsync(project, resetStage!) || selectedProject != project) return;
        loading = true;
        SetSettingControlValue(id, desired);
        loading = false;
        ApplySettingToProject(selectedProject!, id, desired);
        ProjectEdited(this, new RoutedEventArgs());
    }

    void ApplySettingToProject(ProjectRecord project, string id, string value)
    {
        if (id != "inference.model" || string.IsNullOrWhiteSpace(value)) return;
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        var config = Path.Combine(resources, value + ".yaml");
        var checkpoint = Path.Combine(resources, value + ".pth");
        if (File.Exists(config)) project.Settings.Inference.ModelConfig = config;
        if (File.Exists(checkpoint)) project.Settings.Inference.ModelCheckpoint = checkpoint;
    }

    void SetSettingControlValue(string id, string value)
    {
        if (textSettings.TryGetValue(id, out var binding)) { binding.Control.Text = value; return; }
        switch (id)
        {
            case "project.use_bezierppm": usePredictionsBox.IsChecked = bool.TryParse(value, out var use) && use; break;
            case "scan_preparation.enabled": scanPreparationEnabledBox.IsChecked = bool.TryParse(value, out var scan) && scan; break;
            case "scan_preparation.prepare_left": prepareLeftEarBox.IsChecked = bool.TryParse(value, out var left) && left; break;
            case "scan_preparation.prepare_right": prepareRightEarBox.IsChecked = bool.TryParse(value, out var right) && right; break;
            case "inference.model": modelPicker.SelectedItem = value; break;
            case "numcalc.adaptive_fmm": adaptiveFmmLengthBox.IsChecked = bool.TryParse(value, out var adaptive) && adaptive; break;
            case "postprocessing.normalize": normalizeHrtfsBox.IsChecked = bool.TryParse(value, out var normalize) && normalize; break;
            case "postprocessing.spatial_upsampling": spatialUpsamplingBox.IsChecked = bool.TryParse(value, out var spatial) && spatial; break;
            case "postprocessing.spatial_normalize": spatialNormalizeBox.IsChecked = bool.TryParse(value, out var spatialNormal) && spatialNormal; break;
            case "postprocessing.resample_hrirs": resampleHrirsBox.IsChecked = bool.TryParse(value, out var resample) && resample; UpdatePostprocessingControls(); break;
        }
    }

    void ProjectEdited(object sender, RoutedEventArgs e)
    {
        if (loading || selectedProject == null)
            return;
        var project = selectedProject;
        if (ProjectBusy(project.Id)) { LoadSelectedProject(); return; }
        if (projectsBeingRemoved.Count != 0 && !SamePath(project.SaveLocation, saveLocationBox.Text.Trim()))
        { AppendLog("Wait for project removal before changing a save location.", project.Id); LoadSelectedProject(); return; }
        var previousLeftEar = project.LeftEar;
        var previousRightEar = project.RightEar;
        var previousScanPath = project.Settings.ScanPreparation.ScanPath;
        project.Name = projectNameBox.Text.Trim();
        project.LeftEar = leftEarBox.Text.Trim();
        project.RightEar = rightEarBox.Text.Trim();
        project.SaveLocation = saveLocationBox.Text.Trim();
        project.Settings.Inference.UsePredictionsForPreprocessing = usePredictionsBox.IsChecked == true;
        UpdatePlacementButtons();
        if (placementSide != null && (project.Settings.Inference.UsePredictionsForPreprocessing || !PlacementIsCurrent())) EndPlacement();
        project.Settings.ScanPreparation.Enabled = scanPreparationEnabledBox.IsChecked == true;
        project.Settings.ScanPreparation.ScanPath = scanPathBox.Text.Trim();
        project.Settings.ScanPreparation.PrepareLeft = prepareLeftEarBox.IsChecked == true;
        project.Settings.ScanPreparation.PrepareRight = prepareRightEarBox.IsChecked == true;
        if (!SamePath(previousScanPath, project.Settings.ScanPreparation.ScanPath) && !string.IsNullOrWhiteSpace(project.Settings.ScanPreparation.ScanPath))
        {
            project.Settings.ScanPreparation.OriginalScanPath = project.Settings.ScanPreparation.ScanPath;
            project.Settings.ScanPreparation.ReviewedLeft = null;
            project.Settings.ScanPreparation.ReviewedRight = null;
        }
        project.Settings.Preprocessing.EvaluationGrid = evaluationGridBox.Text.Trim();
        project.Settings.NumCalc.AdaptiveFmmLength = adaptiveFmmLengthBox.IsChecked == true;
        project.Settings.Postprocessing ??= new PostprocessingSettings();
        project.Settings.Postprocessing.Normalize = normalizeHrtfsBox.IsChecked == true;
        project.Settings.Postprocessing.SpatialUpsampling = spatialUpsamplingBox.IsChecked == true;
        project.Settings.Postprocessing.SpatialNormalize = spatialNormalizeBox.IsChecked == true;
        project.Settings.Postprocessing.ResampleHrirs = resampleHrirsBox.IsChecked == true;
        foreach (var binding in textSettings.Values)
            if (!HasInvalidSettingDraft(binding.Control) && (!HasSettingDraft(binding.Control) || committingSettingInputs.Contains(binding.Control))) binding.Write(project, binding.Control.Text);
        samplingRateBox.Text = project.Settings.Postprocessing.SamplingRate;
        UpdatePostprocessingControls();
        InvalidateManualPositions(project);
        Persist();
        var inputMeshesChanged = !string.Equals(previousLeftEar, project.LeftEar, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(previousRightEar, project.RightEar, StringComparison.OrdinalIgnoreCase);
        if (inputMeshesChanged && placementSide == null &&
            (string.IsNullOrWhiteSpace(project.LeftEar) || string.IsNullOrWhiteSpace(project.RightEar) ||
             File.Exists(project.LeftEar) || File.Exists(project.RightEar)))
            RefreshArtifacts();
        RefreshProjectList();
        RefreshPipelineStatus();
    }

    static string NormalizeSamplingRate(string value)
    {
        return value.Trim();
    }

    void UpdatePostprocessingControls() => samplingRateBox.IsEnabled = resampleHrirsBox.IsChecked == true;

    void BezierPPMSettingChanged(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(HandleSettingChangeAsync("project.use_bezierppm"), "Change Mesh2PPM", selectedProject);

    readonly Dictionary<Guid, Grid> folderRows = [];
    bool reconcilingProjectRows;

    void RefreshProjectList(ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        var projectScroll = FindDescendant<ScrollViewer>(projectList);
        var projectScrollOffset = projectScroll?.VerticalOffset ?? 0;
        var desired = new List<object>();
        void AddProject(ProjectRecord project)
        {
            if (!projectRows.TryGetValue(project.Id, out var ui)) ui = AddProjectListRow(project);
            ui.Root.Margin = new Thickness(project.FolderId != null ? 25 : 8, 7, 8, 7);
            desired.Add(ui.Root);
        }
        foreach (var project in projects.Where(p => p.FolderId == null)) AddProject(project);
        foreach (var folder in registry.Folders)
        {
            if (!folderRows.TryGetValue(folder.Id, out var row)) folderRows[folder.Id] = row = BuildProjectFolderRow(folder);
            var toggle = (Button)row.Children[0];
            ((FontIcon)toggle.Content).Glyph = folder.IsExpanded ? "\uE70D" : "\uE76C";
            AutomationProperties.SetName(toggle, (folder.IsExpanded ? "Collapse " : "Expand ") + folder.Name);
            ToolTipService.SetToolTip(toggle, folder.IsExpanded ? "Collapse folder" : "Expand folder");
            ((TextBlock)row.Children[1]).Text = folder.Name;
            desired.Add(row);
            if (folder.IsExpanded)
                foreach (var project in projects.Where(p => p.FolderId == folder.Id)) AddProject(project);
        }
        reconcilingProjectRows = true;
        try
        {
            StableRows.Reconcile(projectList.Items, desired, item => item is FrameworkElement { Tag: ProjectFolder });
            if (selectedProject != null && projectRows.TryGetValue(selectedProject.Id, out var selectedRow) && projectList.Items.Contains(selectedRow.Root))
                projectList.SelectedItem = selectedRow.Root;
        }
        finally { reconcilingProjectRows = false; }
        if (projectScroll != null)
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
                projectScroll.ChangeView(null, Math.Min(projectScrollOffset, projectScroll.ScrollableHeight), null, true));
        foreach (var id in projectRows.Keys.Where(id => projects.All(p => p.Id != id)).ToArray()) projectRows.Remove(id);
        foreach (var id in folderRows.Keys.Where(id => registry.Folders.All(f => f.Id != id)).ToArray()) folderRows.Remove(id);
        RefreshProjectRows(inspection);
    }

    void RefreshProjectRows(ArtifactInspection inspection)
    {
        foreach (var project in projects)
        {
            project.IsRunning = runs.ContainsKey(project.Id);
            project.StatusText = NextStageSummary(project, inspection);
            if (!projectRows.TryGetValue(project.Id, out var ui)) continue;
            ui.Name.Text = project.Name; ui.Status.Text = project.StatusText;
            ui.Name.Foreground = primaryTextBrush; ui.Status.Foreground = mutedTextBrush;
            ui.Spinner.IsActive = project.IsRunning;
            ui.Spinner.Visibility = project.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    ProjectRowUi AddProjectListRow(ProjectRecord project)
    {
        var ui = new ProjectRowUi(project, SelectProjectFromContext, RenameProjectFromContext, DuplicateProject, RemoveProject, MoveProjectToFolder, registry.Folders, project.FolderId != null);
        ui.Root.Tapped += (_, _) => SelectProjectFromContext(project);
        ui.Root.CanDrag = true;
        ui.Root.AllowDrop = true;
        ui.Root.DragStarting += ProjectDragStarting;
        ui.Root.DragOver += ProjectFolderDragOver;
        ui.Root.Drop += async (_, args) =>
        {
            if (!args.DataView.Contains(StandardDataFormats.Text)) return;
            var text = await args.DataView.GetTextAsync();
            if (Guid.TryParse(text, out var id) && id != project.Id && projects.FirstOrDefault(item => item.Id == id) is ProjectRecord moving)
                MoveProjectToFolder(moving, project.FolderId);
        };
        projectRows[project.Id] = ui;
        return ui;
    }

    void ToggleProjectFolder(ProjectFolder folder) { folderNameClickTimer?.Stop(); folderNameClickTimer = null; folder.IsExpanded = !folder.IsExpanded; Persist(); RefreshProjectList(); }

    Grid BuildProjectFolderRow(ProjectFolder folder)
    {
        var row = new Grid { Height = 34, Margin = new Thickness(2, 4, 2, 4), Tag = folder, Background = new SolidColorBrush(Colors.Transparent), AllowDrop = true };
        row.DragOver += ProjectFolderDragOver;
        row.Drop += ProjectFolderDrop;
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        // Native Fluent chevrons, as used by WinUI expanders, rather than text
        // characters whose baseline and weight depend on the content font.
        var toggle = new Button { Content = new FontIcon { FontFamily = new FontFamily("Segoe Fluent Icons"), Glyph = folder.IsExpanded ? "\uE70D" : "\uE76C", FontSize = 12 },
            Width = 28, Height = 28, MinWidth = 0, MinHeight = 0, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Tag = folder };
        AutomationProperties.SetName(toggle, (folder.IsExpanded ? "Collapse " : "Expand ") + folder.Name);
        ToolTipService.SetToolTip(toggle, folder.IsExpanded ? "Collapse folder" : "Expand folder");
        toggle.Click += (_, _) => ToggleProjectFolder(folder);
        row.Tapped += (_, args) =>
        {
            for (DependencyObject? item = args.OriginalSource as DependencyObject; item != null && !ReferenceEquals(item, row); item = VisualTreeHelper.GetParent(item))
                if (item is Button or TextBox) return;
            ToggleProjectFolder(folder); args.Handled = true;
        };
        row.Children.Add(toggle);
        var title = new TextBlock { Text = folder.Name, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(5, 0, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(title, 1);
        row.Children.Add(title);
        title.Tapped += (_, args) => { DeferFolderNameClick(folder); args.Handled = true; };
        title.DoubleTapped += (_, args) => { BeginFolderNameEdit(folder); args.Handled = true; };
        row.KeyDown += (_, args) => { if (args.Key == VirtualKey.F2 && editingProjectFolder == null) { BeginFolderNameEdit(folder); args.Handled = true; } };
        var menu = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = "Rename Folder" };
        rename.Click += (_, _) => BeginFolderNameEdit(folder);
        var remove = new MenuFlyoutItem { Text = "Remove Folder" };
        remove.Click += (_, _) => RemoveProjectFolder(folder);
        menu.Items.Add(rename);
        menu.Items.Add(remove);
        row.ContextFlyout = menu;
        return row;
    }

    void LoadSelectedProjectLog()
    {
        logText.Text = selectedProject != null && projectLogs.TryGetValue(selectedProject.Id, out var value) ? value : "";
        if (selectedProject is { } project && (!technicalLogPaths.TryGetValue(project.Id, out var path) || !File.Exists(path)) && LatestTechnicalLogPath(project) is string latest)
            technicalLogPaths[project.Id] = latest;
        RefreshTechnicalLogButton();
        RestoreLogScroll(0, true);
    }

    void RefreshTechnicalLogButton()
    {
        if (technicalLogButton == null) return;
        technicalLogButton.IsEnabled = selectedProject != null
            && technicalLogPaths.TryGetValue(selectedProject.Id, out var path)
            && File.Exists(path);
    }

    void OpenTechnicalLogClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null || !technicalLogPaths.TryGetValue(selectedProject.Id, out var path) || !File.Exists(path)) return;
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception error) { AppendLog("Could not open the technical log: " + error.Message, selectedProject.Id); }
    }

    void RefreshModelOptions()
    {
        modelPicker.Items.Clear();
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        foreach (var path in Directory.Exists(resources) ? Directory.GetFiles(resources, "*.yaml").OrderBy(NaturalModelSortKey, StringComparer.OrdinalIgnoreCase) : Enumerable.Empty<string>())
            modelPicker.Items.Add(Path.GetFileNameWithoutExtension(path));
    }

    static string NaturalModelSortKey(string path) => Regex.Replace(Path.GetFileNameWithoutExtension(path), "\\d+", match => match.Value.PadLeft(12, '0'), RegexOptions.CultureInvariant);

    void SelectModel(ProjectRecord? project)
    {
        if (project == null || modelPicker.Items.Count == 0)
            return;
        var name = ModelName(project.Settings.Inference.ModelConfig);
        modelPicker.SelectedItem = modelPicker.Items.Cast<object>().FirstOrDefault(x => string.Equals(x.ToString(), name, StringComparison.OrdinalIgnoreCase)) ?? modelPicker.Items[0];
    }

    string ModelName(string path) => Path.GetFileNameWithoutExtension(path);

    void ModelSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || selectedProject == null || modelPicker.SelectedItem is not string name)
            return;
        _ = ObserveUiTaskAsync(HandleSettingChangeAsync("inference.model"), "Change model", selectedProject);
    }

    void CreateProjectClicked(object sender, RoutedEventArgs e) => CreateProject();
    void CreateProjectFolderClicked(object sender, RoutedEventArgs e) => BeginFolderNameEdit();
    void ImportProjectClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ImportProjectAsync(), "Import project", selectedProject);
    void DuplicateProjectClicked(object sender, RoutedEventArgs e) => DuplicateProject();
    void RemoveProjectClicked(object sender, RoutedEventArgs e) => RemoveProject();
    void StageButtonClicked(object sender, RoutedEventArgs e) { if (sender is Button button && button.Tag is Stage stage) RunOrStop(stage); }

    void RemoveProjectFolder(ProjectFolder folder)
    {
        foreach (var project in projects.Where(p => p.FolderId == folder.Id)) project.FolderId = null;
        registry.Folders.RemoveAll(f => f.Id == folder.Id);
        Persist();
        RefreshProjectList();
    }

    void MoveProjectToFolder(ProjectRecord project, Guid? folderId)
    {
        if (folderId != null && registry.Folders.All(folder => folder.Id != folderId)) return;
        project.FolderId = folderId;
        if (folderId is Guid id)
        {
            var folder = registry.Folders.FirstOrDefault(item => item.Id == id);
            if (folder != null) folder.IsExpanded = true;
        }
        Persist();
        RefreshProjectList();
    }

    void ProjectDragStarting(UIElement sender, DragStartingEventArgs args)
    {
        if (sender is FrameworkElement { Tag: ProjectRecord project })
        {
            args.Data.SetText(project.Id.ToString());
            args.AllowedOperations = DataPackageOperation.Move;
        }
    }

    void ProjectFolderDragOver(object sender, DragEventArgs args) => args.AcceptedOperation = DataPackageOperation.Move;

    async void ProjectFolderDrop(object sender, DragEventArgs args)
    {
        if (sender is not FrameworkElement { Tag: ProjectFolder folder } || !args.DataView.Contains(StandardDataFormats.Text)) return;
        var text = await args.DataView.GetTextAsync();
        if (Guid.TryParse(text, out var id) && projects.FirstOrDefault(project => project.Id == id) is ProjectRecord project)
            MoveProjectToFolder(project, folder.Id);
    }

    void BeginScanAlignmentClicked(object sender, RoutedEventArgs e)
    {
        var project = selectedProject;
        if (project == null) return;
        if (ProjectBusy(project.Id))
        {
            AppendLog("Wait for the running project stage to finish before aligning its scan.", project.Id);
            return;
        }
        var source = !string.IsNullOrWhiteSpace(project.Settings.ScanPreparation.OriginalScanPath)
            ? project.Settings.ScanPreparation.OriginalScanPath : project.Settings.ScanPreparation.ScanPath;
        if (string.IsNullOrWhiteSpace(source) || !File.Exists(source))
        {
            AppendLog("Choose a full-head scan before aligning it.", project.Id);
            return;
        }
        if (string.IsNullOrWhiteSpace(project.SaveLocation))
        {
            AppendLog("Choose a save location before saving the aligned scan.", project.Id);
            return;
        }
        ResetScanAlignmentPicks();
        alignmentSessionProject = project.Id;
        if (placementSide != null) EndPlacement();
        prepareLeftEarBox.IsChecked = project.Settings.ScanPreparation.PrepareLeft;
        prepareRightEarBox.IsChecked = project.Settings.ScanPreparation.PrepareRight;
        scanAlignmentMode = true;
        alignScanButton.IsEnabled = false;
        scanAlignmentStatus.Text = "Click nose tip, then left and right ear-canal entrances";
        scanAlignmentBorder.Visibility = Visibility.Visible;
        OpenArtifact(new Artifact("Full-head scan alignment", source));
    }

    void EndScanAlignment()
    {
        if (alignmentSaving) return;
        alignmentSessionProject = null;
        scanAlignmentMode = false;
        ClearAlignmentPreview();
        meshViewport.ShowCoordinateSystem = false;
        ResetScanAlignmentPicks();
        scanAlignmentBorder.Visibility = Visibility.Collapsed;
        alignScanButton.IsEnabled = true;
    }

    void ResetScanAlignmentPicks()
    {
        if (alignmentSaving) return;
        ClearAlignmentPreview();
        if (meshViewport.Items != null)
            foreach (var marker in scanAlignmentMarkerVisuals) meshViewport.Items.Remove(marker);
        foreach (var marker in scanAlignmentMarkerVisuals) meshVisuals.Remove(marker);
        scanAlignmentMarkerVisuals.Clear();
        scanAlignmentLandmarks.Clear();
        applyScanAlignmentButton.IsEnabled = false;
        scanAlignmentStatus.Text = "Click nose tip, then left and right ear-canal entrances";
    }

    Task ApplyScanAlignmentAsync() => PreviewOrSaveAlignmentAsync();

    async Task ImportProjectAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
            await ImportProjectFolderAsync(folder.Path);
    }

    async Task ImportProjectFolderAsync(string folder)
    {
        if (projectsBeingRemoved.Count != 0) throw new IOException("Wait for project removal before importing another folder.");
        if (ExistingProjectRoot(folder) is { } existing) { SelectProjectFromContext(existing); return; }
        var project = NewProject(projects.Count + 1);
        project.Name = Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        project.SaveLocation = folder;
        project.InputHandling = InputHandling.Reference; project.FolderProvenance = "Imported";
        project.LeftEar = ImportedMesh(folder, "Left");
        project.RightEar = ImportedMesh(folder, "Right");
        project.Settings.Inference.UsePredictionsForPreprocessing = false;
        try { await TryReadProjectSettingsAsync(project); }
        catch (Exception error)
        {
            AppendLog("Could not import project settings: " + error.Message);
            return;
        }
        try
        {
            await Task.Run(() => {
                using var fresh = FileFingerprints.Fresh();
                InvalidateManualPositions(project);
                var receipt = Path.Combine(project.SaveLocation, WindowsPreprocessingReceipt);
                if (PreprocessingFilesPresent(project) && !File.Exists(receipt))
                    HeadGeometry.AtomicWrite(receipt, PreprocessingStamp(project));
            });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            AppendLog("Could not validate existing preprocessing during import: " + error.Message, project.Id);
        }
        if (ExistingProjectRoot(folder) is { } duplicate) { SelectProjectFromContext(duplicate); return; }
        if (shutdownCleanupDone || projectsBeingRemoved.Count != 0) return;
        projects.Add(project);
        failedStages[project.Id] = [];
        selectedProject = project;
        Persist();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
        AppendLog("Imported project.", project.Id);
    }

    async Task TryReadProjectSettingsAsync(ProjectRecord project)
    {
        var path = Path.Combine(project.SaveLocation, "Project Settings.yaml");
        if (!File.Exists(path)) return;
        var result = await RequestPythonAsync("HRTFCalculation.DesktopBridge", new { action = "load", path, folder = project.SaveLocation });
        if (result.TryGetProperty("warnings", out var notices))
            foreach (var notice in notices.EnumerateArray()) AppendLog(notice.GetString(), project.Id);
        var root = System.Text.Json.Nodes.JsonNode.Parse(result.GetProperty("config").GetRawText())!.AsObject();
        ProjectDocument.Restore(project, root);
        NormalizeInferenceModelPaths(project);
        foreach (var side in new[] { "left", "right" })
        {
            if (root["preprocessing"]?["source_position_input_" + side] is not System.Text.Json.Nodes.JsonArray a || a.Count != 3) continue;
            var mesh = PreprocessingMesh(project, side);
            if (mesh == null) continue;
            var pos = new ManualMicrophonePosition { X = a[0]!.GetValue<double>(), Y = a[1]!.GetValue<double>(), Z = a[2]!.GetValue<double>(), MeshPath = mesh, MeshIdentity = MeshIdentity(mesh) };
            if (side == "left") project.Settings.Preprocessing.SourcePositionInputLeft = pos; else project.Settings.Preprocessing.SourcePositionInputRight = pos;
        }
    }

    string ImportedMesh(string folder, string side)
    {
        var candidates = new[] { Path.Combine(folder, "Input", side), Path.Combine(folder, "Intermediates", side), Path.Combine(folder, $"Target STL {side}"), Path.Combine(folder, $"Prediction STL {side}"), folder };
        foreach (var candidate in candidates)
        {
            if (Directory.Exists(candidate))
            {
                var file = Directory.EnumerateFiles(candidate).Where(IsMesh).OrderBy(x => x).FirstOrDefault();
                if (file != null)
                    return file;
            }
        }
        return "";
    }

    void CreateProject()
    {
        var project = NewProject(projects.Count + 1);
        projects.Add(project);
        failedStages[project.Id] = [];
        selectedProject = project;
        Persist();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
    }

    void DuplicateProject() => _ = ObserveUiTaskAsync(DuplicateProjectV2Async(), "Duplicate project", selectedProject);

    ProjectRecord NewProject(int index)
    {
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        return new ProjectRecord { Name = "Project " + index, Settings = new ProjectSettings { Inference = new InferenceSettings { ModelConfig = Path.Combine(resources, "Local 3 Views.yaml"), ModelCheckpoint = Path.Combine(resources, "Local 3 Views.pth") } } };
    }

    async void RemoveProject()
    {
        if (selectedProject is not { } project || !projectsBeingRemoved.Add(project.Id)) return;
        try
        {
            if (ProjectBusy(project.Id) || outputScans.Contains(project.Id))
            {
                await ShowProjectRemovalErrorAsync("Wait for the project task and output checks to finish before removing this project.");
                return;
            }

            using var reservation = projectOperations.TryReserve(project.Id);
            if (reservation == null) return;
            var snapshot = projects.Select(Clone).ToArray();
            var initial = Clone(project);
            var plan = await Task.Run(() => PlanRemoval(initial, snapshot));
            var confirmation = new ContentDialog
            {
                Title = $"Remove {project.Name}?",
                Content = $"Save location: {project.SaveLocation}\n\n{plan.Reason}",
                PrimaryButtonText = "Remove from list",
                SecondaryButtonText = plan.CanRecycle ? "Recycle folder" : "",
                CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            var choice = await ShowDialogAsync(confirmation);
            if (choice == ContentDialogResult.None || !projects.Contains(project) || shutdownCleanupDone) return;
            if (choice == ContentDialogResult.Secondary)
            {
                var roots = projects.Select(Clone).ToArray(); var frozen = Clone(project);
                var rechecked = await Task.Run(() => PlanRemoval(frozen, roots));
                if (!rechecked.CanRecycle || rechecked.Root != plan.Root || rechecked.Identity != plan.Identity)
                    throw new IOException("The folder changed after confirmation. Remove it from the list instead.");
                await ShellRecycle.RecycleAsync(plan.Root!, () =>
                {
                    var current = PlanRemoval(frozen, roots);
                    return current.CanRecycle && current.Identity == plan.Identity && current.Root == plan.Root;
                }, WinRT.Interop.WindowNative.GetWindowHandle(this));
            }

            projectLogs.Remove(project.Id);
            legacyProjectLogs.Remove(project.Id);
            technicalLogPaths.Remove(project.Id);
            projectLogKeyIndices.Remove(project.Id);
            viewerStates.Remove(project.Id);
            failedStages.Remove(project.Id);
            queuedStages.Remove(project.Id);
            knownOutputs.Remove(project.Id);
            lastOutputScan.Remove(project.Id);
            projects.Remove(project);
            SaveProjectLogs();
            selectedProject = projects.FirstOrDefault();
            if (selectedProject == null) CreateProject();
            else
            {
                Persist();
                RefreshProjectList();
                LoadSelectedProject();
                RefreshArtifacts();
            }
        }
        catch (Exception error) { AppendLog("Project removal failed: " + error, project.Id); await ShowProjectRemovalErrorAsync(error.Message); }
        finally { projectsBeingRemoved.Remove(project.Id); }
    }

    async Task ShowProjectRemovalErrorAsync(string message)
    {
        var dialog = new ContentDialog
        {
            Title = "Could not remove project",
            Content = message,
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Root.XamlRoot
        };
        await ShowDialogAsync(dialog);
    }

    void BrowseLeftEarClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ChoosePathAsync(leftEarBox, false), "Choose location", selectedProject);
    void BrowseRightEarClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ChoosePathAsync(rightEarBox, false), "Choose location", selectedProject);
    void BrowseScanClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ChoosePathAsync(scanPathBox, false), "Choose location", selectedProject);
    void BrowseSaveLocationClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ChoosePathAsync(saveLocationBox, true), "Choose location", selectedProject);
    void BrowseEvaluationGridClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ChoosePathAsync(evaluationGridBox, true), "Choose location", selectedProject);

    static string? ExistingPickerFolder(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var full = Path.GetFullPath(path.Trim());
            var candidate = Directory.Exists(full) ? full : Path.GetDirectoryName(full);
            while (!string.IsNullOrWhiteSpace(candidate) && !Directory.Exists(candidate))
                candidate = Path.GetDirectoryName(candidate);
            return candidate;
        }
        catch { return null; }
    }

    static void ConfigurePickerStart(object picker, string? currentPath)
    {
        var folder = ExistingPickerFolder(currentPath);
        if (picker is FileOpenPicker filePicker)
        {
            filePicker.SuggestedStartLocation = PickerLocationId.ComputerFolder;
            if (folder != null) filePicker.SettingsIdentifier = "Pinna2HRTF:" + folder;
        }
        else if (picker is FolderPicker folderPicker)
        {
            folderPicker.SuggestedStartLocation = PickerLocationId.ComputerFolder;
            if (folder != null) folderPicker.SettingsIdentifier = "Pinna2HRTF:" + folder;
        }
    }

    async Task ChoosePathAsync(TextBox box, bool folder)
    {
        var project = selectedProject; var previous = box.Text;
        var path = folder ? await PickFolderAsync(previous) : await PickFileAsync(previous);
        if (path != null && selectedProject == project && box.Text == previous && !shutdownCleanupDone && (project == null || !ProjectBusy(project.Id))) box.Text = path;
    }

    async Task<string?> PickFileAsync(string? currentPath = null)
    {
        var native = NativeFileDialog.Pick(WindowNative.GetWindowHandle(this), ExistingPickerFolder(currentPath), false);
        if (native != null) return native.Length == 0 ? null : native;
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        ConfigurePickerStart(picker, currentPath);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    async Task<string?> PickFolderAsync(string? currentPath = null)
    {
        var native = NativeFileDialog.Pick(WindowNative.GetWindowHandle(this), ExistingPickerFolder(currentPath), true);
        if (native != null) return native.Length == 0 ? null : native;
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        ConfigurePickerStart(picker, currentPath);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    void RefreshArtifacts()
    {
        RefreshGeometry();
        if (placementSide != null) return;
        if (selectedProject == null)
        {
            artifacts.Clear();
            ResetViewer();
            return;
        }
        var inspection = new ArtifactInspection();
        var selectedPath = viewerStates.TryGetValue(selectedProject.Id, out var state) ? state.SelectedArtifactPath : null;
        refreshingArtifacts = true;
        artifacts.Clear();
        foreach (var artifact in ArtifactsFor(selectedProject, inspection).Where(x => x.Exists))
            artifacts.Add(artifact);
        artifactPicker.SelectedItem = artifacts.FirstOrDefault(x => x.Path == selectedPath) ?? artifacts.FirstOrDefault();
        refreshingArtifacts = false;
        if (artifactPicker.SelectedItem is Artifact selected)
            OpenArtifact(selected);
        else
            ResetViewer();
        RefreshProjectList(inspection);
    }

    List<Artifact> ArtifactsFor(ProjectRecord project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        var list = new List<Artifact>();
        var hrtf = SofaDirectory(project);
        if (project.Settings.ScanPreparation.Enabled && ScanPreparationOutputsCurrent(project, inspection))
        {
            foreach (var (side, selected, reviewed) in new[]
            {
                ("left", project.Settings.ScanPreparation.PrepareLeft, project.Settings.ScanPreparation.ReviewedLeft),
                ("right", project.Settings.ScanPreparation.PrepareRight, project.Settings.ScanPreparation.ReviewedRight)
            })
            {
                if (!selected) continue;
                var prepared = Path.Combine(project.SaveLocation, "Prepared", side == "left" ? "Left.stl" : "Right.stl");
                var useReviewed = EarReviewIsCurrent(project, side, inspection) && !string.IsNullOrWhiteSpace(reviewed);
                list.Add(new Artifact(useReviewed ? $"Reviewed {side} ear" : $"Prepared {side} ear", useReviewed ? reviewed! : prepared, side));
            }
        }
        if (!project.Settings.ScanPreparation.Enabled)
            foreach (var side in WorkflowSides(project))
                if (EarReviewIsCurrent(project, side, inspection) && SourceEar(project, side, inspection) is string edited)
                    list.Add(new Artifact($"Edited {side} ear", edited, side));
        if (!string.IsNullOrWhiteSpace(project.LeftEar))
        {
            list.Add(new Artifact("Input left ear", project.LeftEar, "left"));
            list.Add(new Artifact("Left simulation mesh", Path.Combine(project.SaveLocation, "Intermediates", "Left", "graded_head.ply"), "left"));
        }
        if (!string.IsNullOrWhiteSpace(project.RightEar))
        {
            list.Add(new Artifact("Input right ear", project.RightEar, "right"));
            list.Add(new Artifact("Right simulation mesh", Path.Combine(project.SaveLocation, "Intermediates", "Right", "graded_head.ply"), "right"));
        }
        foreach (var side in new[] { "left", "right" })
            if (PredictionMesh(project, side) is string prediction)
                list.Add(new Artifact($"Predicted {side} ear", prediction, side));
        if (Directory.Exists(hrtf))
            foreach (var file in Directory.EnumerateFiles(hrtf)
                .Where(x => new[] { ".jpg", ".jpeg", ".png" }.Contains(Path.GetExtension(x).ToLowerInvariant()))
                .OrderBy(x => PlotOrder(x))
                .ThenBy(x => x, StringComparer.OrdinalIgnoreCase))
                list.Add(new Artifact(PlotTitle(file), file));
        foreach (var side in new[] { "left", "right" })
        {
            if (project.Settings.ManualPPM.For(side) is { } fit && File.Exists(fit.Mesh)) list.Add(new Artifact($"Manual {side} PPM",fit.Mesh,side));
            if (SourceEar(project,side,inspection) != null) list.Add(new Artifact($"{side} simulation mesh",Path.Combine(project.SaveLocation,"Intermediates",side=="left"?"Left":"Right","graded_head.ply"),side));
            var solver=Path.Combine(project.SaveLocation,"Projects",side=="left"?"Left":"Right","NumCalc");
            if(Directory.Exists(solver)) foreach(var source in Directory.GetDirectories(solver,"source_*").OrderBy(x=>x))
                if(File.Exists(Path.Combine(source,"NC.inp"))&&Directory.Exists(Path.Combine(source,"be.out")))list.Add(new Artifact($"{side} pressure · Source {Path.GetFileName(source)[7..]}",Path.Combine(source,"NC.inp"),side));
        }
        return list.DistinctBy(x => Path.GetFullPath(x.Path), StringComparer.OrdinalIgnoreCase).ToList();
    }

    static int PlotOrder(string path)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        if (name.Contains("horizontal", StringComparison.OrdinalIgnoreCase)) return 0;
        if (name.Contains("median", StringComparison.OrdinalIgnoreCase)) return 1;
        return 2;
    }

    static string PlotTitle(string path)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        if (name.Contains("horizontal", StringComparison.OrdinalIgnoreCase)) return "Horizontal HRTF plot";
        if (name.Contains("median", StringComparison.OrdinalIgnoreCase)) return "Median HRTF plot";
        return name;
    }

    void ArtifactSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!refreshingArtifacts && placementSide == null && artifactPicker.SelectedItem is Artifact artifact)
            OpenArtifact(artifact);
    }

    void OpenArtifact(Artifact artifact)
    {
        if (artifact.IsPressure)
        {
            if (selectedArtifactPath != artifact.Path) { selectedArtifactPath = artifact.Path; RememberSelectedArtifact(artifact.Path); _ = ObserveUiTaskAsync(OpenPressureViewerAsync(artifact), "Pressure viewer", selectedProject); }
            return;
        }
        if (currentMesh != null && selectedArtifactPath != null &&
            SamePath(currentMesh.Path, selectedArtifactPath))
            SaveMeshCamera();
        ResetViewer();
        selectedArtifactPath = artifact.Path;
        selectedArtifactSide = ArtifactSide(artifact);
        RememberSelectedArtifact(artifact.Path);
        selectedArtifactText.Text = Path.GetFileName(artifact.Path);
        UpdatePlacementButtons();
        if (artifact.IsImage)
        {
            try { imagePreview.Source = new BitmapImage(new Uri(artifact.Path)); imagePreview.Visibility = Visibility.Visible; viewerPlaceholder.Visibility = Visibility.Collapsed; }
            catch (Exception error) { AppendLog("Cannot open image: " + error.Message); }
            return;
        }
        if (artifact.IsMesh)
        {
            _ = ObserveUiTaskAsync(OpenMeshAsync(artifact), "Mesh viewer", selectedProject);
            return;
        }
        viewerPlaceholder.Text = artifact.IsText ? SafeReadText(artifact.Path) : "Preview unavailable for " + Path.GetFileName(artifact.Path);
        viewerPlaceholder.Visibility = Visibility.Visible;
    }

    async Task OpenMeshAsync(Artifact artifact)
    {
        meshLoadCancellation?.Cancel();
        meshLoadCancellation?.Dispose();
        meshLoadCancellation = new CancellationTokenSource();
        var cancellation = meshLoadCancellation.Token;
        var generation = ++meshLoadGeneration;
        RemoveMeshVisuals();
        try
        {
            var loaded = await Task.Run(() => MeshLoader.Load(artifact.Path), cancellation);
            cancellation.ThrowIfCancellationRequested();
            if (generation != meshLoadGeneration || !string.Equals(selectedArtifactPath, artifact.Path, StringComparison.OrdinalIgnoreCase)) return;
            for (var attempt = 0; attempt < 40 && (!viewportReady || meshViewport.RenderHost == null); attempt++)
                await Task.Delay(25);
            cancellation.ThrowIfCancellationRequested();
            if (generation != meshLoadGeneration || !SamePath(selectedArtifactPath, artifact.Path)) return;
            if (!viewportReady || meshViewport.RenderHost == null || meshViewport.Items == null)
                throw new InvalidOperationException("The 3D viewport render host is not ready yet.");
            currentMesh = loaded;
            UpdateAlignmentAxes();
            meshVisual = new MeshGeometryModel3D { Geometry = currentMesh.Geometry, Material = new PhongMaterial { AmbientColor = new Color4(0.18f, 0.22f, 0.22f, 1), DiffuseColor = new Color4(0.48f, 0.68f, 0.66f, 1), EmissiveColor = new Color4(0.035f, 0.045f, 0.045f, 1), SpecularColor = new Color4(0.12f, 0.14f, 0.14f, 1), SpecularShininess = 12 }, CullMode = SharpDX.Direct3D11.CullMode.None };
            meshVisual.RenderWireframe = string.Equals(Path.GetExtension(artifact.Path), ".ply", StringComparison.OrdinalIgnoreCase);
            meshVisual.WireframeColor = ColorHelper.FromArgb(65, 31, 56, 56);
            meshViewport.Items.Add(meshVisual);
            meshVisuals.Add(meshVisual);
            AddMicrophoneMarker(artifact.Path);
            var hasSavedCamera = HasSavedMeshCamera();
            ResetMeshCamera();
            if (!hasSavedCamera)
            {
                var isStl = string.Equals(Path.GetExtension(artifact.Path), ".stl", StringComparison.OrdinalIgnoreCase);
                meshViewport.Camera?.ZoomExtents(meshViewport, isStl ? 0 : 80);
                if (isStl) ZoomOutMeshCamera(2.8);
            }
            viewerPlaceholder.Visibility = Visibility.Collapsed;
            viewerInteractionHint.Visibility = Visibility.Visible;
            resetViewButtonHost.Visibility = Visibility.Visible;
            meshViewport.Visibility = Visibility.Visible;
            UpdatePlacementButtons();
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            currentMesh = null;
            viewerInteractionHint.Visibility = Visibility.Collapsed;
            resetViewButtonHost.Visibility = Visibility.Collapsed;
            viewerPlaceholder.Text = "Could not open mesh";
            viewerPlaceholder.Visibility = Visibility.Visible;
            AppendLog("Cannot open mesh: " + error, selectedProject?.Id);
        }
    }

    string SafeReadText(string path)
    {
        try { return File.ReadAllText(path); } catch (Exception error) { return "Could not preview file: " + error.Message; }
    }

    void AddMicrophoneMarker(string meshPath)
    {
        var position = MicrophonePosition(meshPath);
        if (position == null || currentMesh == null)
            return;
        var p = currentMesh.ToDisplay(position.Value);
        microphoneVisual = new MeshGeometryModel3D { Geometry = MeshLoader.CreateSphere(p, MicrophoneMarkerDisplayRadius()), Material = new PhongMaterial { DiffuseColor = new Color4(1f, 0.58f, 0f, 1), EmissiveColor = new Color4(0.35f, 0.12f, 0f, 1) }, IsHitTestVisible = false };
        meshViewport.Items.Add(microphoneVisual);
    }

    double MicrophoneMarkerDisplayRadius()
    {
        return MicrophoneMarkerRadiusMeshUnits * (currentMesh?.Scale ?? 1.0);
    }

    void ResetViewer()
    {
        meshLoadCancellation?.Cancel();
        meshLoadGeneration++;
        RemoveMeshVisuals();
        meshVisual = null;
        microphoneVisual = null;
        currentMesh = null;
        imagePreview.Source = null;
        imagePreview.Visibility = Visibility.Collapsed;
        viewerInteractionHint.Visibility = Visibility.Collapsed;
        resetViewButtonHost.Visibility = Visibility.Collapsed;
        meshViewport.Visibility = Visibility.Visible;
        viewerPlaceholder.Text = "No preview selected";
        viewerPlaceholder.Visibility = Visibility.Visible;
        selectedArtifactText.Text = "Select a file to preview";
        selectedArtifactPath = null;
        selectedArtifactSide = null;
        placeLeftButton.IsEnabled = false;
        placeRightButton.IsEnabled = false;
    }

    void RemoveMeshVisuals()
    {
        if (meshViewport.Items != null)
        {
            foreach (var visual in meshVisuals.ToList()) meshViewport.Items.Remove(visual);
            if (meshVisual != null) meshViewport.Items.Remove(meshVisual);
            if (microphoneVisual != null) meshViewport.Items.Remove(microphoneVisual);
        }
        meshVisuals.Clear();
        meshVisual = null;
        microphoneVisual = null;
    }

    void MeshViewportPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (meshVisual == null || currentMesh == null || activeMeshPointerId != uint.MaxValue)
            return;
        var point = e.GetCurrentPoint(meshViewport);
        var properties = point.Properties;
        meshPointerIsPrimary = properties.IsLeftButtonPressed;
        var action = NavigationBindings.Mouse(properties.IsMiddleButtonPressed, properties.IsRightButtonPressed,
            (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0,
            (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0);
        meshPointerMode = properties.IsLeftButtonPressed || action is NavigationAction.Orbit or NavigationAction.Zoom ? MeshPointerMode.Rotate : action == NavigationAction.Pan ? MeshPointerMode.Pan : MeshPointerMode.None;
        if (meshPointerMode == MeshPointerMode.None)
            return;
        activeMeshPointerId = point.PointerId;
        lastPointer = point.Position;
        pointerMoved = false;
        rotatingMesh = meshPointerMode == MeshPointerMode.Rotate;
        meshViewportHost?.SetCursor(meshPointerMode == MeshPointerMode.Rotate ? InputSystemCursorShape.Hand : InputSystemCursorShape.SizeAll);
    }

    void MeshViewportPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (meshPointerMode == MeshPointerMode.None || e.GetCurrentPoint(meshViewport).PointerId != activeMeshPointerId)
            return;
        var point = e.GetCurrentPoint(meshViewport).Position;
        if (Math.Abs(point.X - lastPointer.X) + Math.Abs(point.Y - lastPointer.Y) > 2)
            pointerMoved = true;
        lastPointer = point;
    }

    void MeshViewportPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(meshViewport);
        if (point.PointerId != activeMeshPointerId)
            return;
        var mode = meshPointerMode;
        var primaryClick = meshPointerIsPrimary;
        var wasClick = !pointerMoved;
        ResetMeshPointerState();
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, SaveMeshCamera);
        if (primaryClick && PlacementIsCurrent() && !calculatingAutomaticPosition && mode == MeshPointerMode.Rotate && wasClick && currentMesh != null && meshVisual != null)
        {
            var hit = meshViewport.FindHits(point.Position).FirstOrDefault(x => ReferenceEquals(x.ModelHit, meshVisual));
            if (hit != null)
            {
                var raw = currentMesh.ToRaw(hit.PointHit);
                pendingMicrophonePosition = new ManualMicrophonePosition { X = raw.X, Y = raw.Y, Z = raw.Z, MeshPath = currentMesh.Path, MeshIdentity = MeshIdentity(currentMesh.Path) };
                UpdateMicrophoneMarker(raw);
                placementCoordinates.Text = $"{placementSide} mic: {raw.X:0.##}, {raw.Y:0.##}, {raw.Z:0.##} mm";
                donePositionButton.IsEnabled = true;
            }
            else
                AppendLog("Could not hit the active mesh at the selected position. Try clicking directly on the mesh surface.", selectedProject?.Id);
        }
        else if (primaryClick && scanAlignmentMode && mode == MeshPointerMode.Rotate && wasClick && currentMesh != null && meshVisual != null)
        {
            var hit = meshViewport.FindHits(point.Position).FirstOrDefault(x => ReferenceEquals(x.ModelHit, meshVisual));
            if (hit != null && scanAlignmentLandmarks.Count < 3)
            {
                var landmark = currentMesh.ToRaw(hit.PointHit);
                scanAlignmentLandmarks.Add(landmark);
                var markerColors = new[] { new Color4(1f, 0.2f, 0.2f, 1f), new Color4(0.2f, 0.45f, 1f, 1f), new Color4(0.2f, 0.9f, 0.35f, 1f) };
                var marker = new MeshGeometryModel3D
                {
                    Geometry = MeshLoader.CreateSphere(currentMesh.ToDisplay(landmark), currentMesh.MaximumDimension * 0.006),
                    Material = new PhongMaterial { DiffuseColor = markerColors[scanAlignmentLandmarks.Count - 1], EmissiveColor = markerColors[scanAlignmentLandmarks.Count - 1] },
                    IsHitTestVisible = false
                };
                meshViewport.Items.Add(marker);
                meshVisuals.Add(marker);
                scanAlignmentMarkerVisuals.Add(marker);
                var names = new[] { "nose tip", "left ear-canal entrance", "right ear-canal entrance" };
                scanAlignmentStatus.Text = scanAlignmentLandmarks.Count == 3
                    ? "Three landmarks picked. Apply the alignment or cancel."
                    : $"Picked {scanAlignmentLandmarks.Count}/3. Next: {names[scanAlignmentLandmarks.Count]}";
                UpdateAlignmentSaveEnabled();
            }
            else if (hit == null)
                AppendLog("Click directly on the scan surface to place each landmark.", selectedProject?.Id);
        }
    }

    void MeshViewportPointerCanceled(object sender, PointerRoutedEventArgs e) => ResetMeshPointerState();

    void MeshViewportPointerCaptureLost(object sender, PointerRoutedEventArgs e) => ResetMeshPointerState();

    void MeshViewportPointerWheelChanged(object sender, PointerRoutedEventArgs e) => DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, SaveMeshCamera);

    void ResetMeshPointerState()
    {
        meshPointerMode = MeshPointerMode.None;
        activeMeshPointerId = uint.MaxValue;
        rotatingMesh = false;
        pointerMoved = false;
        meshViewportHost?.SetCursor(InputSystemCursorShape.Arrow);
    }

    void UpdateMicrophoneMarker(System.Numerics.Vector3 raw)
    {
        if (currentMesh == null)
            return;
        if (microphoneVisual != null) meshViewport.Items.Remove(microphoneVisual);
        microphoneVisual = new MeshGeometryModel3D { Geometry = MeshLoader.CreateSphere(currentMesh.ToDisplay(raw), MicrophoneMarkerDisplayRadius()), Material = new PhongMaterial { DiffuseColor = new Color4(1f, 0.58f, 0f, 1), EmissiveColor = new Color4(0.35f, 0.12f, 0f, 1) }, IsHitTestVisible = false };
        meshViewport.Items.Add(microphoneVisual);
    }

    static Border MicButtonHost(Button button)
    {
        var host = new Border
        {
            Background = new SolidColorBrush(Colors.Transparent),
            Child = button,
            IsHitTestVisible = true
        };
        // Keep one stable tooltip instance. Replacing it while the status timer
        // refreshes the buttons makes WinUI close an otherwise valid hover.
        ToolTipService.SetToolTip(host, new ToolTip { Content = string.Empty });
        return host;
    }

    void UpdatePlacementButtons()
    {
        var mesh2PpmEnabled = selectedProject?.Settings.Inference.UsePredictionsForPreprocessing == true;
        foreach (var (side, button, host) in new[] { ("left", placeLeftButton, placeLeftButtonHost), ("right", placeRightButton, placeRightButtonHost) })
        {
            var available = selectedProject != null && PreprocessingMesh(selectedProject, side) != null;
            button.IsEnabled = !mesh2PpmEnabled && placementSide == null && available && selectedProject != null && !runs.ContainsKey(selectedProject.Id);
            var tooltipText = mesh2PpmEnabled ? "Automatic microphone placement is used for Mesh2PPM-inferred meshes." : available ? $"Place the {side} microphone on the mesh used for preprocessing." :
                selectedProject != null && InferenceIsAutomatic(selectedProject) ? $"Run Mesh2PPM Inference to create the predicted {side} ear first." : $"Select an input {side} ear first.";
            if (ToolTipService.GetToolTip(host) is ToolTip tooltip && !string.Equals(tooltip.Content as string, tooltipText, StringComparison.Ordinal))
                tooltip.Content = tooltipText;
        }
    }

    bool PlacementIsCurrent() => selectedProject != null && placementProjectId == selectedProject.Id &&
        placementSide != null && SamePath(placementMeshPath, currentMesh?.Path) &&
        SamePath(placementMeshPath, PreprocessingMesh(selectedProject, placementSide)) &&
        placementMeshIdentity == MeshIdentity(placementMeshPath!);

    void BeginPlacement(string side) => _ = ObserveUiTaskAsync(BeginPlacementAsync(side), "Place microphone", selectedProject);

    async Task BeginPlacementAsync(string side)
    {
        var project = selectedProject;
        if (project == null || placementSide != null || runs.ContainsKey(project.Id)) return;
        if (InferenceIsAutomatic(project))
        {
            AppendLog("Automatic microphone placement is used for Mesh2PPM-inferred meshes.", project.Id);
            UpdatePlacementButtons();
            return;
        }
        var mesh = PreprocessingMesh(project, side);
        if (mesh == null)
        {
            AppendLog(InferenceIsAutomatic(project) ? $"Run Mesh2PPM Inference before placing the {side} microphone." : $"The input {side} ear is not available.", project.Id);
            return;
        }
        placementSide = side;
        placementProjectId = project.Id;
        placementMeshPath = mesh;
        placementMeshIdentity = MeshIdentity(mesh);
        var session = placementCancellation = new CancellationTokenSource();
        pendingMicrophonePosition = ValidManualPosition(project, side) ? ManualPosition(project, side) : null;
        donePositionButton.IsEnabled = false;
        automaticPositionButton.IsEnabled = false;
        placementCoordinates.Text = "Opening microphone placement mesh…";
        placementBorder.Visibility = Visibility.Visible;
        artifactPicker.IsEnabled = false;
        RefreshPipelineStatus();
        var artifact = artifacts.FirstOrDefault(x => SamePath(x.Path, mesh)) ??
            new Artifact(InferenceIsAutomatic(project) ? $"Predicted {side} ear" : $"Input {side} ear", mesh, side);
        artifactPicker.SelectedItem = artifact;
        RememberSelectedArtifact(mesh);
        if (!SamePath(currentMesh?.Path, mesh))
        {
            ResetViewer();
            selectedArtifactPath = artifact.Path;
            selectedArtifactSide = side;
            selectedArtifactText.Text = Path.GetFileName(artifact.Path);
            await OpenMeshAsync(artifact);
        }
        if (!ReferenceEquals(session, placementCancellation)) return;
        if (!PlacementIsCurrent()) { EndPlacement(); return; }
        automaticPositionButton.IsEnabled = true;
        donePositionButton.IsEnabled = pendingMicrophonePosition != null;
        placementCoordinates.Text = pendingMicrophonePosition == null ? "Click the mesh or calculate the automatic microphone position." : "Saved microphone position loaded. Click Done to keep it.";
        AppendLog($"{side} microphone placement uses {artifact.Title}. Click the mesh or calculate automatically, then press Done.", project.Id);
    }

    void AutomaticPositionClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(UseAutomaticPositionAsync(), "Automatic microphone", selectedProject);

    async Task UseAutomaticPositionAsync()
    {
        if (!PlacementIsCurrent() || calculatingAutomaticPosition || placementCancellation == null) return;
        var project = selectedProject!;
        var side = placementSide!;
        var mesh = placementMeshPath!;
        var session = placementCancellation;
        calculatingAutomaticPosition = true;
        automaticPositionButton.IsEnabled = false;
        donePositionButton.IsEnabled = false;
        placementCoordinates.Text = "Calculating automatic microphone position…";
        try
        {
            var position = await CalculateAutomaticPosition(mesh, side, session.Token);
            if (!ReferenceEquals(session, placementCancellation) || !PlacementIsCurrent()) return;
            pendingMicrophonePosition = new ManualMicrophonePosition { X = position.X, Y = position.Y, Z = position.Z, MeshPath = mesh, MeshIdentity = MeshIdentity(mesh) };
            UpdateMicrophoneMarker(position);
            placementCoordinates.Text = $"{side} mic: {position.X:0.##}, {position.Y:0.##}, {position.Z:0.##} mm — press Done to save.";
            donePositionButton.IsEnabled = true;
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            AppendLog("Automatic microphone position failed: " + error.Message, project.Id);
            if (ReferenceEquals(session, placementCancellation)) placementCoordinates.Text = "Calculation failed. Retry or click the mesh to choose a position.";
        }
        finally
        {
            if (ReferenceEquals(session, placementCancellation))
            {
                calculatingAutomaticPosition = false;
                automaticPositionButton.IsEnabled = PlacementIsCurrent();
                donePositionButton.IsEnabled = PlacementIsCurrent() && pendingMicrophonePosition != null;
            }
        }
    }

    async Task<System.Numerics.Vector3> CalculateAutomaticPosition(string mesh, string side, CancellationToken cancellation = default)
    {
        var landmark = Path.Combine(appData, "Cache", "automatic-landmark-" + Guid.NewGuid().ToString("N") + ".json");
        var executable = BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        var info = GeometryProcess("-m", "HRTFCalculation.Preprocessing.src.ear_canal_closer", "--ear_path", mesh,
            "--landmark_path", landmark, "--side", side, "--estimate-only");
        Directory.CreateDirectory(Path.GetDirectoryName(landmark)!);
        try
        {
            var result = await ToolProcess.RunAsync(info, null, TimeSpan.FromSeconds(600), cancellation, placementProjectId);
            var output = result.Output; var error = result.Error;
            if (result.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "Microphone estimation failed: " + output : error.Trim());
            using var document = JsonDocument.Parse(File.Exists(landmark) ? File.ReadAllText(landmark) : output);
            var values = document.RootElement.GetProperty("position").EnumerateArray().Select(x => (float)x.GetDouble()).ToArray();
            if (values.Length != 3 || values.Any(x => !float.IsFinite(x))) throw new InvalidDataException("The estimator returned an invalid position.");
            return new System.Numerics.Vector3(values[0], values[1], values[2]);
        }
        finally
        {

            if (File.Exists(landmark)) File.Delete(landmark);
        }
    }

    void DonePositionClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(DonePositionAsync(), "DonePosition", selectedProject);
    async Task DonePositionAsync()
    {
        if (!PlacementIsCurrent() || calculatingAutomaticPosition || pendingMicrophonePosition == null ||
            !PositionMatchesMesh(pendingMicrophonePosition, placementMeshPath))
            return;
        var project = selectedProject!;
        var side = placementSide!;
        var position = pendingMicrophonePosition;
        var placementEndedForReset = false;
        try { await ReconcileOutputsAsync(project, true); }
        catch { AppendLog("Could not inspect output ownership; microphone position was not changed.", project.Id); return; }
        if (!PlacementIsCurrent() || selectedProject != project) return;
        if (HasOutputsFrom(Stage.Preprocessing, project))
        {
            var dialog = new ContentDialog
            {
                Title = "Reset pipeline outputs?",
                Content = "Changing the microphone position resets preprocessing and later outputs. Input meshes and Mesh2PPM prediction outputs will be kept.",
                PrimaryButtonText = "Reset and save",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = Root.XamlRoot
            };
            if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;
            EndPlacement();
            placementEndedForReset = true;
            if (!await ResetProjectOutputsAsync(project, Stage.Preprocessing)) return;
        }
        if (side == "left") project.Settings.Preprocessing.SourcePositionInputLeft = position; else project.Settings.Preprocessing.SourcePositionInputRight = position;
        Persist();
        AppendLog($"Saved {side} microphone position.", project.Id);
        if (!placementEndedForReset) EndPlacement();
        RefreshArtifacts();
    }

    void CancelPositionClicked(object sender, RoutedEventArgs e) => EndPlacement();

    void EndPlacement()
    {
        placementCancellation?.Cancel();
        placementCancellation?.Dispose();
        placementCancellation = null;
        placementProjectId = null;
        placementMeshPath = null;
        placementMeshIdentity = null;
        calculatingAutomaticPosition = false;
        placementSide = null;
        pendingMicrophonePosition = null;
        donePositionButton.IsEnabled = false;
        placementBorder.Visibility = Visibility.Collapsed;
        artifactPicker.IsEnabled = true;
        if (microphoneVisual != null) meshViewport.Items.Remove(microphoneVisual);
        microphoneVisual = null;
        if (currentMesh != null) AddMicrophoneMarker(currentMesh.Path);
        UpdatePlacementButtons();
        RefreshPipelineStatus();
    }

    void ResetMeshCamera()
    {
        var state = selectedProject != null && selectedArtifactPath != null && viewerStates.TryGetValue(selectedProject.Id, out var projectState) && projectState.CameraByArtifact.TryGetValue(selectedArtifactPath, out var saved) ? saved : new MeshCameraState { Yaw = string.Equals(selectedArtifactSide ?? SideForPath(selectedArtifactPath ?? ""), "left", StringComparison.OrdinalIgnoreCase) ? 180 : 0, Pitch = 8, Distance = Math.Max(currentMesh?.MaximumDimension * 1.7 ?? 300, 120) };
        var camera = new PerspectiveCamera { FieldOfView = 38 };
        var yaw = state.Yaw * Math.PI / 180;
        var pitch = state.Pitch * Math.PI / 180;
        var horizontal = state.Distance * Math.Cos(pitch);
        var center = new System.Numerics.Vector3((float)state.TargetX,(float)state.TargetY,(float)state.TargetZ);
        var position = new System.Numerics.Vector3(center.X + (float)(horizontal * Math.Sin(yaw)), center.Y - (float)(horizontal * Math.Cos(yaw)), center.Z + (float)(state.Distance * Math.Sin(pitch)));
        camera.Position = position;
        camera.LookDirection = center - position;
        camera.UpDirection = new System.Numerics.Vector3(0, 0, 1);
        meshViewport.Camera = camera;
    }

    void ZoomOutMeshCamera(double factor)
    {
        if (meshViewport.Camera is not PerspectiveCamera camera || factor <= 1)
            return;
        var target = camera.Position + camera.LookDirection;
        var direction = camera.Position - target;
        if (direction.LengthSquared() < 1e-6f)
            return;
        camera.Position = target + direction * (float)factor;
        camera.LookDirection = target - camera.Position;
    }

    void ResetViewClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null || selectedArtifactPath == null || currentMesh == null || meshViewport.Items == null)
            return;
        if (viewerStates.TryGetValue(selectedProject.Id, out var state))
            state.CameraByArtifact.Remove(selectedArtifactPath);
        SaveViewerStates();
        ResetMeshCamera();
        var isStl = string.Equals(Path.GetExtension(selectedArtifactPath), ".stl", StringComparison.OrdinalIgnoreCase);
        meshViewport.Camera?.ZoomExtents(meshViewport, isStl ? 0 : 80);
        if (isStl) ZoomOutMeshCamera(2.8);
        SaveMeshCamera();
    }

    bool HasSavedMeshCamera() => selectedProject != null && selectedArtifactPath != null &&
        viewerStates.TryGetValue(selectedProject.Id, out var state) &&
        state.CameraByArtifact.ContainsKey(selectedArtifactPath);

    void SaveMeshCamera()
    {
        if (selectedProject == null || selectedArtifactPath == null || currentMesh == null || meshViewport.Camera is not PerspectiveCamera camera)
            return;
        var target = camera.Position + camera.LookDirection;
        var direction = camera.Position - target;
        if (!viewerStates.TryGetValue(selectedProject.Id, out var state)) viewerStates[selectedProject.Id] = state = new ProjectViewerState();
        state.CameraByArtifact[selectedArtifactPath] = new MeshCameraState { TargetX = target.X, TargetY = target.Y, TargetZ = target.Z, Distance = direction.Length(), Pitch = Math.Asin(direction.Z / Math.Max(direction.Length(), 1e-6f)) * 180 / Math.PI, Yaw = Math.Atan2(direction.X, -direction.Y) * 180 / Math.PI };
        SaveViewerStates();
    }

    void RememberSelectedArtifact(string path)
    {
        if (selectedProject == null)
            return;
        if (!viewerStates.TryGetValue(selectedProject.Id, out var state)) viewerStates[selectedProject.Id] = state = new ProjectViewerState();
        state.SelectedArtifactPath = path;
        SaveViewerStates();
    }

    void RunInferenceClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Inference);
    void RunPreprocessingClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Preprocessing);
    void RunNumCalcClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Numcalc);
    void RunPostprocessingClicked(object sender, RoutedEventArgs e) => RunOrStop(Stage.Postprocessing);
    void RunOrStop(Stage stage) { if (selectedProject != null && runs.TryGetValue(selectedProject.Id, out var active) && active.Stage == stage) StopProject(selectedProject); else RunStage(stage); }

    void RunNextClicked(object sender, RoutedEventArgs e) => PerformWorkflowAction();

    void RunAllClicked(object sender, RoutedEventArgs e) =>
        _ = ObserveUiTaskAsync(RunAllAsync(), "Run all", selectedProject);

    async Task RunAllAsync()
    {
        var project = selectedProject;
        if (project == null || ProjectBusy(project.Id)) return;
        var revision = StatusRevision(project);
        await RefreshStatusSnapshotAsync(project, true);
        if (shutdownCleanupDone || selectedProject != project || StatusRevision(project) != revision) return;
        var stages = AutomaticStages(project).Where(stage => !StageIsComplete(stage, project)).ToList();
        if (stages.Count == 0) { AppendLog("All stages complete.", project.Id); return; }
        queuedStages[project.Id] = new Queue<Stage>(stages.Skip(1));
        await RunStageAsync(stages[0], project, true);
    }

    void RunStage(Stage stage, ProjectRecord? targetProject = null, bool continueQueued = false) =>
        _ = ObserveUiTaskAsync(RunStageAsync(stage, targetProject, continueQueued), stage.Title, targetProject ?? selectedProject);

    async Task RunStageAsync(Stage stage, ProjectRecord? targetProject = null, bool continueQueued = false)
    {
        var project = targetProject ?? selectedProject;
        if (project == null) return;
        if (ReferenceEquals(project, selectedProject))
            foreach (var box in settingControls.Values.OfType<TextBox>().ToArray())
                if (HasSettingDraft(box)) await CommitSettingInputAsync(box);
        var preflightRevision = StatusRevision(project);
        await RefreshStatusSnapshotAsync(project, true);
        if (shutdownCleanupDone || !projects.Contains(project) || StatusRevision(project) != preflightRevision) return;
        if (stage != Stage.ScanPreparation && !await RecoverStaleReviewAsync(project)) return;
        if (StageUnavailableReason(stage, project) is string reason)
        {
            queuedStages.Remove(project.Id);
            AppendLog($"{stage.Title} cannot start: {reason}", project.Id);
            return;
        }
        if (!continueQueued) queuedStages.Remove(project.Id);
        var reservation = projectOperations.TryReserve(project.Id);
        if (reservation == null) { AppendLog("Wait for the project operation to finish.", project.Id); return; }
        GeneratedOutputManifest? outputStore = null;
        outputOperations.Add(project.Id);
        try
        {
            if (stage == Stage.Preprocessing)
            {
                if (!await ConfirmEarDistanceAsync(project)) return;
                if (!ValidateExternalRuntime(project)) return;
            }
            var createdRoot = !Directory.Exists(project.SaveLocation);
            Directory.CreateDirectory(project.SaveLocation);
            if (createdRoot) { RecordCreatedFolder(project); Persist(); }
            outputStore = OutputsFor(project);
            await Task.Run(() => outputStore.Begin(OutputStageFor(stage)));
            if (stage == Stage.Inference)
            {
                project.Settings.Preprocessing.SourcePositionInputLeft = null;
                project.Settings.Preprocessing.SourcePositionInputRight = null;
                Persist();
            }
            if (stage == Stage.Preprocessing || stage == Stage.Inference)
                runInputStamps[project.Id] = await Task.Run(() => stage == Stage.Preprocessing ? PreprocessingStamp(project) : InferenceStamp(project));
            var preparedProject=Clone(project);
            if(stage==Stage.Postprocessing && HasExternalSofa(project))
            {
                var staging=Path.Combine(project.SaveLocation,".pinna-export-windows-"+Guid.NewGuid().ToString("N"));
                stagedSofaOutputs[project.Id]=staging;(preparedProject.Settings.Postprocessing??=new()).OutputFolder=staging;
            }
            var config = await PrepareConfigAsync(preparedProject);
            if (shutdownCleanupDone) { outputStore.ReleaseForRecovery(); return; }
            var executable = BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
            var info = GeometryProcess("-m", "HRTFCalculation.CLI", stage.Value, "--config", config);
            ApplyProcessEnvironment(info);
            var runId = Guid.NewGuid();
            var startedAt = DateTime.Now;
            var logPath = TechnicalLogPath(project, stage, runId, startedAt);
            PipelineLogCapture? capture = null;
            try
            {
                capture = new PipelineLogCapture(logPath,
                    $"Pinna2HRTF technical output\nProject: {project.Name}\nStage: {stage.Title}\nStarted: {startedAt.ToString("F", CultureInfo.CurrentCulture)}\nCommand: {executable} {string.Join(" ", info.ArgumentList.Select(OwnedProcess.Quote))}\n\n--- stdout and stderr ---",
                    progress => DispatcherQueue.TryEnqueue(() => RecordPipelineEvent(progress, stage, project.Id, runId)),
                    message => DispatcherQueue.TryEnqueue(() => AppendLog("Could not save complete technical output: " + message, project.Id)));
                technicalLogPaths[project.Id] = logPath;
                RefreshTechnicalLogButton();
            }
            catch (Exception error) { AppendLog("Could not create a technical log: " + error.Message, project.Id); }
            var owned = OwnedProcess.Start(info, project.Id);
            var process = owned.Process;
            runs[project.Id] = new PipelineRun(process, stage, capture) { Outputs = outputStore, Owned = owned, Reservation = reservation };
            FailedStages(project.Id).Remove(stage);
            _ = ObservePipelineAsync(owned, capture, project, stage);
            var details = StageStartDetails(stage, project);
            AppendLog($"{stage.Title} started{(details.Length == 0 ? "" : " · " + details)}.", project.Id);
            RefreshPipelineStatus();
        }
        catch (Exception error)
        {
            if (runs.Remove(project.Id, out var failedRun))
            {
                failedRun.Owned?.Dispose();
                failedRun.Capture?.Dispose();
                try { failedRun.Process.Dispose(); } catch { }
            }
            FailedStages(project.Id).Add(stage);
            AppendLog("Could not start " + stage.Title + ": " + error, project.Id);
            RefreshPipelineStatus();
        }
        finally
        {
            outputOperations.Remove(project.Id);
            if (!runs.ContainsKey(project.Id)) { reservation.Dispose(); queuedStages.Remove(project.Id); }
            if (!runs.ContainsKey(project.Id) && outputStore != null)
            {
                try { await Task.Run(outputStore.Complete); }
                catch { AppendLog("Output tracking is pending; it will be retried before reset.", project.Id); }
            }
            if (!shutdownCleanupDone) RefreshPipelineStatus();
        }
    }

    async Task ProcessFinishedAsync(Process process, ProjectRecord project, Stage stage, int code)
    {
        if (shutdownCleanupDone)
        {
            try { process.Dispose(); } catch { }
            return;
        }
        // StopProject may already have handled and disposed this process.
        if (!runs.TryGetValue(project.Id, out var run) || !ReferenceEquals(run.Process, process)) return;
        if (code == 0)
        {
            try
            {
                if((stage==Stage.Preprocessing||stage==Stage.Inference)&&runInputStamps.TryGetValue(project.Id,out var originalStamp)&&originalStamp!=(stage==Stage.Preprocessing?PreprocessingStamp(project):InferenceStamp(project)))throw new IOException("Project inputs or settings changed while the stage was running; rerun it.");
                if(stage==Stage.Inference)HeadGeometry.AtomicWrite(Path.Combine(project.SaveLocation,".pinna2hrtf-inference-signature"),InferenceStamp(project));
                if(stage==Stage.Preprocessing && PreprocessingFilesPresent(project)) HeadGeometry.AtomicWrite(Path.Combine(project.SaveLocation,WindowsPreprocessingReceipt),PreprocessingStamp(project));
                if(stage==Stage.Postprocessing&&stagedSofaOutputs.TryGetValue(project.Id,out var staging))
                {
                    await RequestPythonAsync("HRTFCalculation.DesktopBridge",new{action="validate_outputs",paths=Directory.GetFiles(staging,"*.sofa")});
                    var external = ExternalOutputsFor(project); var destination = SofaDirectory(project);
                    await Task.Run(() => external.Publish(staging,destination));
                }
                if (stage == Stage.Postprocessing)
                {
                    await RequestPythonAsync("HRTFCalculation.DesktopBridge", new { action = "validate_outputs", paths = Directory.GetFiles(SofaDirectory(project), "*.sofa", SearchOption.AllDirectories) });
                    if (!SpatialOutputsCurrent(project)) throw new IOException("Spatial upsampling outputs are incomplete or stale.");
                    HeadGeometry.AtomicWrite(PostprocessingReceipt(project), await Task.Run(() => PostprocessingStamp(project)));
                }
                await RefreshStatusSnapshotAsync(project, true);
                if (!StageIsComplete(stage, project, new ArtifactInspection())) throw new IOException("Expected stage outputs are missing, stale or incomplete.");
                if (stage == Stage.Postprocessing)
                    await RequestPythonAsync("HRTFCalculation.DesktopBridge", new { action = "validate_outputs", paths = Directory.GetFiles(SofaDirectory(project), "*.sofa") });
            }
            catch (Exception error) { code = -1; AppendLog("Output validation failed: " + error.Message, project.Id); }
        }
        if (code != 0 && !run.StopRequested) FailedStages(project.Id).Add(stage);
        outputOperations.Add(project.Id);
        var captured = true;
        var store = run.Outputs;
        run.Outputs = null;
        if (store != null)
        {
            try { await Task.Run(store.Complete); }
            catch { captured = false; AppendLog("Output tracking is pending; it will be retried before reset.", project.Id); }
        }
        if(stagedSofaOutputs.Remove(project.Id,out var completedStaging))
        {
            if (code == 0) { try { if (Directory.Exists(completedStaging)) Directory.Delete(completedStaging,true); } catch(IOException) {} }
            else AppendLog("Postprocessing staging/recovery files were retained: " + completedStaging, project.Id);
            // The persisted settings always describe the final destination.
            try{HeadGeometry.AtomicWrite(Path.Combine(project.SaveLocation,"Project Settings.yaml"),Yaml(project));}catch(Exception error){AppendLog(error.Message,project.Id);}
        }
        runs.Remove(project.Id);
        run.Reservation?.Dispose();
        runInputStamps.Remove(project.Id);
        outputOperations.Remove(project.Id);
        var technicalOutput = technicalLogPaths.TryGetValue(project.Id, out var logPath) ? $" Technical output: {Path.GetFileName(logPath)}." : "";
        AppendLog(run.StopRequested ? stage.Title + " stopped. Completed work is kept for resuming." : code == 0 ? stage.Title + " finished." : stage.Title + " failed (status " + code + ")." + technicalOutput, project.Id);
        process.Dispose();
        RefreshTechnicalLogButton();
        RefreshArtifacts();
        RefreshGeometry();
        if (!shutdownCleanupDone && captured && code == 0 && queuedStages.TryGetValue(project.Id, out var queue) && queue.Count > 0) RunStage(queue.Dequeue(), project, true); else queuedStages.Remove(project.Id);
        RefreshPipelineStatus();
    }

    void ApplyProcessEnvironment(ProcessStartInfo info)
    {
        info.Environment["PINNA2HRTF_ROOT"] = Directory.GetParent(packageRoot)?.FullName ?? packageRoot;
        info.Environment["MPLBACKEND"] = "Agg";
        info.Environment["MPLCONFIGDIR"] = Path.Combine(appData, "Cache", "matplotlib");
        info.Environment["PYTHONPYCACHEPREFIX"] = Path.Combine(appData, "Cache", "python");
        info.Environment["PYTHONNOUSERSITE"] = "1";
        info.Environment["PYTHONUTF8"] = "1";
        info.Environment["BLENDER_USER_CONFIG"] = Path.Combine(appData, "Blender", "config");
        info.Environment["BLENDER_USER_SCRIPTS"] = Path.Combine(appData, "Blender", "scripts");
        info.Environment["BLENDER_USER_DATAFILES"] = Path.Combine(appData, "Blender", "datafiles");
        info.Environment["PINNA2HRTF_LIVE_EVENTS"] = "1";
        var sitePackages = PythonSitePackagesPath();
        info.Environment["PYTHONPATH"] = packageRoot + (sitePackages == null ? "" : Path.PathSeparator + sitePackages);
        info.Environment["PATH"] = Path.Combine(environment.ExternalDir, "bin") + Path.PathSeparator + (info.Environment.TryGetValue("PATH", out var path) ? path : "");
    }

    bool ValidateExternalRuntime(ProjectRecord project)
    {
        var bin = Path.Combine(environment.ExternalDir, "bin");
        var required = new[] { "hrtf_mesh_grading.exe", "libpmp.dll", "libpmp_vis.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll" };
        var missing = required.Where(name => !File.Exists(Path.Combine(bin, name))).ToList();
        if (missing.Count > 0)
        {
            AppendLog($"Preprocessing cannot start: missing native runtime file(s) in {bin}: {string.Join(", ", missing)}", project.Id);
            return false;
        }
        var wrongArchitecture = required.Where(name => !name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? false : !IsWindowsPe64(Path.Combine(bin, name))).ToList();
        if (wrongArchitecture.Count > 0)
        {
            AppendLog($"Preprocessing cannot start: runtime file(s) are not 64-bit Windows binaries: {string.Join(", ", wrongArchitecture)}", project.Id);
            return false;
        }
        var coreLibraries = new[] { "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll", "libpmp.dll" };
        var loaded = new List<IntPtr>();
        try
        {
            foreach (var name in coreLibraries)
            {
                var fullPath = Path.Combine(bin, name);
                var handle = LoadLibraryEx(fullPath, IntPtr.Zero, LoadLibrarySearchDllLoadDir | LoadLibrarySearchDefaultDirs);
                if (handle == IntPtr.Zero)
                {
                    var error = Marshal.GetLastWin32Error();
                    AppendLog($"Preprocessing cannot start: Windows could not load {fullPath} (Win32 error {error}). Check dependent DLLs or Windows Security quarantine.", project.Id);
                    return false;
                }
                loaded.Add(handle);
            }
            var visualPath = Path.Combine(bin, "libpmp_vis.dll");
            var visualHandle = LoadLibraryEx(visualPath, IntPtr.Zero, LoadLibrarySearchDllLoadDir | LoadLibrarySearchDefaultDirs);
            if (visualHandle == IntPtr.Zero)
                AppendLog($"Native runtime warning: optional visualization library could not be loaded: {visualPath} (Win32 error {Marshal.GetLastWin32Error()}). Mesh grading can continue.", project.Id);
            else loaded.Add(visualHandle);
            AppendLog($"Native preprocessing runtime verified in {bin}.", project.Id);
            return true;
        }
        finally
        {
            foreach (var handle in loaded) FreeLibrary(handle);
        }
    }

    static bool IsWindowsPe64(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            using var reader = new BinaryReader(stream);
            if (stream.Length < 0x40 || reader.ReadUInt16() != 0x5A4D) return false;
            stream.Position = 0x3C;
            var peOffset = reader.ReadInt32();
            if (peOffset < 0 || peOffset + 6 > stream.Length) return false;
            stream.Position = peOffset;
            if (reader.ReadUInt32() != 0x00004550) return false;
            return reader.ReadUInt16() == 0x8664;
        }
        catch { return false; }
    }

    string? BundledPythonExecutable()
    {
        var pythonRoot = Path.Combine(packageRoot, "Python");
        if (Directory.Exists(pythonRoot))
        {
            var versioned = Directory.EnumerateDirectories(pythonRoot, "cpython-*")
                .Where(path => Regex.IsMatch(Path.GetFileName(path), @"^cpython-\d+\.\d+\.\d+-"))
                .OrderByDescending(path => path, StringComparer.OrdinalIgnoreCase)
                .Select(path => Path.Combine(path, "python.exe"))
                .FirstOrDefault(File.Exists);
            if (versioned != null) return versioned;
        }
        var venvPath = Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        return File.Exists(venvPath) ? venvPath : null;
    }

    string? PythonSitePackagesPath()
    {
        var candidate = Path.Combine(packageRoot, ".venv", "Lib", "site-packages");
        return Directory.Exists(candidate) ? candidate : null;
    }

    async Task<string> PrepareConfigAsync(ProjectRecord project)
    {
        var prepared = Clone(project);
        if (prepared.InputHandling == InputHandling.Copy)
        {
            if (!prepared.Settings.ScanPreparation.Enabled && !string.IsNullOrWhiteSpace(project.LeftEar)) prepared.LeftEar = await Task.Run(() => CopyInput(project.LeftEar, Path.Combine(project.SaveLocation, "Input", "Left")));
            if (!prepared.Settings.ScanPreparation.Enabled && !string.IsNullOrWhiteSpace(project.RightEar)) prepared.RightEar = await Task.Run(() => CopyInput(project.RightEar, Path.Combine(project.SaveLocation, "Input", "Right")));
            if (prepared.Settings.ScanPreparation.Enabled && !string.IsNullOrWhiteSpace(project.Settings.ScanPreparation.ScanPath))
                prepared.Settings.ScanPreparation.ScanPath = await Task.Run(() => CopyInput(project.Settings.ScanPreparation.ScanPath, Path.Combine(project.SaveLocation, "Input", "Scan")));
            RebaseManualPosition(prepared.Settings.Preprocessing.SourcePositionInputLeft, project.LeftEar, prepared.LeftEar);
            RebaseManualPosition(prepared.Settings.Preprocessing.SourcePositionInputRight, project.RightEar, prepared.RightEar);
        }
        var config = Path.Combine(project.SaveLocation, "Project Settings.yaml");
        var validated = await RequestPythonAsync("HRTFCalculation.DesktopBridge", new { action = "validate", config = ProjectDocument.Build(prepared, environment) });
        HeadGeometry.AtomicWrite(config, validated.GetProperty("yaml").GetString()!);
        return config;
    }

    void RebaseManualPosition(ManualMicrophonePosition? position, string source, string path)
    {
        if (PositionMatchesMesh(position, source) && !string.IsNullOrWhiteSpace(path)) { position!.MeshPath = path; position.MeshIdentity = MeshIdentity(path); }
    }

    string CopyInput(string path, string folder)
    {
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, Path.GetFileName(path));
        if (File.Exists(target) && PathIdentity.Read(path).Id == PathIdentity.Read(target).Id) return target;
        string Digest(string file) { using var stream = File.OpenRead(file); return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)); }
        var digest = Digest(path);
        if (File.Exists(target) && Digest(target) != digest)
            target = Path.Combine(folder, Path.GetFileNameWithoutExtension(path) + "-" + digest[..12].ToLowerInvariant() + Path.GetExtension(path));
        if (File.Exists(target))
        { if (Digest(target) != digest) throw new IOException("An input copy already exists with different contents: " + target); }
        else
        {
            var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.Copy(path, temporary);
                if (Digest(temporary) != digest || Digest(path) != digest) throw new IOException("The input changed while it was being copied.");
                File.Move(temporary, target, false);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        return target;
    }

    string Yaml(ProjectRecord project) => ProjectDocument.Build(project, environment).ToJsonString();


    void StopClicked(object sender, RoutedEventArgs e) { if (selectedProject != null) StopProject(selectedProject); }
    void StopProject(ProjectRecord project)
    {
        queuedStages.Remove(project.Id);
        if (runs.TryGetValue(project.Id, out var run))
        {
            run.StopRequested = true;
            try { run.Owned?.Terminate(); AppendLog("Stopping task and its child processes.", project.Id); }
            catch (Exception error) { AppendLog("Could not stop the task: " + error.Message, project.Id); }
        }
        // The single completion path retains output ownership until the job is
        // empty and final logs/capture are settled.
        RefreshPipelineStatus();
    }
    void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch { }
    }

    static bool WaitForExitSafe(Process process, int timeoutMilliseconds)
    {
        try { return process.HasExited || process.WaitForExit(timeoutMilliseconds); }
        catch { return true; }
    }

    static bool HasExitedSafe(Process process)
    {
        try { return process.HasExited; }
        catch { return true; }
    }

    void StopTrackedProcess(Process process, int timeoutMilliseconds)
    {
        TryTerminate(process);
        if (!WaitForExitSafe(process, timeoutMilliseconds))
            AppendLog($"Process {SafeProcessName(process)} did not exit within {timeoutMilliseconds} ms; owned process cleanup remains active.", selectedProject?.Id);
    }
    void ResetOutputsClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ResetOutputsAsync(), "ResetOutputs", selectedProject);
    async Task ResetOutputsAsync()
    {
        if (selectedProject is not { } project || ProjectBusy(project.Id)) return;
        var dialog = new ContentDialog
        {
            Title = "Reset pipeline outputs?",
            Content = "Remove generated outputs from all stages? Input meshes, microphone positions, settings and project logs will be kept.",
            PrimaryButtonText = "Reset Outputs", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot
        };
        if (await ShowDialogAsync(dialog) == ContentDialogResult.Primary) await ResetProjectOutputsAsync(project);
    }

    async Task<bool> ResetProjectOutputsAsync(ProjectRecord project, Stage? fromStage = null, IDisposable? parent = null)
    {
        if (shutdownCleanupDone || runs.ContainsKey(project.Id) || parent == null && ProjectBusy(project.Id)) return false;
        using var reservation = projectOperations.TryReserve(project.Id, parent);
        if (reservation == null || !outputOperations.TryAdd(project.Id)) return false;
        if (placementProjectId == project.Id) EndPlacement();
        queuedStages.Remove(project.Id);
        RefreshPipelineStatus();
        var boundary = fromStage == null ? (GeneratedOutputManifest.OutputStage?)null : OutputStageFor(fromStage);
        GeneratedOutputManifest.ResetResult result;
        try
        {
            var store=OutputsFor(project);result=await Task.Run(()=>store.Reset(boundary));
            var externalStore = ExternalOutputsFor(project);
            var external=await Task.Run(externalStore.Reset);result.Deleted+=external.Deleted;result.Modified+=external.Modified;result.Errors+=external.Errors;result.ProtectedInputs+=external.ProtectedInputs;
        }
        catch { result = new GeneratedOutputManifest.ResetResult { Errors = 1 }; }
        finally { outputOperations.Remove(project.Id); }
        AppendLog(result.Summary(boundary), project.Id);
        if (result.Success)
        {
            FailedStages(project.Id).RemoveWhere(s => fromStage == null || OutputStageFor(s) >= boundary);
            knownOutputs.Remove(project.Id);
            lastOutputScan.Remove(project.Id);
        }
        ReconcileEditorReferences(project);
        Persist();
        if (selectedProject == project) { LoadSelectedProject(); RefreshArtifacts(); }
        RefreshPipelineStatus();
        return result.Success;
    }

    bool ContainsPath(string parent, string child)
    {
        if (string.IsNullOrWhiteSpace(parent) || string.IsNullOrWhiteSpace(child)) return false;
        var p = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var c = Path.GetFullPath(child);
        return c.Equals(p, StringComparison.OrdinalIgnoreCase) || c.StartsWith(p + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    void ClearLogClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null) return;
        projectLogs[selectedProject.Id] = "";
        projectLogKeyIndices.Remove(selectedProject.Id);
        logText.Text = "";
        if (!SaveProjectLog(selectedProject.Id)) SaveProjectLogs();
    }

    static T? FindDescendant<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) return match;
            var nested = FindDescendant<T>(child);
            if (nested != null) return nested;
        }
        return null;
    }

    void AttachLogScrollViewer()
    {
        var scroll = FindDescendant<ScrollViewer>(logText);
        if (scroll == null)
        {
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, AttachLogScrollViewer);
            return;
        }
        if (ReferenceEquals(logScrollViewer, scroll)) return;
        if (logScrollViewer != null) logScrollViewer.ViewChanged -= LogScrollViewerViewChanged;
        logScrollViewer = scroll;
        logScrollViewer.ViewChanged += LogScrollViewerViewChanged;
        logScrollViewer.PointerWheelChanged += (_, _) => MarkLogUserScroll();
        logFollowTail = true;
    }

    void MarkLogUserScroll()
    {
        if (logProgrammaticScroll) return;
        logTailUserInteraction = true;
        logFollowTail = false;
    }

    void LogScrollViewerViewChanged(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        if (sender is not ScrollViewer scroll) return;
        if (logProgrammaticScroll || logTailScrollPending && !logTailUserInteraction) return;
        logFollowTail = scroll.ScrollableHeight - scroll.VerticalOffset <= 4;
    }

    void RequestLogTail()
    {
        logFollowTail = true;
        logTailUserInteraction = false;
        if (logTailScrollPending) return;
        logTailScrollPending = true;
        AttachLogScrollViewer();
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                logTailScrollPending = false;
                if (!logFollowTail || logTailUserInteraction) return;
                var scroll = logScrollViewer ?? FindDescendant<ScrollViewer>(logText);
                if (scroll == null) return;
                logProgrammaticScroll = true;
                try { scroll.ChangeView(null, scroll.ScrollableHeight, null); }
                finally { logProgrammaticScroll = false; }
            });
        });
    }

    void RestoreLogScroll(double offset, bool followTail)
    {
        AttachLogScrollViewer();
        if (followTail)
        {
            RequestLogTail();
            return;
        }
        logFollowTail = false;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            var scroll = logScrollViewer ?? FindDescendant<ScrollViewer>(logText);
            if (scroll == null) return;
            logProgrammaticScroll = true;
            try { scroll.ChangeView(null, Math.Clamp(offset, 0, scroll.ScrollableHeight), null); }
            finally { logProgrammaticScroll = false; }
        });
    }

    void AppendLog(string? text, Guid? projectId = null, string? key = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var compactLines = text.Replace("\r\n", "\n").Split('\n').Select(x => x.Trim())
            .Where(x => x.Length > 0 && !Path.IsPathRooted(x) && !x.Contains("Mem:") && !x.StartsWith("Fra:") && !x.StartsWith("Blender", StringComparison.OrdinalIgnoreCase))
            .ToArray();
        if (compactLines.Length == 0) return;
        var id = projectId ?? selectedProject?.Id;
        if (id == null) return;
        void Append()
        {
            AttachLogScrollViewer();
            var scroll = logScrollViewer ?? FindDescendant<ScrollViewer>(logText);
            var oldOffset = scroll?.VerticalOffset ?? 0;
            var followTail = logFollowTail;
            var current = projectLogs.TryGetValue(id.Value, out var value) && value.Length > 0
                ? value.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries).ToList()
                : new List<string>();
            var timestamp = DateTime.Now.ToString("T", CultureInfo.CurrentCulture);
            var formatted = compactLines.Select(line => $"[{timestamp}] {line}").ToArray();
            projectLogKeyIndices.TryGetValue(id.Value, out var keyIndices);
            if (key != null && keyIndices != null && keyIndices.TryGetValue(key, out var existingIndex) && existingIndex < current.Count)
                current[existingIndex] = formatted[0];
            else
            {
                var firstIndex = current.Count;
                current.AddRange(formatted);
                if (key != null)
                {
                    keyIndices ??= [];
                    keyIndices[key] = firstIndex;
                    projectLogKeyIndices[id.Value] = keyIndices;
                }
            }
            if (current.Count > 400)
            {
                current.RemoveRange(0, current.Count - 400);
                projectLogKeyIndices.Remove(id.Value);
            }
            projectLogs[id.Value] = string.Join(Environment.NewLine, current);
            if (!SaveProjectLog(id.Value)) legacyProjectLogs[id.Value] = projectLogs[id.Value];
            else legacyProjectLogs.Remove(id.Value);
            if (selectedProject?.Id == id)
            {
                logText.Text = projectLogs[id.Value];
                RestoreLogScroll(oldOffset, followTail);
            }
        }
        if (DispatcherQueue.HasThreadAccess) Append(); else DispatcherQueue.TryEnqueue(Append);
    }

    void RecordPipelineEvent(PipelineLogEvent progress, Stage stage, Guid projectId, Guid runId)
    {
        var message = progress.Level?.ToLowerInvariant() switch
        {
            "warning" => $"Warning · {stage.Title} · {progress.Message}",
            "error" => $"Error · {stage.Title} · {progress.Message}",
            _ => $"{stage.Title} · {progress.Message}"
        };
        var key = progress.Key == null ? null : $"{runId:N}:{progress.Key}";
        AppendLog(message, projectId, key);
    }

    string StageStartDetails(Stage stage, ProjectRecord project)
    {
        if (stage == Stage.ScanPreparation)
        {
            var scan = Path.GetFileName(project.Settings.ScanPreparation.ScanPath);
            var sides = new List<string>();
            if (project.Settings.ScanPreparation.PrepareLeft) sides.Add("Left");
            if (project.Settings.ScanPreparation.PrepareRight) sides.Add("Right");
            return $"{scan} · {string.Join(" + ", sides)} ear{(sides.Count == 1 ? "" : "s")}";
        }
        if (stage == Stage.Numcalc || stage == Stage.Postprocessing)
            return $"Project output: {Path.GetFileName(project.SaveLocation)}";

        var inputs = new[]
        {
            ("Left", project.Settings.ScanPreparation.Enabled && project.Settings.ScanPreparation.PrepareLeft ? Path.Combine(project.SaveLocation, "Prepared", "Left.stl") : project.LeftEar),
            ("Right", project.Settings.ScanPreparation.Enabled && project.Settings.ScanPreparation.PrepareRight ? Path.Combine(project.SaveLocation, "Prepared", "Right.stl") : project.RightEar)
        }.Where(input => !string.IsNullOrWhiteSpace(input.Item2))
            .Select(input => $"{input.Item1} {Path.GetFileName(input.Item2)}");
        var description = string.Join(", ", inputs);
        return description.Length == 0 ? "" : "Inputs: " + description;
    }

    // An inspection lives only for one synchronous refresh, including its dependent status queries.
    sealed class ArtifactInspection
    {
        public bool Background { get; init; }
        public readonly Dictionary<(Guid, Stage), bool> Stages = [];
        public readonly Dictionary<(string, int), bool> Steps = [];
        readonly Dictionary<string, JsonElement> documents = new(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, string> digests = new(StringComparer.OrdinalIgnoreCase);

        public JsonElement Document(string path)
        {
            if (!documents.TryGetValue(path, out var value))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(path));
                documents[path] = value = document.RootElement.Clone();
            }
            return value;
        }

        public string Digest(string path)
        {
            if (!digests.TryGetValue(path, out var value)) digests[path] = value = FileDigest(path);
            return value;
        }
    }

    void RefreshNumCalcStatus(ArtifactInspection? inspection = null) =>
        numCalcStatusText.Text = selectedProject == null ? "No project selected" : NumCalcStatus(selectedProject, inspection);
    void RefreshPipelineStatus(ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        if (selectedProject != null) _ = ReconcileOutputsAsync(selectedProject);
        if (selectedProject == null) { RefreshNumCalcStatus(inspection); RefreshWorkflow(inspection); return; }
        var stages = Stage.GetValues();
        for (var i = 0; i < stages.Length; i++)
        {
            var stage = stages[i];
            var skipped = stage == Stage.Inference && !selectedProject.Settings.Inference.UsePredictionsForPreprocessing;
            var running = runs.TryGetValue(selectedProject.Id, out var active) && active.Stage == stage;
            var failed = FailedStages(selectedProject.Id).Contains(stage);
            var reason = StageUnavailableReason(stage, selectedProject, inspection);
            var complete = StageIsComplete(stage, selectedProject, inspection);
            stageStatus[i].Text = skipped ? "Skipped" : running ? "Running…" : failed ? "Failed" : complete ? "Done" : reason != null ? "Blocked" : "Ready";
            stageStatus[i].Foreground = new SolidColorBrush(skipped ? ColorHelper.FromArgb(255, 130, 130, 130) : running ? Colors.DarkOrange : failed ? Colors.Firebrick : complete ? Colors.ForestGreen : Colors.Gray);
            if (!MacLayout) stageButtons[i].Content = running ? "Stop" : "Run";
            stageButtons[i].IsEnabled = placementSide == null && (running || reason == null);
            ToolTipService.SetToolTip(stageStatus[i], reason ?? $"{stage.Title} is ready.");
            ToolTipService.SetToolTip(stageButtons[i], running ? "Stop this stage" : reason ?? $"Run {WorkflowStageTitle(stage)}");
        }
        var pending = AutomaticStages(selectedProject).Where(x => !StageIsComplete(x, selectedProject, inspection)).ToList();
        runAllButton.IsEnabled = placementSide == null && pending.Count > 0 && StageCanRun(pending[0], selectedProject, inspection);
        var preprocessingReason = StageUnavailableReason(Stage.Preprocessing, selectedProject, inspection);
        var hint = placementSide != null ? "Finish microphone placement with Done or Cancel." :
            runs.ContainsKey(selectedProject.Id) ? null :
            preprocessingReason != null ? "Preprocessing: " + preprocessingReason :
            pending.Count > 0 ? StageUnavailableReason(pending[0], selectedProject, inspection) : null;
        pipelineHintText.Text = hint ?? "";
        pipelineHintText.Visibility = hint == null ? Visibility.Collapsed : Visibility.Visible;
        UpdatePlacementButtons();
        RefreshProjectRows(inspection);
        RefreshNumCalcStatus(inspection);
        if (MacLayout) RefreshMacPresentation(inspection);
        RefreshWorkflow(inspection);
    }

    bool InferenceIsAutomatic(ProjectRecord project) => project.Settings.Inference.UsePredictionsForPreprocessing && !project.Settings.ManualPPM.Enabled;
    bool HasGeneratedPipelineOutputs(ProjectRecord project) => (project.Settings.ScanPreparation.Enabled || !string.IsNullOrWhiteSpace(project.LeftEar) || !string.IsNullOrWhiteSpace(project.RightEar)) && !string.IsNullOrWhiteSpace(project.SaveLocation) && ((InferenceIsAutomatic(project) && StageIsComplete(Stage.Inference, project)) || StageIsComplete(Stage.Preprocessing, project) || StageIsComplete(Stage.Numcalc, project) || StageIsComplete(Stage.Postprocessing, project));
    bool PreprocessingBlocked(ProjectRecord project, ArtifactInspection? inspection = null) => InferenceIsAutomatic(project) && !StageIsComplete(Stage.Inference, project, inspection);
    bool StageCanRun(Stage stage, ProjectRecord? project, ArtifactInspection? inspection = null) => StageUnavailableReason(stage, project, inspection) == null;

    string? StageUnavailableReason(Stage stage, ProjectRecord? project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        if (project == null) return "Select a project first.";
        if (scanAlignmentMode && alignmentSessionProject == project.Id) return "Save or cancel scan alignment before running a stage.";
        if (SettingDraftError(project) is string draftError) return draftError;
        if (ProjectDocument.ValidationError(project) is string validation) return validation;
        if (stage != Stage.ScanPreparation && CurrentEarModel(project) == null) return "Choose one ear modelling method in Ear model.";
        if (projectOperations.Contains(project.Id) || OwnedProcess.HasProjectActivity(project.Id)) return "Wait for the project operation or editor to finish.";
        if (outputOperations.Contains(project.Id)) return "Wait for project outputs to finish updating.";
        if (runs.ContainsKey(project.Id)) return "Wait for the running stage to finish.";
        if (placementProjectId == project.Id) return "Finish microphone placement with Done or Cancel.";
        if (SofaConflict(project) is string conflict) return conflict;
        if (!inspection.Background && DispatcherQueue.HasThreadAccess)
        {
            _ = CachedStageComplete(stage, project);
            return statusSnapshots.TryGetValue(project.Id, out var saved) && saved.Revision == StatusRevision(project)
                ? saved.Reasons.GetValueOrDefault(stage) : "Checking project inputs…";
        }
        return StageAvailabilityReason(stage, project, inspection);
    }
    string? StageAvailabilityReason(Stage stage, ProjectRecord project, ArtifactInspection inspection)
    {
        if (string.IsNullOrWhiteSpace(project.SaveLocation)) return "Choose a save location first.";
        if (stage == Stage.Postprocessing && project.Settings.Postprocessing?.SpatialUpsampling == true &&
            (SourceEar(project, "left", inspection) == null || SourceEar(project, "right", inspection) == null))
            return "Spatial upsampling requires both left and right ears. Disable it for a one-ear export.";
        if (string.IsNullOrWhiteSpace(project.LeftEar) && string.IsNullOrWhiteSpace(project.RightEar) && !project.Settings.ScanPreparation.Enabled) return "Select at least one input ear.";
        if (stage == Stage.ScanPreparation)
        {
            if (!project.Settings.ScanPreparation.Enabled) return "Enable optional scan preparation first.";
            if (!File.Exists(project.Settings.ScanPreparation.ScanPath)) return "Choose an existing full-head scan.";
            if (!project.Settings.ScanPreparation.PrepareLeft && !project.Settings.ScanPreparation.PrepareRight) return "Select an ear to prepare.";
            return null;
        }
        if (!project.Settings.ScanPreparation.Enabled && ((!string.IsNullOrWhiteSpace(project.LeftEar) && !File.Exists(project.LeftEar)) || (!string.IsNullOrWhiteSpace(project.RightEar) && !File.Exists(project.RightEar)))) return "An input ear file is missing. Select it again.";
        if (project.Settings.ScanPreparation.Enabled && !ScanPreparationOutputsCurrent(project, inspection)) return "Run Scan Preparation with the current settings first.";
        if (project.Settings.ScanPreparation.Enabled && project.Settings.ScanPreparation.RequireManualReview && new[] { "left", "right" }.Any(side => SourceEar(project, side, inspection) != null && !EarReviewIsCurrent(project, side, inspection))) return "Review the prepared ears before continuing.";
        foreach (var side in WorkflowSides(project)) {
            var reviewed = project.Settings.ScanPreparation.EarEdit(side);
            if (reviewed != null && !EarReviewIsCurrent(project, side, inspection)) return $"The {side} ear edit is outdated. Edit again or use the original in Prepare ears.";
            if (project.Settings.ManualPPM.Enabled && !FitIsCurrent(project, side)) return $"Fit the {side} ear: manual mode requires a current saved fit for every included ear.";
        }
        if (stage == Stage.Inference)
        {
            if (!InferenceIsAutomatic(project)) return "Enable Use Mesh2PPM and select at least one input ear.";
            return File.Exists(project.Settings.Inference.ModelConfig) && File.Exists(project.Settings.Inference.ModelCheckpoint) ? null : "The selected inference model is missing.";
        }
        if (stage == Stage.Preprocessing)
        {
            if (PreprocessingBlocked(project, inspection)) return "Run Mesh2PPM Inference to create the predicted input ear(s) first.";
            if (!File.Exists(environment.MeshGradingExecutable)) return "The Windows mesh-grading tool is missing. Rebuild the app with its external tools.";
            var bin = Path.Combine(environment.ExternalDir, "bin");
            if (new[] { "libpmp.dll", "libpmp_vis.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll" }.Any(name => !File.Exists(Path.Combine(bin, name))))
                return "The Windows mesh-grading runtime is incomplete. Rebuild the app with its external tools.";
            return File.Exists(Path.Combine(environment.ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf", "Mesh2Input", "mesh2input.py")) ? null : "The Mesh2HRTF export tools are missing.";
        }
        if (stage == Stage.Numcalc) return !StageIsComplete(Stage.Preprocessing, project, inspection) ? "Run Preprocessing first." : File.Exists(environment.NumCalcExecutable) ? null : "The NumCalc executable is missing.";
        if (stage == Stage.Postprocessing && !StageIsComplete(Stage.Preprocessing, project, inspection)) return "Run preprocessing with the current inputs and settings first.";
        return stage == Stage.Postprocessing && StageIsComplete(Stage.Numcalc, project, inspection) ? null : "Run NumCalc first.";
    }

    Stage[] AutomaticStages(ProjectRecord project) => [
        .. (project.Settings.ScanPreparation.Enabled ? new[] { Stage.ScanPreparation } : Array.Empty<Stage>()),
        .. (InferenceIsAutomatic(project) ? new[] { Stage.Inference } : Array.Empty<Stage>()),
        Stage.Preprocessing, Stage.Numcalc, Stage.Postprocessing];
    bool StageIsComplete(Stage stage, ProjectRecord project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        if (!inspection.Background && DispatcherQueue.HasThreadAccess) return CachedStageComplete(stage, project);
        var key = (project.Id, stage);
        if (!inspection.Stages.TryGetValue(key, out var complete))
            inspection.Stages[key] = complete = InspectStage(stage, project, inspection);
        return complete;
    }

    bool InspectStage(Stage stage, ProjectRecord project, ArtifactInspection inspection)
    {
        var output = project.SaveLocation;
        if (stage == Stage.Inference)
        {
            if (!project.Settings.Inference.UsePredictionsForPreprocessing) return true;
            if (!InferenceIsAutomatic(project)) return false;
            if (project.Settings.ScanPreparation.Enabled && !ScanReviewStageReceiptCurrent(project, "inference", inspection)) return false;
            var leftDone = SourceEar(project,"left",inspection) == null || PredictionMesh(project, "left") != null;
            var rightDone = SourceEar(project,"right",inspection) == null || PredictionMesh(project, "right") != null;
            return leftDone && rightDone && InferenceStampIsCurrent(project);
        }
        if (stage == Stage.ScanPreparation)
        {
            if (!project.Settings.ScanPreparation.Enabled || string.IsNullOrWhiteSpace(output)) return false;
            var prepared = Path.Combine(output, "Prepared");
            var leftReady = project.Settings.ScanPreparation.PrepareLeft && File.Exists(Path.Combine(prepared, "Left.stl"));
            var rightReady = project.Settings.ScanPreparation.PrepareRight && File.Exists(Path.Combine(prepared, "Right.stl"));
            return ScanPreparationOutputsCurrent(project, inspection) && (leftReady || rightReady);
        }
        if (string.IsNullOrWhiteSpace(output) || (string.IsNullOrWhiteSpace(project.LeftEar) && string.IsNullOrWhiteSpace(project.RightEar) && !project.Settings.ScanPreparation.Enabled)) return false;
        if (stage == Stage.Preprocessing)
        {
            if(project.Settings.ScanPreparation.Enabled&&!ScanReviewStageReceiptCurrent(project,"preprocessing",inspection))return false;
            return PreprocessingFilesPresent(project) && PreprocessingStampIsCurrent(project);

        }
        if (stage == Stage.Numcalc) return StageIsComplete(Stage.Preprocessing, project, inspection) && NumCalcIsComplete(project, inspection);
        return stage == Stage.Postprocessing && StageIsComplete(Stage.Numcalc, project, inspection) && PostprocessingIsCurrent(project);
    }

    bool ScanPreparationOutputsCurrent(ProjectRecord project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        try
        {
            var scan=project.Settings.ScanPreparation;
            var report=inspection.Document(Path.Combine(project.SaveLocation,"Prepared","mesh_preparation.json"));
            if(report.GetProperty("status").GetString()!="completed"||report.GetProperty("signature").GetProperty("source_sha256").GetString()!=inspection.Digest(scan.ScanPath))return false;
            var recorded=System.Text.Json.Nodes.JsonNode.Parse(report.GetProperty("signature").GetProperty("settings").GetRawText())!.AsObject();
            var expected=ProjectDocument.Build(project,environment)["scan_preparation"]!.AsObject();
            foreach(var key in new[]{"require_manual_review","reviewed_left","reviewed_right","scan_path","original_scan_path","prepare_left","prepare_right"}) {recorded.Remove(key);expected.Remove(key);}
            // The default polygon is YAML-only, and is preserved on import.
            if(!expected.ContainsKey("crop_polygon_xz"))recorded.Remove("crop_polygon_xz");
            if(!ProjectDocument.SameJson(recorded,expected))return false;
            foreach(var side in new[]{"left","right"})
                if(side=="left"?scan.PrepareLeft:scan.PrepareRight)
                    if(report.GetProperty("ears").GetProperty(side).GetProperty("sha256").GetString()!=inspection.Digest(Path.Combine(project.SaveLocation,"Prepared",side=="left"?"Left.stl":"Right.stl")))return false;
            return true;
        }
        catch{return false;}
    }

    string NextStageSummary(ProjectRecord project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        if (runs.TryGetValue(project.Id, out var active)) return active.Stage.Title + ": Running";
        var next = AutomaticStages(project).FirstOrDefault(x => !StageIsComplete(x, project, inspection));
        return next == null ? "Complete" : next.Title + (StageCanRun(next, project, inspection) ? ": Ready" : ": Blocked");
    }
    string NumCalcStatus(ProjectRecord project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        if (!inspection.Background && DispatcherQueue.HasThreadAccess)
            return statusSnapshots.TryGetValue(project.Id, out var saved) && saved.Revision == StatusRevision(project) ? saved.NumCalc : "NumCalc: checking results…";
        var sides = project.Settings.ScanPreparation.Enabled
            ? new[] { project.Settings.ScanPreparation.PrepareLeft, project.Settings.ScanPreparation.PrepareRight }
            : new[] { !string.IsNullOrWhiteSpace(project.LeftEar), !string.IsNullOrWhiteSpace(project.RightEar) };
        return "NumCalc: " + string.Join(" · ", sides.Select((selected, i) => !selected ? "" : (i == 0 ? "Left" : "Right") + " " + NumCalcCompleted(project, i == 0 ? "Left" : "Right", inspection) + "/" + NumCalcTotal(project, i == 0 ? "Left" : "Right", inspection)).Where(x => x.Length > 0));
    }
    int NumCalcCompleted(ProjectRecord project, string side, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        var source = Path.Combine(project.SaveLocation, "Projects", side, "NumCalc", "source_1");
        var output = Path.Combine(source, "be.out");
        if (!Directory.Exists(output)) return 0;
        return Directory.GetDirectories(output, "be.*")
            .Select(path => int.TryParse(Path.GetFileName(path).AsSpan(3), out var step) && FrequencyStepComplete(source, step, inspection) ? 1 : 0)
            .Sum();
    }
    int NumCalcTotal(ProjectRecord project, string side, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        try
        {
            var document = inspection.Document(Path.Combine(project.SaveLocation, "Projects", side, "parameters.json"));
            return document.TryGetProperty("numFrequencies", out var value) ? value.GetInt32() : 0;
        }
        catch { return 0; }
    }
    bool NumCalcIsComplete(ProjectRecord project, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        if (string.IsNullOrWhiteSpace(project.SaveLocation)) return false;
        var sides = project.Settings.ScanPreparation.Enabled
            ? new[] { ("Left", project.Settings.ScanPreparation.PrepareLeft), ("Right", project.Settings.ScanPreparation.PrepareRight) }
            : new[] { ("Left", !string.IsNullOrWhiteSpace(project.LeftEar)), ("Right", !string.IsNullOrWhiteSpace(project.RightEar)) };
        var selected = sides.Where(x => x.Item2).ToArray();
        if (selected.Length == 0) return false;
        return selected.All(x => NumCalcSideIsComplete(project, x.Item1, inspection));
    }

    bool NumCalcSideIsComplete(ProjectRecord project, string side, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        var sideRoot = Path.Combine(project.SaveLocation, "Projects", side);
        if (ContainsOutput2HRTF(Path.Combine(sideRoot, "Output2HRTF"))) return true;
        var total = NumCalcTotal(project, side, inspection);
        if (total <= 0) return false;
        var sources = Directory.Exists(Path.Combine(sideRoot, "NumCalc"))
            ? Directory.GetDirectories(Path.Combine(sideRoot, "NumCalc"), "source_*")
            : Array.Empty<string>();
        return sources.Length > 0 && sources.All(source => Enumerable.Range(1, total).All(step => FrequencyStepComplete(source, step, inspection)));
    }

    bool FrequencyStepComplete(string source, int step, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        var key = (source, step);
        if (!inspection.Steps.TryGetValue(key, out var complete))
            inspection.Steps[key] = complete = InspectFrequencyStep(source, step);
        return complete;
    }

    bool InspectFrequencyStep(string source, int step)
    {
        var output = Path.Combine(source, "be.out", $"be.{step}");
        var required = new[] { "pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid" };
        if (!Directory.Exists(output) || required.Any(name => !File.Exists(Path.Combine(output, name)) && !Directory.Exists(Path.Combine(output, name)))) return false;
        var log = Path.Combine(source, $"NC{step}-{step}_log.txt");
        try { return File.Exists(log) && File.ReadAllText(log).Contains("---------- NumCalc ended:", StringComparison.Ordinal); }
        catch { return false; }
    }
    bool ContainsMesh(string folder) => Directory.Exists(folder) && Directory.GetFiles(folder).Any(IsMesh);
    bool ContainsOutput2HRTF(string folder) => Directory.Exists(folder) && Directory.GetFiles(folder, "*.sofa").Any();
    bool IsMesh(string path) => new[] { ".stl", ".ply" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
    HashSet<Stage> FailedStages(Guid id) { if (!failedStages.TryGetValue(id, out var set)) failedStages[id] = set = []; return set; }

    void SettingInfoClicked(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not string id || !settingHelp.TryGetValue(id, out var entry)) return;
        var flyout = new Flyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        var panel = new StackPanel { Width = 360, Spacing = 8, Margin = new Thickness(14) };
        panel.Children.Add(new TextBlock { Text = entry.Title, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = entry.Description, TextWrapping = TextWrapping.Wrap });
        foreach (var publication in entry.Publications)
        {
            var link = new Button { Content = publication.Title, Tag = publication.Url, HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 23, 105, 170)) };
            link.Click += PublicationClicked;
            panel.Children.Add(link);
        }
        flyout.Content = panel;
        flyout.ShowAt(button);
    }

    void PublicationClicked(object sender, RoutedEventArgs e) { if (sender is Button button && button.Tag is string url) OpenExternal(url); }
    async void OpenDocumentationClicked(object sender, RoutedEventArgs e)
    { try { await OpenOfflineDocumentationAsync(); } catch (Exception error) { AppendLog("Could not open Help: " + error.Message); } }
    void OpenExternal(string url) { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { } }

    void ShowAboutClicked(object sender, RoutedEventArgs e) => _ = ObserveUiTaskAsync(ShowAboutAsync(), "ShowAbout", selectedProject);
    async Task ShowAboutAsync()
    {
        var version = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "1.2.0";
        var content = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        var logoPath = Path.Combine(AppContext.BaseDirectory, "icon.png");
        if (File.Exists(logoPath)) content.Children.Add(new Image { Source = new BitmapImage(new Uri(logoPath)), Width = 336, Height = 240, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "Pinna2HRTF", FontSize = 24, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "Version " + version, FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "A desktop pipeline for ear-mesh preprocessing, Mesh2PPM inference, Mesh2HRTF simulation, and SOFA export.", FontSize = 13, TextWrapping = TextWrapping.Wrap, MaxWidth = 540, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center });
        var dialog = new ContentDialog { Title = "About Pinna2HRTF", Content = content, CloseButtonText = "Close", XamlRoot = Root.XamlRoot };
        await ShowDialogAsync(dialog);
    }

    void LoadSettingHelp()
    {
        var path = Path.Combine(packageRoot, "ProjectSettingHelp.json");
        if (!File.Exists(path)) return;
        try { foreach (var entry in JsonSerializer.Deserialize<List<SettingHelpEntry>>(File.ReadAllText(path), jsonOptions) ?? []) settingHelp[entry.Id] = entry; } catch { settingHelp.Clear(); }
    }

    void UpdateViewerAppearance()
    {
        var dark = Root.ActualTheme == ElementTheme.Dark;
        appBackgroundBrush.Color = dark ? ColorHelper.FromArgb(255, 32, 32, 32) : Colors.White;
        surfaceBrush.Color = dark ? ColorHelper.FromArgb(255, 38, 38, 38) : Colors.White;
        secondarySurfaceBrush.Color = dark ? ColorHelper.FromArgb(255, 45, 45, 45) : ColorHelper.FromArgb(255, 251, 251, 252);
        inputBackgroundBrush.Color = dark ? ColorHelper.FromArgb(255, 45, 45, 45) : Colors.White;
        borderBrush.Color = dark ? ColorHelper.FromArgb(255, 70, 70, 70) : ColorHelper.FromArgb(255, 220, 225, 228);
        primaryTextBrush.Color = dark ? ColorHelper.FromArgb(255, 235, 235, 235) : ColorHelper.FromArgb(255, 32, 32, 32);
        mutedTextBrush.Color = dark ? ColorHelper.FromArgb(255, 160, 160, 160) : ColorHelper.FromArgb(255, 105, 113, 125);
        viewerBackgroundBrush.Color = dark ? ColorHelper.FromArgb(255, 31, 36, 38) : ColorHelper.FromArgb(255, 237, 243, 242);
        viewerHintBackgroundBrush.Color = dark ? ColorHelper.FromArgb(215, 43, 46, 48) : ColorHelper.FromArgb(220, 255, 255, 255);
        viewerHintTextBrush.Color = dark ? Colors.White : ColorHelper.FromArgb(255, 48, 55, 58);
        placementBorder.Background = viewerHintBackgroundBrush;
        placementCoordinates.Foreground = viewerHintTextBrush;
        Root.Background = appBackgroundBrush;
        if (contentGrid != null) contentGrid.Background = appBackgroundBrush;
        if (meshViewerBackground != null) { meshViewerBackground.Background = viewerBackgroundBrush; meshViewport.BackgroundColor = viewerBackgroundBrush.Color; }
        foreach (var box in settingControls.Values.OfType<TextBox>().Append(logText))
        {
            box.Background = inputBackgroundBrush;
            box.Foreground = primaryTextBrush;
            box.BorderBrush = borderBrush;
        }
        foreach (var combo in new[] { modelPicker, artifactPicker })
        {
            combo.Background = inputBackgroundBrush;
            combo.Foreground = primaryTextBrush;
            combo.BorderBrush = borderBrush;
        }
        selectedArtifactText.Foreground = mutedTextBrush;
        viewerPlaceholder.Foreground = mutedTextBrush;
        numCalcStatusText.Foreground = mutedTextBrush;
        pipelineHintText.Foreground = mutedTextBrush;
        foreach (var row in projectRows.Values)
        {
            row.Name.Foreground = primaryTextBrush;
            row.Status.Foreground = mutedTextBrush;
        }
    }

    public void ShutdownForAppClose()
    {
        try { FinishFolderNameForClose(); } catch { }
        windowChrome?.Dispose();
        meshNavigation?.Dispose();
        try { documentationWindow?.Close(); } catch { }
        editorLifetime.Cancel();
        OwnedProcess.StopAll();
        foreach (var editor in editorWindows.ToArray()) { try { editor.Close(); } catch { } }
        if (shutdownCleanupDone) return;
        shutdownCleanupDone = true;
        try { if (placementSide != null) EndPlacement(); } catch { }
        try
        {
            meshLoadCancellation?.Cancel();
            meshLoadCancellation?.Dispose();
            meshLoadCancellation = null;
        }
        catch { }
        try { statusTimer.Stop(); } catch { }

        try
        {
            if (meshViewport.RenderHost != null)
                meshViewport.Detach();
        }
        catch { }

        var processes = runs.Values.Select(run => run.Process).Distinct().ToList();
        foreach (var process in processes)
        {
            try { StopTrackedProcess(process, 1500); } catch { }
        }

        foreach (var process in processes)
        {
            WaitForExitSafe(process, 1000);
            try { process.Dispose(); } catch { }
        }
        foreach (var run in runs.Values) { run.Capture?.Dispose(); run.Reservation?.Dispose(); }
        foreach (var store in runs.Values.Select(run => run.Outputs).Distinct()) store?.ReleaseForRecovery();
        runs.Clear();
        queuedStages.Clear();
        try { Persist(); } catch { }
        try { SaveUiState(); } catch { }
        try { SaveViewerStates(); } catch { }
        try { SaveProjectLogs(); } catch { }
    }

    void AppWindowClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (closingConfirmed || (runs.Count == 0 && editorWindows.Count == 0)) { ShutdownForAppClose(); return; }
        args.Cancel = true;
        _ = ConfirmQuitAsync(sender);
    }

    async Task ConfirmQuitAsync(Microsoft.UI.Windowing.AppWindow appWindow)
    {
        var dialog = new ContentDialog { Title = "Quit Pinna2HRTF?", Content = "Quitting stops running tasks and discards unsaved changes in open editors. Save editor work before quitting.", PrimaryButtonText = "Quit", CloseButtonText = "Keep app open", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot };
        if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;
        closingConfirmed = true;
        ShutdownForAppClose();
        Close();
    }

    void LoadRegistry()
    {
        if (File.Exists(registryPath))
        {
            try
            {
                var original = File.ReadAllText(registryPath);
                var migrated = HeadGeometry.MigrateRegistry(original, out var changed);
                registry = JsonSerializer.Deserialize<ProjectRegistry>(migrated, jsonOptions) ?? throw new InvalidDataException("Invalid registry.");
                if (changed)
                {
                    File.Copy(registryPath, registryPath + ".compatibility-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fffffff") + ".bak");
                    HeadGeometry.AtomicWrite(registryPath, migrated);
                }
            }
            catch (Exception error) {
                registrySavingBlocked = true;
                ReportStateError("The project list could not be loaded. The original file is protected. Changes from this session are saved to " + registryPath + ".recovery.json.\n" + error.Message);
            }
        }
        registry.Folders ??= [];
        projects.Clear();
        foreach (var project in registry.Projects) projects.Add(project);
        var folderIds = registry.Folders.Select(folder => folder.Id).ToHashSet();
        foreach (var project in projects)
            if (project.FolderId is Guid id && !folderIds.Contains(id)) project.FolderId = null;
        if (projects.Count == 0) { var project = NewProject(1); projects.Add(project); }
        registryNeedsPersist = false;
        foreach (var project in projects) registryNeedsPersist |= NormalizeInferenceModelPaths(project);
        selectedProject = projects.FirstOrDefault(x => x.Id == registry.SelectedProjectID) ?? projects.FirstOrDefault();
    }

    bool NormalizeInferenceModelPaths(ProjectRecord project)
    {
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        if (!Directory.Exists(resources)) return false;
        var changed = false;
        var modelName = ModelName(project.Settings.Inference.ModelConfig);
        if (string.IsNullOrWhiteSpace(modelName)) modelName = "Local 3 Views";
        var config = Path.Combine(resources, modelName + ".yaml");
        if (File.Exists(config) && !File.Exists(project.Settings.Inference.ModelConfig))
        {
            project.Settings.Inference.ModelConfig = config;
            changed = true;
        }
        var checkpointName = Path.GetFileNameWithoutExtension(project.Settings.Inference.ModelCheckpoint);
        if (string.IsNullOrWhiteSpace(checkpointName)) checkpointName = modelName;
        var checkpoint = Path.Combine(resources, checkpointName + ".pth");
        if (File.Exists(checkpoint) && !File.Exists(project.Settings.Inference.ModelCheckpoint))
        {
            project.Settings.Inference.ModelCheckpoint = checkpoint;
            changed = true;
        }
        return changed;
    }

    void LoadProjectLogs()
    {
        if (File.Exists(logsPath))
        {
            try
            {
                foreach (var pair in JsonSerializer.Deserialize<Dictionary<Guid, string>>(File.ReadAllText(logsPath), jsonOptions) ?? [])
                    legacyProjectLogs[pair.Key] = pair.Value;
            }
            catch { legacyProjectLogs.Clear(); }
        }
        foreach (var project in projects)
        {
            var activityPath = ProjectActivityLogPath(project);
            if (activityPath != null && File.Exists(activityPath))
            {
                try
                {
                    var savedText = File.ReadAllText(activityPath);
                    var normalizedText = NormalizeActivityLog(savedText);
                    projectLogs[project.Id] = normalizedText;
                    legacyProjectLogs.Remove(project.Id);
                    if (!string.Equals(savedText, normalizedText, StringComparison.Ordinal)) SaveProjectLog(project.Id);
                }
                catch { }
            }
            else if (legacyProjectLogs.TryGetValue(project.Id, out var oldLog))
            {
                projectLogs[project.Id] = NormalizeActivityLog(oldLog);
                if (SaveProjectLog(project.Id)) legacyProjectLogs.Remove(project.Id);
            }
            if (LatestTechnicalLogPath(project) is string path) technicalLogPaths[project.Id] = path;
        }
        SaveLegacyProjectLogs();
    }

    void SaveProjectLogs()
    {
        foreach (var pair in projectLogs.ToArray())
        {
            if (SaveProjectLog(pair.Key)) legacyProjectLogs.Remove(pair.Key);
            else legacyProjectLogs[pair.Key] = pair.Value;
        }
        SaveLegacyProjectLogs();
    }

    bool SaveProjectLog(Guid projectId)
    {
        var project = projects.FirstOrDefault(item => item.Id == projectId);
        var activityPath = project == null ? null : ProjectActivityLogPath(project);
        if (activityPath == null) return false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(activityPath)!);
            var temporaryPath = activityPath + ".tmp";
            File.WriteAllText(temporaryPath, projectLogs.TryGetValue(projectId, out var value) ? value : "", new UTF8Encoding(false));
            File.Move(temporaryPath, activityPath, true);
            return true;
        }
        catch { return false; }
    }

    static string NormalizeActivityLog(string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        return string.Join(Environment.NewLine, lines.TakeLast(400));
    }

    void SaveLegacyProjectLogs()
    {
        if (string.IsNullOrWhiteSpace(logsPath)) return;
        if (legacyProjectLogs.Count == 0)
        {
            try { if (File.Exists(logsPath)) File.Delete(logsPath); } catch { }
            return;
        }
        try { File.WriteAllText(logsPath, JsonSerializer.Serialize(legacyProjectLogs, jsonOptions)); } catch { }
    }

    static string? ProjectLogDirectory(ProjectRecord project) => string.IsNullOrWhiteSpace(project.SaveLocation)
        ? null
        : ResolveProjectLogDirectory(project.SaveLocation);

    static string? ResolveProjectLogDirectory(string location)
    {
        try { return Path.Combine(Path.GetFullPath(location), "Logs"); }
        catch { return null; }
    }

    static string? ProjectActivityLogPath(ProjectRecord project) => ProjectLogDirectory(project) is string directory
        ? Path.Combine(directory, "Activity.log")
        : null;

    string TechnicalLogPath(ProjectRecord project, Stage stage, Guid runId, DateTime startedAt)
    {
        var directory = ProjectLogDirectory(project)
            ?? Path.Combine(appData, "Logs", project.Id.ToString("D"));
        var filename = $"{startedAt.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture)}-{stage.Value}-{runId.ToString("N")[..8]}.log";
        return Path.Combine(directory, filename);
    }

    static string? LatestTechnicalLogPath(ProjectRecord project)
    {
        var directory = ProjectLogDirectory(project);
        if (directory == null || !Directory.Exists(directory)) return null;
        try
        {
            return Directory.EnumerateFiles(directory, "*.log", SearchOption.TopDirectoryOnly)
                .Where(path => !string.Equals(Path.GetFileName(path), "Activity.log", StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
        }
        catch { return null; }
    }

    bool stateWarningVisible;
    void ReportStateError(string message)
    {
        System.Diagnostics.Debug.WriteLine(message);
        if (stateWarningVisible || shutdownCleanupDone) return;
        stateWarningVisible = true;
        DispatcherQueue.TryEnqueue(async () => {
            try { await ShowDialogAsync(new ContentDialog { Title = "Could not save app state", Content = message, CloseButtonText = "OK" }); }
            finally { stateWarningVisible = false; }
        });
    }
    void EnsureStateDirectory(string path)
    {
        try { Directory.CreateDirectory(path); }
        catch (Exception error) { ReportStateError(path + "\n" + error.Message); }
    }
    void SaveStateFile(string path, string text)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try { HeadGeometry.AtomicWrite(path, text); }
        catch (Exception error) { ReportStateError(path + "\n" + error.Message); }
    }

    void Persist()
    {
        if (registrySavingBlocked) {
            var recovery = new ProjectRegistry { Projects = projects.ToList(), SelectedProjectID = selectedProject?.Id, Environment = environment, Folders = registry.Folders };
            SaveStateFile(registryPath + ".recovery.json", JsonSerializer.Serialize(recovery, jsonOptions));
            return;
        }
        registry = new ProjectRegistry { Projects = projects.ToList(), SelectedProjectID = selectedProject?.Id, Environment = environment, Folders = registry.Folders };
        SaveStateFile(registryPath, JsonSerializer.Serialize(registry, jsonOptions));
    }

    void LoadViewerStates()
    {
        if (!File.Exists(viewerStatePath)) return;
        try { foreach (var pair in JsonSerializer.Deserialize<Dictionary<Guid, ProjectViewerState>>(File.ReadAllText(viewerStatePath), jsonOptions) ?? []) viewerStates[pair.Key] = pair.Value; } catch { viewerStates.Clear(); }
    }
    void SaveViewerStates() { SaveStateFile(viewerStatePath, JsonSerializer.Serialize(viewerStates, jsonOptions)); }
    void LoadUiState() { if (!File.Exists(uiStatePath)) return; try { var state = JsonSerializer.Deserialize<WindowUiState>(File.ReadAllText(uiStatePath), jsonOptions); if (state != null) { projectsExpandedWidth = state.ProjectsWidth; liveLogExpandedHeight = state.LiveLogHeight; settingsExpandedWidth = state.SettingsWidth; } } catch { } }
    void SaveUiState() { SaveStateFile(uiStatePath, JsonSerializer.Serialize(new WindowUiState { ProjectsWidth = projectsExpandedWidth, LiveLogHeight = liveLogExpandedHeight, SettingsWidth = settingsExpandedWidth }, jsonOptions)); }
    string FindPackageRoot() { var current = new DirectoryInfo(AppContext.BaseDirectory); while (current != null) { if (File.Exists(Path.Combine(current.FullName, "pyproject.toml")) && Directory.Exists(Path.Combine(current.FullName, "HRTFCalculation"))) return current.FullName; current = current.Parent; } return AppContext.BaseDirectory; }
    EnvironmentConfig DefaultEnvironment()
    {
        var external = Path.Combine(packageRoot, "External");
        var bin = Path.Combine(external, "bin");
        return new EnvironmentConfig { UvExecutable = Path.Combine(bin, "uv.exe"), NumCalcExecutable = Path.Combine(bin, "NumCalc.exe"), MeshGradingExecutable = Path.Combine(bin, "hrtf_mesh_grading.exe"), ExternalDir = external };
    }
    ProjectRecord Clone(ProjectRecord project) => JsonSerializer.Deserialize<ProjectRecord>(JsonSerializer.Serialize(project, jsonOptions), jsonOptions) ?? project;

    string? PreprocessingMesh(ProjectRecord project, string side)
    {
        if (project.Settings.ManualPPM.Enabled)
            return FitIsCurrent(project, side) ? project.Settings.ManualPPM.For(side)?.Mesh : null;
        return InferenceIsAutomatic(project) ? PredictionMesh(project, side) : SourceEar(project, side);
    }

    string? PredictionMesh(ProjectRecord project, string side)
    {
        var raw = SourceEar(project, side);
        if (string.IsNullOrWhiteSpace(raw) || string.IsNullOrWhiteSpace(project.SaveLocation)) return null;
        var folder = Path.Combine(project.SaveLocation, side == "left" ? project.Settings.Inference.PredictionLeftFolder : project.Settings.Inference.PredictionRightFolder);
        if (!Directory.Exists(folder)) return null;
        var stem = Path.GetFileNameWithoutExtension(raw);
        foreach (var name in new[] { $"Prediction_{stem}.stl", $"{stem}.stl" })
        {
            var path = Path.Combine(folder, name);
            if (File.Exists(path)) return path;
        }
        var candidates = Directory.EnumerateFiles(folder).Where(x => Path.GetExtension(x).Equals(".stl", StringComparison.OrdinalIgnoreCase)).ToArray();
        return candidates.Length == 1 && Path.GetFileName(candidates[0]).StartsWith("Prediction_", StringComparison.OrdinalIgnoreCase) ? candidates[0] : null;
    }

    static bool SamePath(string? left, string? right) => !string.IsNullOrWhiteSpace(left) && !string.IsNullOrWhiteSpace(right) &&
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    bool PositionMatchesMesh(ManualMicrophonePosition? position, string? mesh) => position != null && SamePath(position.MeshPath, mesh) &&
        position.MeshIdentity == MeshIdentity(mesh!) && double.IsFinite(position.X) && double.IsFinite(position.Y) && double.IsFinite(position.Z);

    string SideForPath(string path) => IsLeftMesh(path) ? "left" : IsRightMesh(path) ? "right" : "";
    string ArtifactSide(Artifact artifact) => artifact.Side ?? SideForPath(artifact.Path);
    bool IsLeftMesh(string path) => path.Contains("left", StringComparison.OrdinalIgnoreCase);
    bool IsRightMesh(string path) => path.Contains("right", StringComparison.OrdinalIgnoreCase);
    ManualMicrophonePosition? ManualPosition(ProjectRecord project, string side) => side == "left" ? project.Settings.Preprocessing.SourcePositionInputLeft : project.Settings.Preprocessing.SourcePositionInputRight;
    bool ValidManualPosition(ProjectRecord project, string side) => PositionMatchesMesh(ManualPosition(project, side), PreprocessingMesh(project, side));
    void InvalidateManualPositions(ProjectRecord project)
    {
        foreach (var side in new[] { "left", "right" })
        {
            var position = ManualPosition(project, side);
            if (position == null) continue;
            var mesh = PreprocessingMesh(project, side);
            // Missing or still-pending fingerprints must not erase saved positions.
            if (string.IsNullOrWhiteSpace(mesh)) continue;
            var identity = MeshIdentity(mesh);
            if (string.IsNullOrEmpty(identity)) continue;
            if (SamePath(position.MeshPath, mesh) && position.MeshIdentity == identity &&
                double.IsFinite(position.X) && double.IsFinite(position.Y) && double.IsFinite(position.Z)) continue;
            if (side == "left") project.Settings.Preprocessing.SourcePositionInputLeft = null;
            else project.Settings.Preprocessing.SourcePositionInputRight = null;
        }
    }
    string MeshIdentity(string path) { try { var file = new FileInfo(path); return Path.GetFullPath(path).ToLowerInvariant() + ":" + file.Length + ":" + file.LastWriteTimeUtc.Ticks + ":" + FileFingerprints.Hash(path); } catch { return ""; } }

    System.Numerics.Vector3? MicrophonePosition(string meshPath)
    {
        if (selectedProject == null) return null;
        foreach (var side in new[] { "left", "right" })
        {
            var sideTitle = CultureInfo.InvariantCulture.TextInfo.ToTitleCase(side);
            var simulationMesh = Path.Combine(selectedProject.SaveLocation, "Intermediates", sideTitle, "graded_head.ply");
            if (SamePath(meshPath, simulationMesh))
            {
                var parameters = Path.Combine(selectedProject.SaveLocation, "Projects", sideTitle, "parameters.json");
                try
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(parameters));
                    var values = document.RootElement.GetProperty("sourceCenter").EnumerateArray().Select(x => (float)x.GetDouble() * 1000).ToArray();
                    return values.Length == 3 && values.All(float.IsFinite) ? new System.Numerics.Vector3(values[0], values[1], values[2]) : null;
                }
                catch { return null; }
            }
            if (!SamePath(meshPath, PreprocessingMesh(selectedProject, side))) continue;
            var position = placementProjectId == selectedProject.Id && placementSide == side && PositionMatchesMesh(pendingMicrophonePosition, meshPath)
                ? pendingMicrophonePosition : ValidManualPosition(selectedProject, side) ? ManualPosition(selectedProject, side) : null;
            if (position != null) return new System.Numerics.Vector3((float)position.X, (float)position.Y, (float)position.Z);
        }
        return null;
    }

    sealed class ProjectRowUi
    {
        public Grid Root { get; }
        public TextBlock Name { get; }
        public TextBlock Status { get; }
        public ProgressRing Spinner { get; }

        public ProjectRowUi(ProjectRecord project, Action<ProjectRecord> select, Action<ProjectRecord> rename, Action duplicate, Action remove, Action<ProjectRecord, Guid?> move, IReadOnlyList<ProjectFolder> folders, bool nested)
        {
            Root = new Grid { Margin = new Thickness(nested ? 25 : 8, 7, 8, 7), Tag = project, HorizontalAlignment = HorizontalAlignment.Stretch };
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch };
            Name = new TextBlock { Text = project.Name, FontWeight = FontWeights.SemiBold, FontSize = 14 };
            Status = new TextBlock { Text = project.StatusText, FontSize = 11 };
            text.Children.Add(Name);
            text.Children.Add(Status);
            Root.Children.Add(text);
            Spinner = new ProgressRing { Width = 17, Height = 17, IsActive = false, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
            Grid.SetColumn(Spinner, 1);
            Root.Children.Add(Spinner);
            var menu = new MenuFlyout();
            var renameItem = new MenuFlyoutItem { Text = "Rename Project" };
            renameItem.Click += (_, _) => rename(project);
            var duplicateItem = new MenuFlyoutItem { Text = "Duplicate Project" };
            duplicateItem.Click += (_, _) => { select(project); duplicate(); };
            var removeItem = new MenuFlyoutItem { Text = "Remove Project" };
            removeItem.Click += (_, _) => { select(project); remove(); };
            var moveItem = new MenuFlyoutSubItem { Text = "Move to Folder" };
            menu.Opening += (_, _) =>
            {
                moveItem.Items.Clear();
                var unfiled = new MenuFlyoutItem { Text = "No Folder" };
                unfiled.Click += (_, _) => move(project, null);
                moveItem.Items.Add(unfiled);
                foreach (var folder in folders)
                {
                    var folderItem = new MenuFlyoutItem { Text = folder.Name, Tag = folder.Id };
                    folderItem.Click += (_, _) => move(project, folder.Id);
                    moveItem.Items.Add(folderItem);
                }
            };
            menu.Items.Add(renameItem);
            menu.Items.Add(duplicateItem);
            menu.Items.Add(moveItem);
            menu.Items.Add(removeItem);
            Root.ContextFlyout = menu;
        }
    }
}

record Artifact(string Title, string Path, string? Side = null)
{
    public bool IsPressure => System.IO.Path.GetFileName(Path).Equals("NC.inp",StringComparison.OrdinalIgnoreCase) && File.Exists(Path) && Directory.Exists(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!,"be.out"));
    public bool Exists => File.Exists(Path) || IsPressure;
    public bool IsMesh => new[] { ".stl", ".ply" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
    public bool IsImage => new[] { ".jpg", ".jpeg", ".png", ".bmp", ".gif" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
    public bool IsText => new[] { ".txt", ".csv", ".json", ".yaml", ".yml", ".log", ".out" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
}

record Stage(string Value, string Title)
{
    public static readonly Stage ScanPreparation = new("scan-preparation", "Scan Preparation");
    public static readonly Stage Inference = new("inference", "Mesh2PPM Inference");
    public static readonly Stage Preprocessing = new("preprocessing", "Preprocessing");
    public static readonly Stage Numcalc = new("numcalc", "NumCalc");
    public static readonly Stage Postprocessing = new("postprocessing", "Postprocess");
    public static Stage[] GetValues() => [ScanPreparation, Inference, Preprocessing, Numcalc, Postprocessing];
}

class ProjectRegistry { public string NumericFormat { get; set; } = "invariant-1"; public List<ProjectRecord> Projects { get; set; } = []; public Guid? SelectedProjectID { get; set; } public EnvironmentConfig Environment { get; set; } = new(); public List<ProjectFolder> Folders { get; set; } = []; }
class ProjectFolder { public Guid Id { get; set; } = Guid.NewGuid(); public string Name { get; set; } = ""; public bool IsExpanded { get; set; } = true; }
class WindowUiState { public double ProjectsWidth { get; set; } = 280; public double LiveLogHeight { get; set; } = 170; public double SettingsWidth { get; set; } = 390; }
class ProjectViewerState { public string? SelectedArtifactPath { get; set; } public Dictionary<string, MeshCameraState> CameraByArtifact { get; set; } = []; }
class MeshCameraState { public double TargetX { get; set; } public double TargetY { get; set; } public double TargetZ { get; set; } public double Yaw { get; set; } public double Pitch { get; set; } public double Distance { get; set; } }
class SettingHelpEntry { public string Id { get; set; } = ""; public string Title { get; set; } = ""; public string Description { get; set; } = ""; public List<SettingHelpPublication> Publications { get; set; } = []; }
class SettingHelpPublication { public string Title { get; set; } = ""; public string Url { get; set; } = ""; }


[ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IFileDialogNative
{
    [PreserveSig] int Show(IntPtr owner);
    void SetFileTypes(uint count, IntPtr filters);
    void SetFileTypeIndex(uint index);
    void GetFileTypeIndex(out uint index);
    void Advise(IntPtr events, out uint cookie);
    void Unadvise(uint cookie);
    void SetOptions(uint options);
    void GetOptions(out uint options);
    void SetDefaultFolder(IShellItemNative folder);
    void SetFolder(IShellItemNative folder);
    void GetFolder(out IShellItemNative folder);
    void GetCurrentSelection(out IShellItemNative item);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
    void GetResult(out IShellItemNative item);
    void AddPlace(IShellItemNative place, uint alignment);
    void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
    void Close(int hr);
    void SetClientGuid(ref Guid guid);
    void ClearClientData();
    void SetFilter(IntPtr filter);
}

[ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IFileOpenDialogNative : IFileDialogNative
{
    void GetResults(out IShellItemArrayNative results);
    void GetSelectedItems(out IShellItemArrayNative results);
}

[ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellItemNative
{
    void BindToHandler(IntPtr bindContext, ref Guid bhid, ref Guid riid, out IntPtr result);
    void GetParent(out IShellItemNative parent);
    void GetDisplayName(uint sigdnName, out IntPtr name);
    void GetAttributes(uint attributes, out uint result);
    void Compare(IShellItemNative item, uint hint, out int result);
}

[ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellItemArrayNative { }

static class NativeFileDialog
{
    const uint FOS_PICKFOLDERS = 0x20;
    const uint FOS_FORCEFILESYSTEM = 0x40;
    const uint FOS_FILEMUSTEXIST = 0x1000;
    const uint FOS_PATHMUSTEXIST = 0x800;
    const uint SIGDN_FILESYSPATH = 0x80058000;
    static readonly Guid ClsidFileOpenDialog = new("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7");
    static readonly Guid IidShellItem = new("43826D1E-E718-42EE-BC55-A1E261C37BFE");

    [DllImport("ole32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IFileOpenDialogNative dialog);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHCreateItemFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bindContext, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemNative item);
    [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr memory);

    public static string? Pick(IntPtr owner, string? folder, bool folders)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var clsid = ClsidFileOpenDialog;
        var iid = typeof(IFileOpenDialogNative).GUID;
        if (CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref iid, out var dialog) != 0) return null;
        try
        {
            dialog.SetOptions(FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | (folders ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST));
            var iidShellItem = IidShellItem;
            if (!string.IsNullOrWhiteSpace(folder) && SHCreateItemFromParsingName(folder, IntPtr.Zero, ref iidShellItem, out var start) == 0)
                dialog.SetFolder(start);
            var result = dialog.Show(owner);
            if (result == unchecked((int)0x800704C7)) return "";
            if (result != 0) return null;
            dialog.GetResult(out var item);
            item.GetDisplayName(SIGDN_FILESYSPATH, out var raw);
            try { return Marshal.PtrToStringUni(raw); } finally { CoTaskMemFree(raw); }
        }
        catch { return null; }
    }
}

sealed class CursorGrid : Grid
{
    public CursorGrid(InputSystemCursorShape shape)
    {
        Loaded += (_, _) => ProtectedCursor = InputSystemCursor.Create(shape);
    }

    public void SetCursor(InputSystemCursorShape value)
    {
        DispatcherQueue.TryEnqueue(() => ProtectedCursor = InputSystemCursor.Create(value));
    }
}

sealed class MeshInputController : InputController
{
    static bool Pressed(global::Windows.System.VirtualKey key) => (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key) & global::Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
    static NavigationAction Action(Microsoft.UI.Input.PointerPointProperties properties) => NavigationBindings.Mouse(properties.IsMiddleButtonPressed, properties.IsRightButtonPressed,
        Pressed(global::Windows.System.VirtualKey.Shift), Pressed(global::Windows.System.VirtualKey.Control));
    protected override bool IsStartRotate(Microsoft.UI.Input.PointerPointProperties properties) =>
        Action(properties) == NavigationAction.Orbit;

    protected override bool IsStartPan(Microsoft.UI.Input.PointerPointProperties properties) =>
        Action(properties) == NavigationAction.Pan;
    protected override bool IsStartZoom(Microsoft.UI.Input.PointerPointProperties properties) =>
        Action(properties) == NavigationAction.Zoom;
}

class MeshData
{
    public string Path { get; }
    public MeshGeometry3D Geometry { get; }
    public System.Numerics.Vector3 Center { get; }
    public double Scale { get; }
    public double MaximumDimension { get; }
    public MeshData(string path, MeshGeometry3D geometry, System.Numerics.Vector3 center, double scale, double maximumDimension) { Path = path; Geometry = geometry; Center = center; Scale = scale; MaximumDimension = maximumDimension; }
    public System.Numerics.Vector3 ToDisplay(System.Numerics.Vector3 raw) => (raw - Center) * (float)Scale;
    public System.Numerics.Vector3 ToRaw(System.Numerics.Vector3 display) => display / (float)Scale + Center;
}

static class MeshLoader
{
    static MeshGeometry3D NewGeometry() => new()
    {
        Positions = new Vector3Collection(),
        Indices = new IntCollection()
    };

    static (Vector3Collection Positions, IntCollection Indices) GetMeshCollections(MeshGeometry3D mesh)
    {
        if (mesh.Positions is not { } positions || mesh.Indices is not { } indices)
            throw new InvalidOperationException("Mesh geometry collections are not initialized.");
        return (positions, indices);
    }

    public static MeshData Load(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Mesh file was not found.", path);
        var mesh = NewGeometry();
        if (Path.GetExtension(path).Equals(".ply", StringComparison.OrdinalIgnoreCase)) LoadPly(path, mesh); else LoadStl(path, mesh);
        var (positions, indices) = GetMeshCollections(mesh);
        if (positions.Count == 0 || indices.Count < 3) throw new InvalidDataException($"Mesh contains no usable triangles: {path}");
        var min = new System.Numerics.Vector3(positions.Min(x => x.X), positions.Min(x => x.Y), positions.Min(x => x.Z));
        var max = new System.Numerics.Vector3(positions.Max(x => x.X), positions.Max(x => x.Y), positions.Max(x => x.Z));
        var center = (min + max) / 2;
        var maximum = Math.Max(max.X - min.X, Math.Max(max.Y - min.Y, max.Z - min.Z));
        var scale = 180 / Math.Max(maximum, 1);
        for (var i = 0; i < positions.Count; i++) positions[i] = (positions[i] - center) * (float)scale;
        CalculateNormals(mesh);
        mesh.UpdateBounds();
        return new MeshData(path, mesh, center, scale, maximum * scale);
    }

    static void LoadStl(string path, MeshGeometry3D mesh)
    {
        var (positions, indices) = GetMeshCollections(mesh);
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length >= 84)
        {
            var offset = 84;
            var count = BitConverter.ToUInt32(bytes, 80);
            var expected = 84L + count * 50L;
            if (expected == bytes.Length)
            {
                for (var i = 0; i < count; i++)
                {
                    if (offset + 50 > bytes.Length) throw new InvalidDataException($"Binary STL triangle {i} is truncated: {path}");
                    offset += 12;
                    var start = positions.Count;
                    for (var v = 0; v < 3; v++)
                    {
                        positions.Add(new System.Numerics.Vector3(BitConverter.ToSingle(bytes, offset), BitConverter.ToSingle(bytes, offset + 4), BitConverter.ToSingle(bytes, offset + 8)));
                        offset += 12;
                    }
                    indices.Add(start); indices.Add(start + 1); indices.Add(start + 2);
                    offset += 2;
                }
                return;
            }
        }
        var vertices = new List<System.Numerics.Vector3>(3);
        foreach (var line in File.ReadLines(path))
        {
            var p = line.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (p.Length == 0 || !p[0].Equals("vertex", StringComparison.OrdinalIgnoreCase)) continue;
            if (p.Length < 4 || !float.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) || !float.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var y) || !float.TryParse(p[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var z))
            {
                vertices.Clear();
                continue;
            }
            vertices.Add(new System.Numerics.Vector3(x, y, z));
            if (vertices.Count == 3)
            {
                var start = positions.Count;
                foreach (var vertex in vertices) positions.Add(vertex);
                indices.Add(start); indices.Add(start + 1); indices.Add(start + 2);
                vertices.Clear();
            }
        }
        if (indices.Count == 0) throw new InvalidDataException($"STL contains no usable triangles: {path}");
    }

    sealed class PlyElement
    {
        public string Name { get; init; } = "";
        public int Count { get; init; }
        public List<PlyProperty> Properties { get; } = [];
    }

    sealed class PlyProperty
    {
        public string Name { get; init; } = "";
        public bool IsList { get; init; }
        public string Type { get; init; } = "";
        public string? CountType { get; init; }
        public string? ItemType { get; init; }
    }

    static void LoadPly(string path, MeshGeometry3D mesh)
    {
        var (positions, indices) = GetMeshCollections(mesh);
        var bytes = File.ReadAllBytes(path);
        var headerEnd = FindPlyHeaderEnd(bytes);
        if (headerEnd < 0) throw new InvalidDataException($"PLY header is missing end_header: {path}");
        var header = Encoding.ASCII.GetString(bytes, 0, headerEnd);
        var elements = new List<PlyElement>();
        PlyElement? current = null;
        var format = "";
        foreach (var raw in header.Split('\n'))
        {
            var p = raw.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (p.Length == 0 || p[0].Equals("comment", StringComparison.OrdinalIgnoreCase) || p[0].Equals("obj_info", StringComparison.OrdinalIgnoreCase)) continue;
            if (p[0].Equals("format", StringComparison.OrdinalIgnoreCase) && p.Length >= 2) format = p[1].ToLowerInvariant();
            else if (p[0].Equals("element", StringComparison.OrdinalIgnoreCase) && p.Length >= 3 && int.TryParse(p[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var count))
            {
                current = new PlyElement { Name = p[1].ToLowerInvariant(), Count = count }; elements.Add(current);
            }
            else if (p[0].Equals("property", StringComparison.OrdinalIgnoreCase) && current != null)
            {
                if (p.Length >= 5 && p[1].Equals("list", StringComparison.OrdinalIgnoreCase)) current.Properties.Add(new PlyProperty { IsList = true, CountType = p[2].ToLowerInvariant(), ItemType = p[3].ToLowerInvariant(), Name = p[4] });
                else if (p.Length >= 3) current.Properties.Add(new PlyProperty { Type = p[1].ToLowerInvariant(), Name = p[2] });
            }
        }
        var vertexElement = elements.FirstOrDefault(e => e.Name == "vertex");
        var faceElement = elements.FirstOrDefault(e => e.Name == "face");
        if (vertexElement == null || vertexElement.Count <= 0 || faceElement == null || faceElement.Count < 0) throw new InvalidDataException($"PLY does not define usable vertex/face elements: {path}");
        var xProperty = vertexElement.Properties.FindIndex(p => p.Name.Equals("x", StringComparison.OrdinalIgnoreCase));
        var yProperty = vertexElement.Properties.FindIndex(p => p.Name.Equals("y", StringComparison.OrdinalIgnoreCase));
        var zProperty = vertexElement.Properties.FindIndex(p => p.Name.Equals("z", StringComparison.OrdinalIgnoreCase));
        if (xProperty < 0 || yProperty < 0 || zProperty < 0) throw new InvalidDataException($"PLY vertex element has no x/y/z properties: {path}");
        var faceList = faceElement.Properties.FirstOrDefault(p => p.IsList && (p.Name.Equals("vertex_indices", StringComparison.OrdinalIgnoreCase) || p.Name.Equals("vertex_index", StringComparison.OrdinalIgnoreCase))) ?? faceElement.Properties.FirstOrDefault(p => p.IsList);
        if (faceList == null) throw new InvalidDataException($"PLY face element has no vertex index list: {path}");

        if (format == "ascii")
        {
            using var reader = new StreamReader(new MemoryStream(bytes, headerEnd, bytes.Length - headerEnd), Encoding.ASCII, false);
            for (var i = 0; i < vertexElement.Count; i++)
            {
                var tokens = (reader.ReadLine() ?? "").Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (tokens.Length < vertexElement.Properties.Count || !float.TryParse(tokens[xProperty], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) || !float.TryParse(tokens[yProperty], NumberStyles.Float, CultureInfo.InvariantCulture, out var y) || !float.TryParse(tokens[zProperty], NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) throw new InvalidDataException($"PLY vertex {i} is invalid: {path}");
                positions.Add(new System.Numerics.Vector3(x, y, z));
            }
            for (var i = 0; i < faceElement.Count; i++)
            {
                var tokens = (reader.ReadLine() ?? "").Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (tokens.Length == 0 || !int.TryParse(tokens[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) || count < 3 || tokens.Length < count + 1) continue;
                var faceIndices = new int[count]; var valid = true;
                for (var j = 0; j < count; j++) if (!int.TryParse(tokens[j + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out faceIndices[j]) || faceIndices[j] < 0 || faceIndices[j] >= vertexElement.Count) { valid = false; break; }
                if (!valid) continue;
                for (var j = 1; j < count - 1; j++) { indices.Add(faceIndices[0]); indices.Add(faceIndices[j]); indices.Add(faceIndices[j + 1]); }
            }
        }
        else if (format == "binary_little_endian")
        {
            using var reader = new BinaryReader(new MemoryStream(bytes, headerEnd, bytes.Length - headerEnd), Encoding.ASCII, false);
            foreach (var element in elements)
            {
                for (var i = 0; i < element.Count; i++)
                {
                    if (element == vertexElement)
                    {
                        var coords = new float[3];
                        foreach (var property in element.Properties)
                        {
                            if (property.IsList) { var n = checked((int)ReadPlyScalar(reader, property.CountType!)); for (var j = 0; j < n; j++) _ = ReadPlyScalar(reader, property.ItemType!); continue; }
                            var value = ReadPlyScalar(reader, property.Type);
                            if (property.Name.Equals("x", StringComparison.OrdinalIgnoreCase)) coords[0] = (float)value;
                            else if (property.Name.Equals("y", StringComparison.OrdinalIgnoreCase)) coords[1] = (float)value;
                            else if (property.Name.Equals("z", StringComparison.OrdinalIgnoreCase)) coords[2] = (float)value;
                        }
                        positions.Add(new System.Numerics.Vector3(coords[0], coords[1], coords[2]));
                    }
                    else if (element == faceElement)
                    {
                        List<int>? faceIndices = null;
                        foreach (var property in element.Properties)
                        {
                            if (!property.IsList) { _ = ReadPlyScalar(reader, property.Type); continue; }
                            var n = checked((int)ReadPlyScalar(reader, property.CountType!)); var values = new List<int>(Math.Max(0, n));
                            for (var j = 0; j < n; j++) { var value = ReadPlyScalar(reader, property.ItemType!); values.Add(value is < 0 or > int.MaxValue ? -1 : (int)value); }
                            if (ReferenceEquals(property, faceList)) faceIndices = values;
                        }
                        if (faceIndices == null || faceIndices.Count < 3 || faceIndices.Any(index => index < 0 || index >= vertexElement.Count)) continue;
                        for (var j = 1; j < faceIndices.Count - 1; j++) { indices.Add(faceIndices[0]); indices.Add(faceIndices[j]); indices.Add(faceIndices[j + 1]); }
                    }
                    else
                    {
                        foreach (var property in element.Properties)
                        {
                            if (property.IsList) { var n = checked((int)ReadPlyScalar(reader, property.CountType!)); for (var j = 0; j < n; j++) _ = ReadPlyScalar(reader, property.ItemType!); }
                            else _ = ReadPlyScalar(reader, property.Type);
                        }
                    }
                }
            }
        }
        else throw new InvalidDataException($"Unsupported PLY format '{format}'. Supported formats are ASCII and binary_little_endian: {path}");
        if (indices.Count == 0) throw new InvalidDataException($"PLY contains no usable faces: {path}");
    }

    static int FindPlyHeaderEnd(byte[] bytes)
    {
        var marker = Encoding.ASCII.GetBytes("end_header");
        for (var i = 0; i <= bytes.Length - marker.Length; i++)
        {
            var match = true; for (var j = 0; j < marker.Length; j++) if (bytes[i + j] != marker[j]) { match = false; break; }
            if (!match) continue;
            var end = i + marker.Length; while (end < bytes.Length && (bytes[end] == 13 || bytes[end] == 10)) { end++; if (bytes[end - 1] == 10) break; }
            return end;
        }
        return -1;
    }

    static double ReadPlyScalar(BinaryReader reader, string type) => type switch
    {
        "char" or "int8" => reader.ReadSByte(), "uchar" or "uint8" => reader.ReadByte(), "short" or "int16" => reader.ReadInt16(), "ushort" or "uint16" => reader.ReadUInt16(), "int" or "int32" => reader.ReadInt32(), "uint" or "uint32" => reader.ReadUInt32(), "float" or "float32" => reader.ReadSingle(), "double" or "float64" => reader.ReadDouble(), _ => throw new InvalidDataException($"Unsupported PLY property type '{type}'.")
    };

    public static MeshGeometry3D CreateSphere(System.Numerics.Vector3 center, double radius)
    {
        var mesh = NewGeometry(); var (positions, indices) = GetMeshCollections(mesh); const int slices = 16; const int stacks = 8;
        for (var stack = 0; stack <= stacks; stack++) { var phi = Math.PI * stack / stacks; for (var slice = 0; slice <= slices; slice++) { var theta = 2 * Math.PI * slice / slices; positions.Add(center + new System.Numerics.Vector3((float)(radius * Math.Sin(phi) * Math.Cos(theta)), (float)(radius * Math.Sin(phi) * Math.Sin(theta)), (float)(radius * Math.Cos(phi)))); } }
        for (var stack = 0; stack < stacks; stack++) for (var slice = 0; slice < slices; slice++) { var first = stack * (slices + 1) + slice; var second = first + slices + 1; indices.Add(first); indices.Add(second); indices.Add(first + 1); indices.Add(first + 1); indices.Add(second); indices.Add(second + 1); }
        CalculateNormals(mesh);
        mesh.UpdateBounds(); return mesh;
    }

    static void CalculateNormals(MeshGeometry3D mesh)
    {
        var (positions, indices) = GetMeshCollections(mesh);
        var normals = new Vector3Collection();
        for (var i = 0; i < positions.Count; i++)
            normals.Add(System.Numerics.Vector3.Zero);
        for (var i = 0; i + 2 < indices.Count; i += 3)
        {
            var ia = indices[i];
            var ib = indices[i + 1];
            var ic = indices[i + 2];
            if (ia < 0 || ib < 0 || ic < 0 || ia >= positions.Count || ib >= positions.Count || ic >= positions.Count)
                continue;
            var face = System.Numerics.Vector3.Cross(positions[ib] - positions[ia], positions[ic] - positions[ia]);
            if (face.LengthSquared() < 1e-12f)
                continue;
            normals[ia] += face;
            normals[ib] += face;
            normals[ic] += face;
        }
        for (var i = 0; i < normals.Count; i++)
        {
            var normal = normals[i];
            normals[i] = normal.LengthSquared() < 1e-12f ? new System.Numerics.Vector3(0, 0, 1) : System.Numerics.Vector3.Normalize(normal);
        }
        mesh.Normals = normals;
    }
}
