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
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using WinRT.Interop;

namespace Pinna2HRTF.Windows;

public partial class MainWindow : Window
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeLibrary(IntPtr hModule);
    const uint LoadLibrarySearchDllLoadDir = 0x00000100;
    const uint LoadLibrarySearchDefaultDirs = 0x00001000;
    // Mesh coordinates are expressed in millimetres by the pipeline.  The
    // marker radius is deliberately independent of the mesh bounds; only the
    // loader's display transform is applied when creating the viewer sphere.
    const double MicrophoneMarkerRadiusMeshUnits = 0.5;
    readonly ObservableCollection<ProjectRecord> projects = [];
    readonly ObservableCollection<Artifact> artifacts = [];
    readonly Dictionary<Guid, Process> runningProcesses = [];
    readonly Dictionary<Guid, Stage> runningStages = [];
    readonly Dictionary<Guid, Queue<Stage>> queuedStages = [];
    readonly Dictionary<Guid, HashSet<Stage>> failedStages = [];
    readonly Dictionary<Guid, string> projectLogs = [];
    readonly Dictionary<Guid, ProjectRowUi> projectRows = [];
    readonly Dictionary<Guid, ProjectViewerState> viewerStates = [];
    readonly Dictionary<string, SettingHelpEntry> settingHelp = [];
    readonly JsonSerializerOptions jsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true, Converters = { new JsonStringEnumConverter() } };
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer statusTimer;
    readonly Dictionary<string, Control> settingControls = [];
    readonly List<Button> stageButtons = [];
    readonly List<TextBlock> stageStatusLabels = [];
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
    Grid? contentGrid;
    ColumnDefinition? projectsColumn;
    ColumnDefinition? settingsColumn;
    ListView projectList = new();
    ComboBox artifactPicker = new();
    TextBlock selectedArtifactText = new();
    Image imagePreview = new();
    TextBlock viewerPlaceholder = new();
    Border viewerInteractionHint = new();
    Viewport3DX meshViewport = new();
    Border meshViewerBackground = new();
    CursorGrid? meshViewportHost;
    Border? projectsPaneBorder;
    Border? previewPanelBorder;
    Border? logPanelBorder;
    Border? settingsPaneBorder;
    TextBlock? projectsHeaderText;
    FrameworkElement? projectsBody;
    Expander? projectsExpander;
    ColumnDefinition? projectsSplitterColumn;
    FrameworkElement? projectsSplitter;
    Expander? logExpander;
    RowDefinition? centerLogRow;
    RowDefinition? logSplitterRow;
    FrameworkElement? logSplitter;
    bool projectsCollapsed;
    bool logCollapsed;
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
    Button placeLeftButton = new();
    Button placeRightButton = new();
    Button automaticPositionButton = new();
    Button donePositionButton = new();
    Button cancelPositionButton = new();
    Button runAllButton = new();
    readonly TextBox projectNameBox = new();
    readonly TextBox leftEarBox = new();
    readonly TextBox rightEarBox = new();
    readonly TextBox saveLocationBox = new();
    readonly TextBox evaluationGridBox = new();
    readonly TextBox headRadiusBox = new();
    readonly TextBox minFrequencyBox = new();
    readonly TextBox maxFrequencyBox = new();
    readonly TextBox frequencyStepsBox = new();
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
    readonly CheckBox useHeadRadiusBox = new();
    readonly CheckBox adaptiveFmmLengthBox = new();
    readonly CheckBox normalizeHrtfsBox = new();
    readonly ComboBox modelPicker = new();
    readonly TextBlock[] stageStatus = [new(), new(), new(), new()];

    public MainWindow()
    {
        InitializeComponent();
        Root.Loaded += WindowLoaded;
        Root.ActualThemeChanged += (_, _) => UpdateViewerAppearance();
        statusTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        statusTimer.Interval = TimeSpan.FromSeconds(2);
        statusTimer.Tick += (_, _) => { RefreshNumCalcStatus(); RefreshPipelineStatus(); };
        ExtendsContentIntoTitleBar = true;
        Activated += (_, _) => UpdateViewerAppearance();
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(id);
        appWindow.Title = "Pinna2HRTF";
        try
        {
            var icon = Path.Combine(AppContext.BaseDirectory, "app_icon.ico");
            if (!File.Exists(icon)) icon = Path.Combine(AppContext.BaseDirectory, "Resources", "app_icon.ico");
            if (File.Exists(icon)) appWindow.SetIcon(icon);
        }
        catch { }
        appWindow.Closing += AppWindowClosing;
    }

    void WindowLoaded(object sender, RoutedEventArgs e)
    {
        BuildInterface();
        packageRoot = FindPackageRoot();
        appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinna2HRTF");
        registryPath = Path.Combine(appData, "projects.json");
        viewerStatePath = Path.Combine(appData, "viewer-state.json");
        uiStatePath = Path.Combine(appData, "ui-state.json");
        Directory.CreateDirectory(appData);
        Directory.CreateDirectory(Path.Combine(appData, "Cache", "matplotlib"));
        Directory.CreateDirectory(Path.Combine(appData, "Cache", "python"));
        Directory.CreateDirectory(Path.Combine(appData, "Blender", "config"));
        Directory.CreateDirectory(Path.Combine(appData, "Blender", "scripts"));
        Directory.CreateDirectory(Path.Combine(appData, "Blender", "datafiles"));
        LoadSettingHelp();
        LoadRegistry();
        LoadViewerStates();
        LoadUiState();
        SetProjectsCollapsed(projectsCollapsed, false);
        SetLogCollapsed(logCollapsed, false);
        if (settingsColumn != null) settingsColumn.Width = new GridLength(Math.Clamp(settingsExpandedWidth, 320, 560));
        // Windows builds always use the bundled native tools. Older registries
        // may contain absolute paths from a previous build directory; ignoring
        // those paths prevents preprocessing from loading stale/missing DLLs.
        environment = DefaultEnvironment();
        foreach (var project in projects)
        {
            if (int.TryParse(project.Settings.Preprocessing.FrequencyStepCount, out var steps))
                project.Settings.Preprocessing.FrequencyStepCount = Math.Max(steps, 2).ToString(CultureInfo.InvariantCulture);
            InvalidateManualPositions(project);
        }
        RefreshModelOptions();
        RefreshProjectList();
        if (selectedProject != null)
            projectList.SelectedIndex = projects.IndexOf(selectedProject);
        LoadSelectedProject();
        // Viewport3DX creates its item collection when its template is applied. Defer
        // the first artifact load until the newly-created visual tree has completed layout.
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
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) });
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var titleBar = BuildTitleBar();
        Grid.SetRow(titleBar, 0);
        Root.Children.Add(titleBar);

        contentGrid = new Grid { Background = appBackgroundBrush };
        projectsColumn = new ColumnDefinition
        {
            Width = new GridLength(projectsExpandedWidth), MinWidth = 240, MaxWidth = 520
        };
        contentGrid.ColumnDefinitions.Add(projectsColumn);
        projectsSplitterColumn = new ColumnDefinition { Width = new GridLength(12) };
        contentGrid.ColumnDefinitions.Add(projectsSplitterColumn);
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 420 });
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12), MinWidth = 12, MaxWidth = 12 });
        settingsColumn = new ColumnDefinition { Width = new GridLength(settingsExpandedWidth), MinWidth = 320, MaxWidth = 560 };
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
        Grid.SetColumn(settingsSplitter, 3);
        contentGrid.Children.Add(settingsSplitter);
        var settings = BuildSettingsPane();
        Grid.SetColumn(settings, 4);
        contentGrid.Children.Add(settings);
        SetProjectsCollapsed(projectsCollapsed, false);
    }

    Grid BuildSplitter(bool vertical, DragDeltaEventHandler handler)
    {
        // Reserve the proven 12-pixel interaction slot. The interaction host and
        // Thumb remain transparent; only the centered one-pixel guide is visible.
        var host = new CursorGrid(vertical ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.SizeNorthSouth)
        {
            Background = new SolidColorBrush(Colors.Transparent),
            IsHitTestVisible = true
        };
        
        if (vertical)
        {
            // Vertical splitter: fills the 12-pixel column and stretches height.
            host.VerticalAlignment = VerticalAlignment.Stretch;
        }
        else
        {
            // Horizontal splitter: fills the 12-pixel row and stretches width.
            host.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        
        // Visual indicator line: one pixel, centered in the interaction slot.
        var line = new Border
        {
            Width = vertical ? 1 : double.NaN,
            Height = vertical ? double.NaN : 1,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Background = borderBrush,
            IsHitTestVisible = false
        };
        
        // The Thumb fills the complete slot and remains the drag target.
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
        var titleBar = new Grid { Height = 36, Background = new SolidColorBrush(Colors.Transparent), HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
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
        SetTitleBar(titleBar);
        return titleBar;
    }

    void ProjectSplitterDragged(object sender, DragDeltaEventArgs e)
    {
        if (projectsCollapsed || projectsColumn == null) return;
        projectsExpandedWidth = Math.Clamp(projectsExpandedWidth + e.HorizontalChange, 240, 520);
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
        projectsCollapsed = collapsed;
        if (projectsExpander != null)
        {
            if (projectsExpander.IsExpanded == collapsed) projectsExpander.IsExpanded = !collapsed;
            projectsExpander.Header = collapsed ? null : projectsHeaderText;
            projectsExpander.VerticalAlignment = collapsed ? VerticalAlignment.Top : VerticalAlignment.Stretch;
            // WinUI's static header padding reserves room even with no title.
            // Apply the template first; Loaded can fire before its header exists.
            projectsExpander.ApplyTemplate();
            if (FindDescendant<ToggleButton>(projectsExpander) is { } header)
                header.Padding = new Thickness(0);
            ToolTipService.SetToolTip(projectsExpander, collapsed ? "Expand Projects" : "Collapse Projects");
        }
        // Hide the body immediately: the vertical Expander animation must not
        // keep the project's list width in the measurement of the compact rail.
        if (projectsBody != null) projectsBody.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (projectsColumn != null)
        {
            projectsColumn.MinWidth = collapsed ? 0 : 240;
            projectsColumn.Width = collapsed ? GridLength.Auto : new GridLength(Math.Clamp(projectsExpandedWidth, 240, 520));
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
        project.Items.Add(MenuItem("Import Project", ImportProjectClicked, "Ctrl+Shift+O"));
        project.Items.Add(MenuItem("Duplicate Project", DuplicateProjectClicked, "Ctrl+D"));
        project.Items.Add(new MenuFlyoutSeparator());
        project.Items.Add(MenuItem("Delete Project", RemoveProjectClicked, "Ctrl+Delete"));
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
        pipeline.Items.Add(MenuItem("Stop", StopClicked, "Ctrl+."));
        pipeline.Items.Add(MenuItem("Reset Outputs", ResetOutputsClicked));
        var help = new MenuBarItem { Title = "Help", VerticalAlignment = VerticalAlignment.Center };
        help.Items.Add(MenuItem("Online Documentation", OpenDocumentationClicked));
        help.Items.Add(new MenuFlyoutSeparator());
        help.Items.Add(MenuItem("About Pinna2HRTF", ShowAboutClicked));
        bar.Items.Add(project);
        bar.Items.Add(pipeline);
        bar.Items.Add(help);
        return bar;
    }

    MenuFlyoutItem MenuItem(string text, RoutedEventHandler handler, string? shortcut = null)
    {
        var item = new MenuFlyoutItem { Text = text, KeyboardAcceleratorTextOverride = shortcut ?? "" };
        item.Click += handler;
        return item;
    }

    Border BuildProjectsPane()
    {
        projectsPaneBorder = new Border { Background = surfaceBrush, BorderBrush = borderBrush, BorderThickness = new Thickness(0, 0, 1, 0) };
        var pane = projectsPaneBorder;
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        projectsHeaderText = new TextBlock { Text = "Projects", FontSize = 20, Margin = new Thickness(12, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = primaryTextBrush };
        // Actions belong to the body, outside the native expander's toggle.
        // A separate toolbar also fits at the sidebar's minimum width.
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(10, 8, 10, 8) };
        buttons.Children.Add(ProjectButton("\uE710", "New project", CreateProjectClicked));
        buttons.Children.Add(ProjectButton("\uE896", "Import project", ImportProjectClicked));
        buttons.Children.Add(ProjectButton("\uE8C8", "Duplicate selected project", DuplicateProjectClicked));
        buttons.Children.Add(ProjectButton("\uE74D", "Delete selected project", RemoveProjectClicked));
        grid.Children.Add(buttons);
        projectList.SelectionChanged += ProjectSelectionChanged;
        projectList.Background = new SolidColorBrush(Colors.Transparent);
        projectList.BorderThickness = new Thickness(0);
        projectList.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        projectList.VerticalContentAlignment = VerticalAlignment.Stretch;
        projectList.Margin = new Thickness(10, 0, 10, 10);
        Grid.SetRow(projectList, 1);
        grid.Children.Add(projectList);
        projectsBody = grid;
        projectsExpander = new Expander
        {
            Header = projectsHeaderText, Content = grid, IsExpanded = !projectsCollapsed,
            ExpandDirection = ExpandDirection.Down, MinWidth = 0, Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch
        };
        // Keep WinUI's animated chevron and keyboard/accessibility behavior.
        // Remove only the space reserved around it, so an empty header measures
        // to the native 32-pixel toggle plus its border when collapsed.
        projectsExpander.Resources["ExpanderChevronMargin"] = new Thickness(0);
        projectsExpander.RegisterPropertyChangedCallback(Expander.IsExpandedProperty, (_, _) =>
            SetProjectsCollapsed(!projectsExpander.IsExpanded, true));
        AutomationProperties.SetName(projectsExpander, "Projects");
        pane.Child = projectsExpander;
        return pane;
    }

    Button ProjectButton(string glyph, string tip, RoutedEventHandler handler)
    {
        var fontIcon = new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = glyph, FontSize = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var button = new Button { Content = fontIcon, Width = 32, Height = 32, Padding = new Thickness(0) };
        ToolTipService.SetToolTip(button, tip);
        AutomationProperties.SetName(button, tip);
        button.Click += handler;
        return button;
    }

    Grid BuildCenterPane()
    {
        // Keep the vertical breathing room while bringing the viewer closer to
        // both sidebars. The 12-pixel splitter columns still provide the drag
        // target between panes.
        var grid = new Grid { Margin = new Thickness(6, 14, 6, 14) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        logSplitterRow = new RowDefinition { Height = new GridLength(12) };
        grid.RowDefinitions.Add(logSplitterRow);
        centerLogRow = new RowDefinition { Height = new GridLength(Math.Clamp(liveLogExpandedHeight, 100, 600)) };
        grid.RowDefinitions.Add(centerLogRow);
        previewPanelBorder = new Border { CornerRadius = new CornerRadius(8), BorderBrush = borderBrush, BorderThickness = new Thickness(1), Background = surfaceBrush };
        var preview = previewPanelBorder;
        var previewGrid = new Grid();
        previewGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(57) });
        previewGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(12, 7, 12, 7) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titlePanel = new StackPanel();
        titlePanel.Children.Add(new TextBlock { Text = "Preview", FontSize = 18, FontWeight = FontWeights.SemiBold });
        selectedArtifactText = new TextBlock { Text = "Select a file to preview", FontSize = 12, Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)), TextTrimming = TextTrimming.CharacterEllipsis };
        titlePanel.Children.Add(selectedArtifactText);
        header.Children.Add(titlePanel);
        var pickerPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        placeLeftButton = new Button { Content = "Place Left Mic", MinWidth = 108, MinHeight = 30 };
        placeRightButton = new Button { Content = "Place Right Mic", MinWidth = 112, MinHeight = 30 };
        placeLeftButton.Click += (_, _) => BeginPlacement("left");
        placeRightButton.Click += (_, _) => BeginPlacement("right");
        pickerPanel.Children.Add(placeLeftButton);
        pickerPanel.Children.Add(placeRightButton);
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
            // Let Helix handle camera manipulation. The previous implementation
            // disabled rotation/pan and tried to mutate the camera from routed
            // pointer events, which competed with Helix and left zoom as the only
            // reliable gesture.
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
        // Helix consumes camera gestures, so observe these events with
        // handledEventsToo for placement-click detection and camera persistence.
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
            Padding = new Thickness(10, 6, 10, 6),
            CornerRadius = new CornerRadius(5),
            Background = viewerHintBackgroundBrush,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
            Child = new TextBlock
            {
                Text = "Drag to rotate  |  Mouse wheel to zoom",
                FontSize = 12,
                Foreground = viewerHintTextBrush,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        viewerGrid.Children.Add(viewerInteractionHint);
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
        // Viewport3DX does not guarantee useful lighting when no scene lights are
        // supplied by the host. Keep the setup neutral and diffuse so mesh shape
        // remains readable in both light and dark themes.
        var ambient = new AmbientLight3D { Color = Colors.White };
        var key = new DirectionalLight3D { Color = Colors.White, Direction = new System.Numerics.Vector3(-0.45f, -0.65f, -0.6f) };
        var fill = new DirectionalLight3D { Color = ColorHelper.FromArgb(210, 220, 235, 255), Direction = new System.Numerics.Vector3(0.7f, 0.25f, -0.35f) };
        var rim = new DirectionalLight3D { Color = ColorHelper.FromArgb(170, 255, 235, 210), Direction = new System.Numerics.Vector3(0.15f, 0.55f, 0.8f) };
        sceneLights.AddRange([ambient, key, fill, rim]);
        foreach (var light in sceneLights)
            meshViewport.Items.Add(light);
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
        logPanelBorder = new Border { Margin = new Thickness(0), Background = surfaceBrush, BorderBrush = borderBrush, BorderThickness = new Thickness(1) };
        var panel = logPanelBorder;
        var header = new Grid { Margin = new Thickness(10, 0, 6, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock { Text = "Live Log", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(title, 0);
        header.Children.Add(title);
        var clear = new Button { Content = "Clear", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(10, 2, 10, 2) };
        clear.Click += ClearLogClicked;
        Grid.SetColumn(clear, 1);
        header.Children.Add(clear);
        logText = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), FontSize = 12, BorderThickness = new Thickness(0), Margin = new Thickness(10) };
        ScrollViewer.SetVerticalScrollBarVisibility(logText, ScrollBarVisibility.Auto);
        logExpander = new Expander
        {
            Header = header,
            Content = logText,
            ExpandDirection = ExpandDirection.Up,
            IsExpanded = !logCollapsed,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Padding = new Thickness(0),
            Margin = new Thickness(0)
        };
        logExpander.RegisterPropertyChangedCallback(Expander.IsExpandedProperty, (_, _) =>
            SetLogCollapsed(!logExpander.IsExpanded, true));
        ToolTipService.SetToolTip(logExpander, "Expand or collapse Live Log");
        AutomationProperties.SetName(logExpander, "Live Log");
        panel.Child = logExpander;
        return panel;
    }

    void SetLogCollapsed(bool collapsed, bool persist)
    {
        logCollapsed = collapsed;
        if (centerLogRow != null)
            centerLogRow.Height = collapsed ? GridLength.Auto : new GridLength(Math.Clamp(liveLogExpandedHeight, 100, 600));
        if (logSplitterRow != null) logSplitterRow.Height = new GridLength(collapsed ? 0 : 12);
        if (logSplitter != null) logSplitter.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (logExpander != null)
        {
            if (logExpander.IsExpanded == collapsed) logExpander.IsExpanded = !collapsed;
            logExpander.VerticalAlignment = collapsed ? VerticalAlignment.Top : VerticalAlignment.Stretch;
            ToolTipService.SetToolTip(logExpander, collapsed ? "Expand Live Log" : "Collapse Live Log");
        }
        if (persist) SaveUiState();
    }

    Border BuildSettingsPane()
    {
        settingsPaneBorder = new Border { Background = secondarySurfaceBrush, BorderBrush = borderBrush, BorderThickness = new Thickness(1, 0, 0, 0) };
        var pane = settingsPaneBorder;
        var outer = new Grid();
        outer.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        outer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var settings = new StackPanel { Margin = new Thickness(12, 10, 12, 10), HorizontalAlignment = HorizontalAlignment.Stretch };
        settings.Children.Add(new TextBlock { Text = "Project", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        AddSetting(settings, "Project name", "project.name", projectNameBox);
        AddPathSetting(settings, "Left ear (optional)", "project.left_ear", leftEarBox, BrowseLeftEarClicked);
        AddPathSetting(settings, "Right ear (optional)", "project.right_ear", rightEarBox, BrowseRightEarClicked);
        AddPathSetting(settings, "Save location", "project.save_location", saveLocationBox, BrowseSaveLocationClicked);
        settings.Children.Add(new TextBlock { Text = "Choose at least one ear mesh.", Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)), Margin = new Thickness(0, 3, 0, 4) });
        AddSetting(settings, "Use BezierPPM", "project.use_bezierppm", usePredictionsBox, "Use BezierPPM");
        AddExpander(settings, "Mesh2PPM", [AddSettingPanel("Model", "inference.model", modelPicker)]);
        AddExpander(settings, "Mesh2HRTF", [PathSettingPanel("Evaluation grid", "mesh2hrtf.evaluation_grid", evaluationGridBox, BrowseEvaluationGridClicked), AddSettingPanel("Use custom head radius", "mesh2hrtf.use_head_radius", useHeadRadiusBox, "Use custom head radius"), AddSettingPanel("Head radius", "mesh2hrtf.head_radius", headRadiusBox), AddSettingPanel("Min frequency", "mesh2hrtf.min_frequency", minFrequencyBox), AddSettingPanel("Max frequency", "mesh2hrtf.max_frequency", maxFrequencyBox), AddSettingPanel("Frequency steps (minimum 2)", "mesh2hrtf.frequency_steps", frequencyStepsBox), AddSettingPanel("Microphone faces", "mesh2hrtf.microphone_faces", microphoneFacesBox)]);
        AddExpander(settings, "Mesh Grading", [AddSettingPanel("Min edge length", "mesh_grading.min_edge_length", meshMinEdgeBox), AddSettingPanel("Max edge length", "mesh_grading.max_edge_length", meshMaxEdgeBox), AddSettingPanel("Max error", "mesh_grading.max_error", meshMaxErrorBox), AddSettingPanel("Gamma", "mesh_grading.gamma", meshGammaBox), AddSettingPanel("Gamma opposite", "mesh_grading.gamma_opposite", meshGammaOppositeBox)]);
        AddExpander(settings, "NumCalc", [AddSettingPanel("Parallel instances", "numcalc.parallel_instances", maxInstancesBox), AddSettingPanel("CPU limit (%)", "numcalc.cpu_limit", maxCpuLoadBox), AddSettingPanel("Adaptive FMM expansion length", "numcalc.adaptive_fmm", adaptiveFmmLengthBox, "Adaptive FMM expansion length")]);
        AddExpander(settings, "Postprocessing", [AddSettingPanel("Normalize HRTFs", "postprocessing.normalize", normalizeHrtfsBox, "Normalize HRTFs"), AddSettingPanel("Level offset (dB)", "postprocessing.level_offset", levelOffsetBox)]);
        scroll.Content = settings;
        outer.Children.Add(scroll);
        var stages = BuildStagesPane();
        Grid.SetRow(stages, 1);
        outer.Children.Add(stages);
        pane.Child = outer;
        RegisterSettingControls();
        return pane;
    }

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
            textBox.TextChanged += ProjectEdited;
        if (control is CheckBox box)
        {
            if (ReferenceEquals(box, usePredictionsBox))
            {
                box.Checked += BezierPPMSettingChanged;
                box.Unchecked += BezierPPMSettingChanged;
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
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labelPanel = new StackPanel { Orientation = Orientation.Horizontal };
        labelPanel.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        var info = InfoButton(id);
        labelPanel.Children.Add(info);
        row.Children.Add(labelPanel);
        var browse = new Button { Content = "Browse", HorizontalAlignment = HorizontalAlignment.Right, MinHeight = 28, Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(6, 0, 0, 0) };
        browse.Click += handler;
        Grid.SetColumn(browse, 1);
        row.Children.Add(browse);
        Grid.SetRow(box, 1);
        Grid.SetColumnSpan(box, 2);
        box.HorizontalAlignment = HorizontalAlignment.Stretch;
        box.MinHeight = 28;
        row.Children.Add(box);
        box.Tag = id;
        settingControls[id] = box;
        box.TextChanged += ProjectEdited;
        return row;
    }

    Button InfoButton(string id)
    {
        // Match the macOS info.circle affordance while keeping the existing
        // flyout content and publication links used by the Windows app.
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
            Tag = id, Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0), Foreground = mutedTextBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        ToolTipService.SetToolTip(info, "Show information");
        AutomationProperties.SetName(info, "Show information");
        info.Click += SettingInfoClicked;
        return info;
    }

    void AddExpander(StackPanel parent, string title, IEnumerable<Grid> children)
    {
        var panel = new StackPanel { Spacing = 3 };
        foreach (var child in children)
            panel.Children.Add(child);
        panel.HorizontalAlignment = HorizontalAlignment.Stretch;
        var expander = new Expander { Header = title, Content = panel, IsExpanded = false, Margin = new Thickness(0, 5, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        settingSections.Add(expander);
        parent.Children.Add(expander);
    }

    Border BuildStagesPane()
    {
        var border = new Border { BorderBrush = borderBrush, BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(14, 8, 14, 12) };
        var stack = new StackPanel();
        var stages = Stage.GetValues();
        for (var i = 0; i < stages.Length; i++)
        {
            var row = new Grid { Margin = new Thickness(0, 1, 0, 1), HorizontalAlignment = HorizontalAlignment.Stretch };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = stages[i].Title, VerticalAlignment = VerticalAlignment.Center });
            Grid.SetColumn(stageStatus[i], 1);
            stageStatus[i].Margin = new Thickness(8, 0, 10, 0);
            stageStatus[i].FontSize = 11;
            stageStatus[i].VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(stageStatus[i]);
            var button = new Button { Content = "Run", Width = 62, Padding = new Thickness(8, 3, 8, 3), Tag = stages[i] };
            button.Click += StageButtonClicked;
            stageButtons.Add(button);
            Grid.SetColumn(button, 2);
            row.Children.Add(button);
            stack.Children.Add(row);
        }
        runAllButton = new Button { Content = "Run All", Height = 34, Margin = new Thickness(0, 8, 0, 0), Background = new SolidColorBrush(ColorHelper.FromArgb(255, 111, 159, 156)), Foreground = new SolidColorBrush(Colors.White), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center };
        runAllButton.Click += RunAllClicked;
        stack.Children.Add(runAllButton);
        pipelineHintText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 11, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
        stack.Children.Add(pipelineHintText);
        var statusRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        numCalcStatusText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 11, Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)) };
        statusRow.Children.Add(numCalcStatusText);
        var reset = new Button { Content = "Reset Outputs", Padding = new Thickness(10, 3, 10, 3), FontSize = 11 };
        reset.Click += ResetOutputsClicked;
        Grid.SetColumn(reset, 1);
        statusRow.Children.Add(reset);
        stack.Children.Add(statusRow);
        border.Child = stack;
        return border;
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
        if (projectList.SelectedIndex >= 0 && projectList.SelectedIndex < projects.Count && !ReferenceEquals(selectedProject, projects[projectList.SelectedIndex]))
        {
            selectedProject = projects[projectList.SelectedIndex];
            LoadSelectedProject();
            RefreshArtifacts();
        }
    }

    void LoadSelectedProject()
    {
        if (placementSide != null) EndPlacement();
        loading = true;
        var project = selectedProject;
        projectNameBox.Text = project?.Name ?? "";
        leftEarBox.Text = project?.LeftEar ?? "";
        rightEarBox.Text = project?.RightEar ?? "";
        saveLocationBox.Text = project?.SaveLocation ?? "";
        usePredictionsBox.IsChecked = project?.Settings.Inference.UsePredictionsForPreprocessing ?? true;
        evaluationGridBox.Text = project?.Settings.Preprocessing.EvaluationGrid ?? "";
        useHeadRadiusBox.IsChecked = project?.Settings.Preprocessing.UseCustomHeadRadius == true;
        headRadiusBox.Text = project?.Settings.Preprocessing.HeadRadius ?? "";
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
        levelOffsetBox.Text = project?.Settings.Postprocessing?.LevelOffsetDB ?? "-30";
        SelectModel(project);
        LoadSelectedProjectLog();
        loading = false;
    }

    void ProjectEdited(object sender, RoutedEventArgs e)
    {
        if (loading || selectedProject == null)
            return;
        var project = selectedProject;
        project.Name = projectNameBox.Text.Trim();
        project.LeftEar = leftEarBox.Text.Trim();
        project.RightEar = rightEarBox.Text.Trim();
        project.SaveLocation = saveLocationBox.Text.Trim();
        project.Settings.Inference.UsePredictionsForPreprocessing = usePredictionsBox.IsChecked == true;
        if (placementSide != null && !PlacementIsCurrent()) EndPlacement();
        project.Settings.Preprocessing.EvaluationGrid = evaluationGridBox.Text.Trim();
        project.Settings.Preprocessing.UseCustomHeadRadius = useHeadRadiusBox.IsChecked == true;
        project.Settings.Preprocessing.HeadRadius = headRadiusBox.Text.Trim();
        project.Settings.Preprocessing.MinFrequency = minFrequencyBox.Text.Trim();
        project.Settings.Preprocessing.MaxFrequency = maxFrequencyBox.Text.Trim();
        project.Settings.Preprocessing.FrequencyStepCount = Math.Max(int.TryParse(frequencyStepsBox.Text, out var steps) ? steps : 129, 2).ToString(CultureInfo.InvariantCulture);
        project.Settings.Preprocessing.SourceAssignmentFaceCount = microphoneFacesBox.Text.Trim();
        project.Settings.Preprocessing.MeshMinEdgeLength = meshMinEdgeBox.Text.Trim();
        project.Settings.Preprocessing.MeshMaxEdgeLength = meshMaxEdgeBox.Text.Trim();
        project.Settings.Preprocessing.MeshMaxError = meshMaxErrorBox.Text.Trim();
        project.Settings.Preprocessing.MeshGamma = meshGammaBox.Text.Trim();
        project.Settings.Preprocessing.MeshGammaOpposite = meshGammaOppositeBox.Text.Trim();
        project.Settings.NumCalc.MaxInstances = maxInstancesBox.Text.Trim();
        project.Settings.NumCalc.MaxCpuLoad = maxCpuLoadBox.Text.Trim();
        project.Settings.NumCalc.AdaptiveFmmLength = adaptiveFmmLengthBox.IsChecked == true;
        project.Settings.Postprocessing ??= new PostprocessingSettings();
        project.Settings.Postprocessing.Normalize = normalizeHrtfsBox.IsChecked == true;
        project.Settings.Postprocessing.LevelOffsetDB = levelOffsetBox.Text.Trim();
        InvalidateManualPositions(project);
        Persist();
        RefreshProjectList();
        RefreshPipelineStatus();
    }

    async void BezierPPMSettingChanged(object sender, RoutedEventArgs e)
    {
        if (loading || selectedProject == null)
            return;
        var project = selectedProject;
        var desired = usePredictionsBox.IsChecked == true;
        var current = project.Settings.Inference.UsePredictionsForPreprocessing;
        if (desired == current)
            return;
        if (runningProcesses.ContainsKey(project.Id))
        {
            loading = true;
            usePredictionsBox.IsChecked = current;
            loading = false;
            return;
        }
        if (!HasGeneratedPipelineOutputs(project))
        {
            ProjectEdited(sender, e);
            return;
        }
        loading = true;
        usePredictionsBox.IsChecked = current;
        loading = false;
        var dialog = new ContentDialog { Title = "Reset pipeline outputs?", Content = "Changing Use BezierPPM changes the mesh used for preprocessing and resets the completed pipeline outputs. Your input meshes and project settings will be kept.", PrimaryButtonText = "OK", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = Root.XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            return;
        ResetSelectedProjectOutputs();
        loading = true;
        usePredictionsBox.IsChecked = desired;
        loading = false;
        ProjectEdited(sender, e);
    }

    void RefreshProjectList()
    {
        var index = selectedProject == null ? -1 : projects.IndexOf(selectedProject);
        var matching = projectList.Items.Count == projects.Count && projects.Select((project, i) => projectList.Items[i] is Grid row && ReferenceEquals(row.Tag, project)).All(x => x);
        if (!matching)
        {
            projectRows.Clear();
            projectList.Items.Clear();
            foreach (var project in projects)
            {
                var ui = new ProjectRowUi(project);
                projectRows[project.Id] = ui;
                projectList.Items.Add(ui.Root);
            }
        }
        foreach (var project in projects)
        {
            project.IsRunning = runningProcesses.ContainsKey(project.Id);
            project.StatusText = NextStageSummary(project);
            if (projectRows.TryGetValue(project.Id, out var ui))
            {
                ui.Name.Text = project.Name;
                ui.Status.Text = project.StatusText;
                ui.Name.Foreground = primaryTextBrush;
                ui.Status.Foreground = mutedTextBrush;
                ui.Spinner.IsActive = project.IsRunning;
                ui.Spinner.Visibility = project.IsRunning ? Visibility.Visible : Visibility.Collapsed;
            }
        }
        if (index >= 0 && index < projectList.Items.Count && projectList.SelectedIndex != index)
            projectList.SelectedIndex = index;
    }

    void LoadSelectedProjectLog()
    {
        logText.Text = selectedProject != null && projectLogs.TryGetValue(selectedProject.Id, out var value) ? value : "";
        RestoreLogScroll(0, true);
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
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        selectedProject.Settings.Inference.ModelConfig = Path.Combine(resources, name + ".yaml");
        selectedProject.Settings.Inference.ModelCheckpoint = Path.Combine(resources, name + ".pth");
        Persist();
        RefreshPipelineStatus();
    }

    void CreateProjectClicked(object sender, RoutedEventArgs e) => CreateProject();
    void ImportProjectClicked(object sender, RoutedEventArgs e) => _ = ImportProjectAsync();
    void DuplicateProjectClicked(object sender, RoutedEventArgs e) => DuplicateProject();
    void RemoveProjectClicked(object sender, RoutedEventArgs e) => RemoveProject();
    void StageButtonClicked(object sender, RoutedEventArgs e) { if (sender is Button button && button.Tag is Stage stage) RunOrStop(stage); }

    async Task ImportProjectAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder != null)
            ImportProject(folder.Path);
    }

    void ImportProject(string folder)
    {
        var project = NewProject(projects.Count + 1);
        project.Name = Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        project.SaveLocation = folder;
        project.LeftEar = ImportedMesh(folder, "Left");
        project.RightEar = ImportedMesh(folder, "Right");
        project.Settings.Inference.UsePredictionsForPreprocessing = false;
        TryReadProjectSettings(project);
        InvalidateManualPositions(project);
        projects.Add(project);
        failedStages[project.Id] = [];
        selectedProject = project;
        Persist();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
        AppendLog("Imported project.", project.Id);
    }

    void TryReadProjectSettings(ProjectRecord project)
    {
        var path = Path.Combine(project.SaveLocation, "Project Settings.yaml");
        if (!File.Exists(path))
            return;
        var text = File.ReadAllText(path);
        project.Settings.Inference.UsePredictionsForPreprocessing = !text.Contains("use_predictions_for_preprocessing: false", StringComparison.OrdinalIgnoreCase);
        foreach (var (key, setter) in new (string, Action<string>)[] { ("min_frequency", v => project.Settings.Preprocessing.MinFrequency = v), ("max_frequency", v => project.Settings.Preprocessing.MaxFrequency = v), ("frequency_step_count", v => project.Settings.Preprocessing.FrequencyStepCount = Math.Max(int.TryParse(v, out var n) ? n : 129, 2).ToString(CultureInfo.InvariantCulture)), ("mesh_min_edge_length", v => project.Settings.Preprocessing.MeshMinEdgeLength = v), ("mesh_max_edge_length", v => project.Settings.Preprocessing.MeshMaxEdgeLength = v), ("mesh_max_error", v => project.Settings.Preprocessing.MeshMaxError = v), ("mesh_gamma", v => project.Settings.Preprocessing.MeshGamma = v), ("mesh_gamma_opposite", v => project.Settings.Preprocessing.MeshGammaOpposite = v) })
        {
            var line = text.Split('\n').FirstOrDefault(x => x.TrimStart().StartsWith(key + ":", StringComparison.OrdinalIgnoreCase));
            if (line != null)
                setter(line[(line.IndexOf(':') + 1)..].Trim().Trim('\''));
        }
        project.Settings.Preprocessing.SourcePositionInputLeft = ReadManualPosition(project, text, "source_position_input_left");
        project.Settings.Preprocessing.SourcePositionInputRight = ReadManualPosition(project, text, "source_position_input_right");
    }

    ManualMicrophonePosition? ReadManualPosition(ProjectRecord project, string text, string key)
    {
        var line = text.Split('\n').FirstOrDefault(x => x.TrimStart().StartsWith(key + ":", StringComparison.OrdinalIgnoreCase));
        if (line == null) return null;
        var start = line.IndexOf('[');
        if (start < 0) return null;
        var values = line[(start + 1)..].Trim().TrimEnd(']').Split(',').Select(x => double.TryParse(x.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : double.NaN).ToArray();
        if (values.Length != 3 || values.Any(double.IsNaN)) return null;
        var side = key.EndsWith("left", StringComparison.OrdinalIgnoreCase) ? "left" : "right";
        var mesh = PreprocessingMesh(project, side);
        return mesh == null ? null : new ManualMicrophonePosition { X = values[0], Y = values[1], Z = values[2], MeshPath = mesh, MeshIdentity = MeshIdentity(mesh) };
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

    void DuplicateProject()
    {
        if (selectedProject == null)
            return;
        var duplicate = Clone(selectedProject);
        duplicate.Id = Guid.NewGuid();
        duplicate.Name = selectedProject.Name + " Copy";
        if (!string.IsNullOrWhiteSpace(selectedProject.SaveLocation))
        {
            var original = new DirectoryInfo(selectedProject.SaveLocation);
            var parent = original.Parent?.FullName ?? selectedProject.SaveLocation;
            var location = Path.Combine(parent, original.Name + " Copy");
            var number = 2;
            while (Directory.Exists(location))
                location = Path.Combine(parent, original.Name + " Copy " + number++);
            duplicate.SaveLocation = location;
            if (original.Exists)
            {
                try
                {
                    CopyDirectory(original.FullName, location);
                    var originalPath = Path.GetFullPath(original.FullName).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    var duplicatePath = Path.GetFullPath(location).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    string Relocate(string path)
                    {
                        if (string.IsNullOrWhiteSpace(path)) return path;
                        var normalized = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                        return normalized.Equals(originalPath, StringComparison.OrdinalIgnoreCase) || normalized.StartsWith(originalPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ? duplicatePath + normalized[originalPath.Length..] : path;
                    }
                    duplicate.LeftEar = Relocate(duplicate.LeftEar);
                    duplicate.RightEar = Relocate(duplicate.RightEar);
                    var settingsPath = Path.Combine(location, "Project Settings.yaml");
                    if (File.Exists(settingsPath))
                        File.WriteAllText(settingsPath, File.ReadAllText(settingsPath).Replace(originalPath, duplicatePath, StringComparison.OrdinalIgnoreCase));
                }
                catch (Exception error)
                {
                    AppendLog("Could not duplicate project folder: " + error.Message, selectedProject.Id);
                    return;
                }
            }
        }
        duplicate.Settings.Preprocessing.SourcePositionInputLeft = null;
        duplicate.Settings.Preprocessing.SourcePositionInputRight = null;
        InvalidateManualPositions(duplicate);
        projects.Add(duplicate);
        failedStages[duplicate.Id] = [];
        selectedProject = duplicate;
        Persist();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
    }

    void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        foreach (var directory in Directory.EnumerateDirectories(source))
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }

    ProjectRecord NewProject(int index)
    {
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        return new ProjectRecord { Name = "Project " + index, Settings = new ProjectSettings { Inference = new InferenceSettings { ModelConfig = Path.Combine(resources, "Local 3 Views.yaml"), ModelCheckpoint = Path.Combine(resources, "Local 3 Views.pth") } } };
    }

    void RemoveProject()
    {
        if (selectedProject == null)
            return;
        StopProject(selectedProject);
        projectLogs.Remove(selectedProject.Id);
        projects.Remove(selectedProject);
        selectedProject = projects.FirstOrDefault();
        if (selectedProject == null)
            CreateProject();
        else
        {
            Persist();
            RefreshProjectList();
            LoadSelectedProject();
            RefreshArtifacts();
        }
    }

    async void BrowseLeftEarClicked(object sender, RoutedEventArgs e) { var path = await PickFileAsync(leftEarBox.Text); if (path != null) leftEarBox.Text = path; }
    async void BrowseRightEarClicked(object sender, RoutedEventArgs e) { var path = await PickFileAsync(rightEarBox.Text); if (path != null) rightEarBox.Text = path; }
    async void BrowseSaveLocationClicked(object sender, RoutedEventArgs e) { var path = await PickFolderAsync(saveLocationBox.Text); if (path != null) saveLocationBox.Text = path; }
    async void BrowseEvaluationGridClicked(object sender, RoutedEventArgs e) { var path = await PickFolderAsync(evaluationGridBox.Text); if (path != null) evaluationGridBox.Text = path; }

    static string? ExistingPickerFolder(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var full = Path.GetFullPath(path.Trim());
            if (Directory.Exists(full)) return full;
            var parent = Path.GetDirectoryName(full);
            return !string.IsNullOrWhiteSpace(parent) && Directory.Exists(parent) ? parent : null;
        }
        catch { return null; }
    }

    static void ConfigurePickerStart(object picker, string? currentPath)
    {
        // WinUI pickers expose only a coarse SuggestedStartLocation. A stable
        // SettingsIdentifier lets Windows remember the last folder separately for
        // each existing path, while still falling back to the normal picker.
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

    async Task<string?> PickFileAsync(string? currentPath = null)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        ConfigurePickerStart(picker, currentPath);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    async Task<string?> PickFolderAsync(string? currentPath = null)
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        ConfigurePickerStart(picker, currentPath);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    void RefreshArtifacts()
    {
        // A background stage finishing must not replace an active placement mesh.
        if (placementSide != null) return;
        if (selectedProject == null)
        {
            artifacts.Clear();
            ResetViewer();
            return;
        }
        var selectedPath = viewerStates.TryGetValue(selectedProject.Id, out var state) ? state.SelectedArtifactPath : null;
        refreshingArtifacts = true;
        artifacts.Clear();
        foreach (var artifact in ArtifactsFor(selectedProject).Where(x => x.Exists))
            artifacts.Add(artifact);
        artifactPicker.SelectedItem = artifacts.FirstOrDefault(x => x.Path == selectedPath) ?? artifacts.FirstOrDefault();
        refreshingArtifacts = false;
        if (artifactPicker.SelectedItem is Artifact selected)
            OpenArtifact(selected);
        else
            ResetViewer();
        RefreshProjectList();
    }

    List<Artifact> ArtifactsFor(ProjectRecord project)
    {
        var list = new List<Artifact>();
        var hrtf = Path.Combine(project.SaveLocation, "HRTF");
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
        return list;
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
            _ = OpenMeshAsync(artifact);
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
            meshVisual = new MeshGeometryModel3D { Geometry = currentMesh.Geometry, Material = new PhongMaterial { AmbientColor = new Color4(0.18f, 0.22f, 0.22f, 1), DiffuseColor = new Color4(0.48f, 0.68f, 0.66f, 1), EmissiveColor = new Color4(0.035f, 0.045f, 0.045f, 1), SpecularColor = new Color4(0.12f, 0.14f, 0.14f, 1), SpecularShininess = 12 }, CullMode = SharpDX.Direct3D11.CullMode.None };
            meshVisual.RenderWireframe = string.Equals(Path.GetExtension(artifact.Path), ".ply", StringComparison.OrdinalIgnoreCase);
            meshVisual.WireframeColor = ColorHelper.FromArgb(65, 31, 56, 56);
            meshViewport.Items.Add(meshVisual);
            meshVisuals.Add(meshVisual);
            AddMicrophoneMarker(artifact.Path);
            ResetMeshCamera();
            meshViewport.Camera?.ZoomExtents(meshViewport, 80);
            viewerPlaceholder.Visibility = Visibility.Collapsed;
            viewerInteractionHint.Visibility = Visibility.Visible;
            meshViewport.Visibility = Visibility.Visible;
            UpdatePlacementButtons();
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            currentMesh = null;
            viewerInteractionHint.Visibility = Visibility.Collapsed;
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
        meshPointerMode = properties.IsLeftButtonPressed ? MeshPointerMode.Rotate : properties.IsMiddleButtonPressed ? MeshPointerMode.Pan : MeshPointerMode.None;
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
        var wasClick = !pointerMoved;
        ResetMeshPointerState();
        SaveMeshCamera();
        if (PlacementIsCurrent() && !calculatingAutomaticPosition && mode == MeshPointerMode.Rotate && wasClick && currentMesh != null && meshVisual != null)
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
    }

    void MeshViewportPointerCanceled(object sender, PointerRoutedEventArgs e) => ResetMeshPointerState();

    void MeshViewportPointerCaptureLost(object sender, PointerRoutedEventArgs e) => ResetMeshPointerState();

    void MeshViewportPointerWheelChanged(object sender, PointerRoutedEventArgs e) => SaveMeshCamera();

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

    void UpdatePlacementButtons()
    {
        foreach (var (side, button) in new[] { ("left", placeLeftButton), ("right", placeRightButton) })
        {
            var available = selectedProject != null && PreprocessingMesh(selectedProject, side) != null;
            button.IsEnabled = placementSide == null && available && !runningProcesses.ContainsKey(selectedProject!.Id);
            ToolTipService.SetToolTip(button, available ? $"Place the {side} microphone on the mesh used for preprocessing." :
                selectedProject != null && InferenceIsAutomatic(selectedProject) ? $"Run Mesh2PPM Inference to create the predicted {side} ear first." : $"Select an input {side} ear first.");
        }
    }

    bool PlacementIsCurrent() => selectedProject != null && placementProjectId == selectedProject.Id &&
        placementSide != null && SamePath(placementMeshPath, currentMesh?.Path) &&
        SamePath(placementMeshPath, PreprocessingMesh(selectedProject, placementSide)) &&
        placementMeshIdentity == MeshIdentity(placementMeshPath!);

    async void BeginPlacement(string side) => await BeginPlacementAsync(side);

    async Task BeginPlacementAsync(string side)
    {
        var project = selectedProject;
        if (project == null || placementSide != null || runningProcesses.ContainsKey(project.Id)) return;
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

    async void AutomaticPositionClicked(object sender, RoutedEventArgs e) => await UseAutomaticPositionAsync();

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
        var info = new ProcessStartInfo(executable, $"-m HRTFCalculation.Preprocessing.src.ear_canal_closer --ear_path {QuoteArgument(mesh)} --landmark_path {QuoteArgument(landmark)} --side {side} --estimate-only") { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        ApplyProcessEnvironment(info);
        Directory.CreateDirectory(Path.GetDirectoryName(landmark)!);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Could not start the bundled Python environment.");
        using var registration = cancellation.Register(() => TryTerminate(process));
        try
        {
            // Drain both pipes together: filling stderr must not block stdout or Done.
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellation);
            var errorTask = process.StandardError.ReadToEndAsync(cancellation);
            await Task.WhenAll(outputTask, errorTask, process.WaitForExitAsync(cancellation));
            var output = await outputTask;
            var error = await errorTask;
            if (process.ExitCode != 0)
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? $"Estimator exited with status {process.ExitCode}. {output.Trim()}" : error.Trim());
            using var document = JsonDocument.Parse(File.Exists(landmark) ? File.ReadAllText(landmark) : output);
            var values = document.RootElement.GetProperty("position").EnumerateArray().Select(x => (float)x.GetDouble()).ToArray();
            if (values.Length != 3 || values.Any(x => !float.IsFinite(x))) throw new InvalidDataException("The estimator returned an invalid position.");
            return new System.Numerics.Vector3(values[0], values[1], values[2]);
        }
        finally
        {
            if (!process.HasExited) { TryTerminate(process); await process.WaitForExitAsync(); }
            if (File.Exists(landmark)) File.Delete(landmark);
        }
    }

    void DonePositionClicked(object sender, RoutedEventArgs e)
    {
        if (!PlacementIsCurrent() || calculatingAutomaticPosition || pendingMicrophonePosition == null ||
            !PositionMatchesMesh(pendingMicrophonePosition, placementMeshPath))
            return;
        if (placementSide == "left") selectedProject!.Settings.Preprocessing.SourcePositionInputLeft = pendingMicrophonePosition; else selectedProject!.Settings.Preprocessing.SourcePositionInputRight = pendingMicrophonePosition;
        Persist();
        AppendLog($"Saved {placementSide} microphone position.", selectedProject.Id);
        EndPlacement();
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
        var position = new System.Numerics.Vector3(currentMesh!.Center.X + (float)(horizontal * Math.Sin(yaw)), currentMesh.Center.Y - (float)(horizontal * Math.Cos(yaw)), currentMesh.Center.Z + (float)(state.Distance * Math.Sin(pitch)));
        camera.Position = position;
        camera.LookDirection = currentMesh.Center - position;
        camera.UpDirection = new System.Numerics.Vector3(0, 0, 1);
        meshViewport.Camera = camera;
    }

    void SaveMeshCamera()
    {
        if (selectedProject == null || selectedArtifactPath == null || currentMesh == null || meshViewport.Camera is not PerspectiveCamera camera)
            return;
        var direction = camera.Position - currentMesh.Center;
        if (!viewerStates.TryGetValue(selectedProject.Id, out var state)) viewerStates[selectedProject.Id] = state = new ProjectViewerState();
        state.CameraByArtifact[selectedArtifactPath] = new MeshCameraState { Distance = direction.Length(), Pitch = Math.Asin(direction.Z / Math.Max(direction.Length(), 1e-6f)) * 180 / Math.PI, Yaw = Math.Atan2(direction.X, -direction.Y) * 180 / Math.PI };
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
    void RunOrStop(Stage stage) { if (selectedProject != null && runningStages.TryGetValue(selectedProject.Id, out var active) && active == stage) StopProject(selectedProject); else RunStage(stage); }

    void RunNextClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null) return;
        var next = AutomaticStages(selectedProject).FirstOrDefault(x => !StageIsComplete(x, selectedProject));
        if (next != null) RunStage(next, selectedProject);
    }

    void RunAllClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null) return;
        var stages = AutomaticStages(selectedProject).Where(x => !StageIsComplete(x, selectedProject)).ToList();
        if (stages.Count == 0) { AppendLog("All stages complete.", selectedProject.Id); return; }
        queuedStages[selectedProject.Id] = new Queue<Stage>(stages.Skip(1));
        RunStage(stages[0], selectedProject, true);
    }

    void RunStage(Stage stage, ProjectRecord? targetProject = null, bool continueQueued = false)
    {
        var project = targetProject ?? selectedProject;
        if (project == null) return;
        if (StageUnavailableReason(stage, project) is string reason)
        {
            AppendLog($"{stage.Title} cannot start: {reason}", project.Id);
            return;
        }
        if (!continueQueued) queuedStages.Remove(project.Id);
        try
        {
            if (stage == Stage.Preprocessing && !ValidateExternalRuntime(project)) return;
            Directory.CreateDirectory(project.SaveLocation);
            if (stage == Stage.Inference)
            {
                project.Settings.Preprocessing.SourcePositionInputLeft = null;
                project.Settings.Preprocessing.SourcePositionInputRight = null;
                Persist();
            }
            var config = PrepareConfig(project);
            var executable = BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
            var info = new ProcessStartInfo(executable, $"-m HRTFCalculation.CLI {stage.Value} --config {QuoteArgument(config)}") { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            ApplyProcessEnvironment(info);
            var process = new Process { StartInfo = info, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, args) => AppendLog(args.Data, project.Id);
            process.ErrorDataReceived += (_, args) => AppendLog(args.Data, project.Id);
            process.Exited += (_, _) => DispatcherQueue.TryEnqueue(() => ProcessFinished(process, project, stage));
            runningProcesses[project.Id] = process;
            runningStages[project.Id] = stage;
            FailedStages(project.Id).Remove(stage);
            if (!process.Start())
                throw new InvalidOperationException("Process.Start returned false.");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            AppendLog(stage.Title + " started.", project.Id);
            AppendLog($"{stage.Title} process: {executable}", project.Id);
            RefreshPipelineStatus();
        }
        catch (Exception error) { FailedStages(project.Id).Add(stage); AppendLog("Could not start " + stage.Title + ": " + error, project.Id); RefreshPipelineStatus(); }
    }

    void ProcessFinished(Process process, ProjectRecord project, Stage stage)
    {
        var code = process.ExitCode;
        if (code != 0) FailedStages(project.Id).Add(stage);
        runningProcesses.Remove(project.Id);
        runningStages.Remove(project.Id);
        AppendLog(code == 0 ? stage.Title + " finished." : stage.Title + " failed (status " + code + ").", project.Id);
        process.Dispose();
        RefreshArtifacts();
        if (code == 0 && queuedStages.TryGetValue(project.Id, out var queue) && queue.Count > 0) RunStage(queue.Dequeue(), project, true); else queuedStages.Remove(project.Id);
        RefreshPipelineStatus();
    }

    void ApplyProcessEnvironment(ProcessStartInfo info)
    {
        info.Environment["PINNA2HRTF_ROOT"] = Directory.GetParent(packageRoot)?.FullName ?? packageRoot;
        info.Environment["MPLCONFIGDIR"] = Path.Combine(appData, "Cache", "matplotlib");
        info.Environment["PYTHONPYCACHEPREFIX"] = Path.Combine(appData, "Cache", "python");
        info.Environment["PYTHONNOUSERSITE"] = "1";
        info.Environment["BLENDER_USER_CONFIG"] = Path.Combine(appData, "Blender", "config");
        info.Environment["BLENDER_USER_SCRIPTS"] = Path.Combine(appData, "Blender", "scripts");
        info.Environment["BLENDER_USER_DATAFILES"] = Path.Combine(appData, "Blender", "datafiles");
        info.Environment["PYTHONPATH"] = packageRoot + Path.PathSeparator + Path.Combine(packageRoot, ".venv", "Lib", "site-packages");
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
        // uv's Windows trampoline can retain an absolute interpreter reference
        // when a portable .venv is moved. Prefer the bundled managed CPython
        // directly; ApplyProcessEnvironment adds the venv site-packages path.
        var pythonRoot = Path.Combine(packageRoot, "Python");
        if (Directory.Exists(pythonRoot))
        {
            var versioned = Directory.EnumerateDirectories(pythonRoot, "cpython-*")
                .Where(path => Regex.IsMatch(Path.GetFileName(path), @"^cpython-\d+\.\d+\.\d+-"))
                .OrderByDescending(path => path, StringComparer.OrdinalIgnoreCase)
                .Select(path => Path.Combine(path, "python.exe"))
                .FirstOrDefault(File.Exists);
            if (versioned != null)
                return versioned;
        }
        var venvPath = Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        return File.Exists(venvPath) ? venvPath : null;
    }

    string PrepareConfig(ProjectRecord project)
    {
        var prepared = Clone(project);
        if (prepared.InputHandling == InputHandling.Copy)
        {
            if (!string.IsNullOrWhiteSpace(project.LeftEar)) prepared.LeftEar = CopyInput(project.LeftEar, Path.Combine(project.SaveLocation, "Input", "Left"));
            if (!string.IsNullOrWhiteSpace(project.RightEar)) prepared.RightEar = CopyInput(project.RightEar, Path.Combine(project.SaveLocation, "Input", "Right"));
            RebaseManualPosition(prepared.Settings.Preprocessing.SourcePositionInputLeft, project.LeftEar, prepared.LeftEar);
            RebaseManualPosition(prepared.Settings.Preprocessing.SourcePositionInputRight, project.RightEar, prepared.RightEar);
        }
        var config = Path.Combine(project.SaveLocation, "Project Settings.yaml");
        File.WriteAllText(config, Yaml(prepared), Encoding.UTF8);
        return config;
    }

    void RebaseManualPosition(ManualMicrophonePosition? position, string source, string path)
    {
        // Copying an input does not change a placement made on its predicted ear.
        if (PositionMatchesMesh(position, source) && !string.IsNullOrWhiteSpace(path)) { position!.MeshPath = path; position.MeshIdentity = MeshIdentity(path); }
    }

    string CopyInput(string path, string folder)
    {
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, Path.GetFileName(path));
        if (!Path.GetFullPath(path).Equals(Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase)) File.Copy(path, target, true);
        return target;
    }

    string Yaml(ProjectRecord project)
    {
        var output = project.SaveLocation;
        var inference = project.Settings.Inference;
        var preprocessing = project.Settings.Preprocessing;
        var numcalc = project.Settings.NumCalc;
        var post = project.Settings.Postprocessing ?? new PostprocessingSettings();
        var grid = string.IsNullOrWhiteSpace(preprocessing.EvaluationGrid) ? "Default" : preprocessing.EvaluationGrid;
        var steps = Math.Max(int.TryParse(preprocessing.FrequencyStepCount, out var n) ? n : 129, 2);
        var leftPosition = ValidManualPosition(project, "left") ? $"\n  source_position_input_left: [{preprocessing.SourcePositionInputLeft!.X.ToString(CultureInfo.InvariantCulture)}, {preprocessing.SourcePositionInputLeft.Y.ToString(CultureInfo.InvariantCulture)}, {preprocessing.SourcePositionInputLeft.Z.ToString(CultureInfo.InvariantCulture)}]" : "";
        var rightPosition = ValidManualPosition(project, "right") ? $"\n  source_position_input_right: [{preprocessing.SourcePositionInputRight!.X.ToString(CultureInfo.InvariantCulture)}, {preprocessing.SourcePositionInputRight.Y.ToString(CultureInfo.InvariantCulture)}, {preprocessing.SourcePositionInputRight.Z.ToString(CultureInfo.InvariantCulture)}]" : "";
        return $@"paths:
  left_ear: {YamlPath(project.LeftEar)}
  right_ear: {YamlPath(project.RightEar)}
  output_dir: {YamlScalar(output)}
  external_deps_dir: {YamlScalar(environment.ExternalDir)}
  numcalc_executable: {YamlScalar(environment.NumCalcExecutable)}
  mesh_grading_executable: {YamlScalar(environment.MeshGradingExecutable)}
  evaluation_grid: {YamlScalar(grid)}
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
  seam_smoothing_iterations: 5
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
  frequency_step_count: {steps}
  compute_hrirs: true
  pictures: false
  reference: true
  unit: mm
  speed_of_sound: ""346.18""
  air_density: ""1.1839""
  material_search_paths: None
  source_assignment_tolerance: 2.0
  source_assignment_face_count: {preprocessing.SourceAssignmentFaceCount}{leftPosition}{rightPosition}
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
  normalize: {Bool(post.Normalize)}
  level_offset_db: {post.LevelOffsetDB}
ui:
  mesh_background: white
  show_axes: true
";
    }

    string YamlScalar(string value) => "'" + value.Replace("'", "''") + "'";
    string YamlPath(string value) => string.IsNullOrWhiteSpace(value) ? "null" : YamlScalar(value);
    string Bool(bool value) => value ? "true" : "false";
    string QuoteArgument(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    void StopClicked(object sender, RoutedEventArgs e) { if (selectedProject != null) StopProject(selectedProject); }
    void StopProject(ProjectRecord project)
    {
        queuedStages.Remove(project.Id);
        if (runningProcesses.TryGetValue(project.Id, out var process))
        {
            TryTerminate(process);
            runningProcesses.Remove(project.Id);
            runningStages.Remove(project.Id);
            AppendLog("Stopping task.", project.Id);
        }
        RefreshPipelineStatus();
    }
    void TryTerminate(Process process) { try { if (!process.HasExited) process.Kill(true); } catch { } }
    void ResetOutputsClicked(object sender, RoutedEventArgs e) => ResetSelectedProjectOutputs();
    void ResetSelectedProjectOutputs()
    {
        if (selectedProject == null || runningProcesses.ContainsKey(selectedProject.Id)) return;
        if (placementSide != null) EndPlacement();
        foreach (var name in new[] { selectedProject.Settings.Inference.TargetLeftFolder, selectedProject.Settings.Inference.TargetRightFolder, selectedProject.Settings.Inference.PredictionLeftFolder, selectedProject.Settings.Inference.PredictionRightFolder, "Intermediates", "intermediates", "Projects", "HRTF", "Results Inference.csv" })
        {
            var path = Path.Combine(selectedProject.SaveLocation, name);
            if (ContainsPath(path, selectedProject.LeftEar) || ContainsPath(path, selectedProject.RightEar)) continue;
            try { if (Directory.Exists(path)) Directory.Delete(path, true); else if (File.Exists(path)) File.Delete(path); } catch (Exception error) { AppendLog("Could not reset " + path + ": " + error.Message, selectedProject.Id); }
        }
        selectedProject.Settings.Preprocessing.SourcePositionInputLeft = null;
        selectedProject.Settings.Preprocessing.SourcePositionInputRight = null;
        failedStages[selectedProject.Id] = [];
        Persist();
        RefreshArtifacts();
        RefreshPipelineStatus();
    }

    bool ContainsPath(string parent, string child)
    {
        if (string.IsNullOrWhiteSpace(parent) || string.IsNullOrWhiteSpace(child)) return false;
        var p = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var c = Path.GetFullPath(child);
        return c.Equals(p, StringComparison.OrdinalIgnoreCase) || c.StartsWith(p + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    void ClearLogClicked(object sender, RoutedEventArgs e) { if (selectedProject != null) projectLogs[selectedProject.Id] = ""; logText.Text = ""; }

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

    void RestoreLogScroll(double offset, bool followTail)
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            var scroll = FindDescendant<ScrollViewer>(logText);
            if (scroll == null) return;
            scroll.ChangeView(null, followTail ? scroll.ScrollableHeight : offset, null);
        });
    }

    void AppendLog(string? text, Guid? projectId = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var compact = string.Join(Environment.NewLine, text.Replace("\r\n", "\n").Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0 && !Path.IsPathRooted(x) && !x.Contains("Mem:") && !x.StartsWith("Fra:") && !x.StartsWith("Blender", StringComparison.OrdinalIgnoreCase)));
        if (compact.Length == 0) return;
        var id = projectId ?? selectedProject?.Id;
        if (id == null) return;
        void Append()
        {
            var scroll = FindDescendant<ScrollViewer>(logText);
            var oldOffset = scroll?.VerticalOffset ?? 0;
            var followTail = scroll == null || scroll.ScrollableHeight - scroll.VerticalOffset < 4;
            var current = projectLogs.TryGetValue(id.Value, out var value) ? value : "";
            projectLogs[id.Value] = current.Length == 0 ? compact : current + Environment.NewLine + compact;
            if (selectedProject?.Id == id)
            {
                logText.Text = projectLogs[id.Value];
                RestoreLogScroll(oldOffset, followTail);
            }
        }
        if (DispatcherQueue.HasThreadAccess) Append(); else DispatcherQueue.TryEnqueue(Append);
    }

    void RefreshNumCalcStatus() { numCalcStatusText.Text = selectedProject == null ? "No project selected" : NumCalcStatus(selectedProject); }
    void RefreshPipelineStatus()
    {
        if (selectedProject == null) return;
        var stages = Stage.GetValues();
        for (var i = 0; i < stages.Length; i++)
        {
            var stage = stages[i];
            var skipped = stage == Stage.Inference && !InferenceIsAutomatic(selectedProject);
            var running = runningStages.TryGetValue(selectedProject.Id, out var active) && active == stage;
            var failed = FailedStages(selectedProject.Id).Contains(stage);
            var reason = StageUnavailableReason(stage, selectedProject);
            stageStatus[i].Text = skipped ? "Skipped" : running ? "Running…" : failed ? "Failed" : StageIsComplete(stage, selectedProject) ? "Done" : reason != null ? "Blocked" : "Ready";
            stageStatus[i].Foreground = new SolidColorBrush(skipped ? ColorHelper.FromArgb(255, 130, 130, 130) : running ? Colors.DarkOrange : failed ? Colors.Firebrick : StageIsComplete(stage, selectedProject) ? Colors.ForestGreen : Colors.Gray);
            stageButtons[i].Content = running ? "Stop" : "Run";
            stageButtons[i].IsEnabled = placementSide == null && (running || StageCanRun(stage, selectedProject));
            ToolTipService.SetToolTip(stageStatus[i], reason ?? $"{stage.Title} is ready.");
            ToolTipService.SetToolTip(stageButtons[i], running ? "Stop this stage" : reason ?? $"Run {stage.Title}");
        }
        var pending = AutomaticStages(selectedProject).Where(x => !StageIsComplete(x, selectedProject)).ToList();
        runAllButton.IsEnabled = placementSide == null && pending.Count > 0 && StageCanRun(pending[0], selectedProject);
        var preprocessingReason = StageUnavailableReason(Stage.Preprocessing, selectedProject);
        var hint = placementSide != null ? "Finish microphone placement with Done or Cancel." :
            runningProcesses.ContainsKey(selectedProject.Id) ? null :
            preprocessingReason != null ? "Preprocessing: " + preprocessingReason :
            pending.Count > 0 ? StageUnavailableReason(pending[0], selectedProject) : null;
        pipelineHintText.Text = hint ?? "";
        pipelineHintText.Visibility = hint == null ? Visibility.Collapsed : Visibility.Visible;
        UpdatePlacementButtons();
        RefreshProjectList();
        RefreshNumCalcStatus();
    }

    bool InferenceIsAutomatic(ProjectRecord project) => project.Settings.Inference.UsePredictionsForPreprocessing && !string.IsNullOrWhiteSpace(project.LeftEar) && !string.IsNullOrWhiteSpace(project.RightEar);
    bool HasGeneratedPipelineOutputs(ProjectRecord project) => (!string.IsNullOrWhiteSpace(project.LeftEar) || !string.IsNullOrWhiteSpace(project.RightEar)) && !string.IsNullOrWhiteSpace(project.SaveLocation) && ((InferenceIsAutomatic(project) && StageIsComplete(Stage.Inference, project)) || StageIsComplete(Stage.Preprocessing, project) || StageIsComplete(Stage.Numcalc, project) || StageIsComplete(Stage.Postprocessing, project));
    bool PreprocessingBlocked(ProjectRecord project) => InferenceIsAutomatic(project) && !StageIsComplete(Stage.Inference, project);
    bool StageCanRun(Stage stage, ProjectRecord? project) => StageUnavailableReason(stage, project) == null;

    string? StageUnavailableReason(Stage stage, ProjectRecord? project)
    {
        if (project == null) return "Select a project first.";
        if (runningProcesses.ContainsKey(project.Id)) return "Wait for the running stage to finish.";
        if (placementProjectId == project.Id) return "Finish microphone placement with Done or Cancel.";
        if (string.IsNullOrWhiteSpace(project.SaveLocation)) return "Choose a project folder first.";
        if (string.IsNullOrWhiteSpace(project.LeftEar) && string.IsNullOrWhiteSpace(project.RightEar)) return "Select at least one input ear.";
        if ((!string.IsNullOrWhiteSpace(project.LeftEar) && !File.Exists(project.LeftEar)) || (!string.IsNullOrWhiteSpace(project.RightEar) && !File.Exists(project.RightEar))) return "An input ear file is missing. Select it again.";
        if (stage == Stage.Inference)
        {
            if (!InferenceIsAutomatic(project)) return "Enable Use BezierPPM and select both input ears.";
            return File.Exists(project.Settings.Inference.ModelConfig) && File.Exists(project.Settings.Inference.ModelCheckpoint) ? null : "The selected inference model is missing.";
        }
        if (stage == Stage.Preprocessing)
        {
            if (PreprocessingBlocked(project)) return "Run Mesh2PPM Inference to create both predicted ears first.";
            if (!File.Exists(environment.MeshGradingExecutable)) return "The Windows mesh-grading tool is missing. Rebuild the app with its external tools.";
            var bin = Path.Combine(environment.ExternalDir, "bin");
            if (new[] { "libpmp.dll", "libpmp_vis.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll" }.Any(name => !File.Exists(Path.Combine(bin, name))))
                return "The Windows mesh-grading runtime is incomplete. Rebuild the app with its external tools.";
            return File.Exists(Path.Combine(environment.ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf", "Mesh2Input", "mesh2input.py")) ? null : "The Mesh2HRTF export tools are missing.";
        }
        if (stage == Stage.Numcalc) return !StageIsComplete(Stage.Preprocessing, project) ? "Run Preprocessing first." : File.Exists(environment.NumCalcExecutable) ? null : "The NumCalc executable is missing.";
        return stage == Stage.Postprocessing && StageIsComplete(Stage.Numcalc, project) ? null : "Run NumCalc first.";
    }

    Stage[] AutomaticStages(ProjectRecord project) => InferenceIsAutomatic(project) ? Stage.GetValues() : [Stage.Preprocessing, Stage.Numcalc, Stage.Postprocessing];
    bool StageIsComplete(Stage stage, ProjectRecord project)
    {
        var output = project.SaveLocation;
        if (stage == Stage.Inference) return !InferenceIsAutomatic(project) || (PredictionMesh(project, "left") != null && PredictionMesh(project, "right") != null);
        if (stage == Stage.Preprocessing) return (string.IsNullOrWhiteSpace(project.LeftEar) || (File.Exists(Path.Combine(output, "Projects", "Left", "parameters.json")) && File.Exists(Path.Combine(output, "Intermediates", "Left", "graded_head.ply")))) && (string.IsNullOrWhiteSpace(project.RightEar) || (File.Exists(Path.Combine(output, "Projects", "Right", "parameters.json")) && File.Exists(Path.Combine(output, "Intermediates", "Right", "graded_head.ply"))));
        if (stage == Stage.Numcalc) return (string.IsNullOrWhiteSpace(project.LeftEar) || ContainsOutput2HRTF(Path.Combine(output, "Projects", "Left", "Output2HRTF"))) && (string.IsNullOrWhiteSpace(project.RightEar) || ContainsOutput2HRTF(Path.Combine(output, "Projects", "Right", "Output2HRTF")));
        return stage == Stage.Postprocessing && Directory.Exists(Path.Combine(output, "HRTF")) && Directory.GetFiles(Path.Combine(output, "HRTF"), "*.sofa").Any();
    }

    string NextStageSummary(ProjectRecord project) { if (runningStages.TryGetValue(project.Id, out var active)) return active.Title + ": Running"; var next = AutomaticStages(project).FirstOrDefault(x => !StageIsComplete(x, project)); return next == null ? "Complete" : next.Title + (StageCanRun(next, project) ? ": Ready" : ": Blocked"); }
    string NumCalcStatus(ProjectRecord project) => "NumCalc: " + string.Join(" · ", new[] { project.LeftEar, project.RightEar }.Select((x, i) => string.IsNullOrWhiteSpace(x) ? "" : (i == 0 ? "Left" : "Right") + " " + NumCalcCompleted(project, i == 0 ? "Left" : "Right") + "/" + NumCalcTotal(project, i == 0 ? "Left" : "Right")).Where(x => x.Length > 0));
    int NumCalcCompleted(ProjectRecord project, string side) { var folder = Path.Combine(project.SaveLocation, "Projects", side, "NumCalc", "source_1", "be.out"); return Directory.Exists(folder) ? Directory.GetDirectories(folder, "be.*").Length : 0; }
    int NumCalcTotal(ProjectRecord project, string side) { try { using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(project.SaveLocation, "Projects", side, "parameters.json"))); return document.RootElement.TryGetProperty("numFrequencies", out var value) ? value.GetInt32() : 0; } catch { return 0; } }
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
    void OpenDocumentationClicked(object sender, RoutedEventArgs e) => OpenExternal("https://github.com/Any2HRTF/Pinna2HRTF#readme");
    void OpenExternal(string url) { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { } }

    async void ShowAboutClicked(object sender, RoutedEventArgs e)
    {
        var version = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "1.0.0";
        var content = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        var logoPath = Path.Combine(AppContext.BaseDirectory, "app_icon.png");
        if (File.Exists(logoPath)) content.Children.Add(new Image { Source = new BitmapImage(new Uri(logoPath)), Width = 96, Height = 96, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "Pinna2HRTF", FontSize = 24, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "Version " + version, HorizontalAlignment = HorizontalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "A desktop pipeline for ear-mesh preprocessing, Mesh2PPM inference, Mesh2HRTF simulation, and SOFA export.", TextWrapping = TextWrapping.Wrap, MaxWidth = 360, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center });
        var dialog = new ContentDialog { Title = "About Pinna2HRTF", Content = content, CloseButtonText = "Close", XamlRoot = Root.XamlRoot };
        await dialog.ShowAsync();
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
        foreach (var label in stageStatusLabels) label.Foreground = mutedTextBrush;
        foreach (var row in projectRows.Values)
        {
            row.Name.Foreground = primaryTextBrush;
            row.Status.Foreground = mutedTextBrush;
        }
    }

    void AppWindowClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (closingConfirmed || runningProcesses.Count == 0) { if (placementSide != null) EndPlacement(); statusTimer.Stop(); Persist(); SaveUiState(); return; }
        args.Cancel = true;
        _ = ConfirmQuitAsync(sender);
    }

    async Task ConfirmQuitAsync(Microsoft.UI.Windowing.AppWindow appWindow)
    {
        var dialog = new ContentDialog { Title = "Quit Pinna2HRTF?", Content = "A pipeline task is still running. Quitting will stop it and may leave incomplete outputs.", PrimaryButtonText = "Quit", CloseButtonText = "Keep Running", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        closingConfirmed = true;
        foreach (var process in runningProcesses.Values.ToList()) TryTerminate(process);
        appWindow.Destroy();
    }

    void LoadRegistry()
    {
        if (File.Exists(registryPath)) try { registry = JsonSerializer.Deserialize<ProjectRegistry>(File.ReadAllText(registryPath), jsonOptions) ?? new ProjectRegistry(); } catch { registry = new ProjectRegistry(); }
        projects.Clear();
        foreach (var project in registry.Projects) projects.Add(project);
        if (projects.Count == 0) { var project = NewProject(1); projects.Add(project); }
        selectedProject = projects.FirstOrDefault(x => x.Id == registry.SelectedProjectID) ?? projects.FirstOrDefault();
    }

    void Persist()
    {
        registry = new ProjectRegistry { Projects = projects.ToList(), SelectedProjectID = selectedProject?.Id, Environment = environment };
        if (!string.IsNullOrWhiteSpace(registryPath)) File.WriteAllText(registryPath, JsonSerializer.Serialize(registry, jsonOptions));
    }

    void LoadViewerStates()
    {
        if (!File.Exists(viewerStatePath)) return;
        try { foreach (var pair in JsonSerializer.Deserialize<Dictionary<Guid, ProjectViewerState>>(File.ReadAllText(viewerStatePath), jsonOptions) ?? []) viewerStates[pair.Key] = pair.Value; } catch { viewerStates.Clear(); }
    }
    void SaveViewerStates() { if (!string.IsNullOrWhiteSpace(viewerStatePath)) File.WriteAllText(viewerStatePath, JsonSerializer.Serialize(viewerStates, jsonOptions)); }
    void LoadUiState() { if (!File.Exists(uiStatePath)) return; try { var state = JsonSerializer.Deserialize<WindowUiState>(File.ReadAllText(uiStatePath), jsonOptions); if (state != null) { projectsExpandedWidth = state.ProjectsWidth; liveLogExpandedHeight = state.LiveLogHeight; settingsExpandedWidth = state.SettingsWidth; } } catch { } }
    void SaveUiState() { if (!string.IsNullOrWhiteSpace(uiStatePath)) File.WriteAllText(uiStatePath, JsonSerializer.Serialize(new WindowUiState { ProjectsWidth = projectsExpandedWidth, LiveLogHeight = liveLogExpandedHeight, SettingsWidth = settingsExpandedWidth }, jsonOptions)); }
    string FindPackageRoot() { var current = new DirectoryInfo(AppContext.BaseDirectory); while (current != null) { if (File.Exists(Path.Combine(current.FullName, "pyproject.toml")) && Directory.Exists(Path.Combine(current.FullName, "HRTFCalculation"))) return current.FullName; current = current.Parent; } return AppContext.BaseDirectory; }
    EnvironmentConfig DefaultEnvironment() { var external = Path.Combine(packageRoot, "External"); var bin = Path.Combine(external, "bin"); return new EnvironmentConfig { UvExecutable = Path.Combine(bin, "uv.exe"), NumCalcExecutable = Path.Combine(bin, "NumCalc.exe"), MeshGradingExecutable = Path.Combine(bin, "hrtf_mesh_grading.exe"), ExternalDir = external }; }
    ProjectRecord Clone(ProjectRecord project) => JsonSerializer.Deserialize<ProjectRecord>(JsonSerializer.Serialize(project, jsonOptions), jsonOptions) ?? project;

    string? PreprocessingMesh(ProjectRecord project, string side)
    {
        if (InferenceIsAutomatic(project)) return PredictionMesh(project, side);
        var raw = side == "left" ? project.LeftEar : project.RightEar;
        return !string.IsNullOrWhiteSpace(raw) && File.Exists(raw) ? raw : null;
    }

    string? PredictionMesh(ProjectRecord project, string side)
    {
        var raw = side == "left" ? project.LeftEar : project.RightEar;
        if (string.IsNullOrWhiteSpace(raw) || string.IsNullOrWhiteSpace(project.SaveLocation)) return null;
        var folder = Path.Combine(project.SaveLocation, side == "left" ? project.Settings.Inference.PredictionLeftFolder : project.Settings.Inference.PredictionRightFolder);
        if (!Directory.Exists(folder)) return null;
        var stem = Path.GetFileNameWithoutExtension(raw);
        // Match RunConfig.predicted_stl's preferred filenames, never an ICP or head mesh.
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
    void InvalidateManualPositions(ProjectRecord project) { if (!ValidManualPosition(project, "left")) project.Settings.Preprocessing.SourcePositionInputLeft = null; if (!ValidManualPosition(project, "right")) project.Settings.Preprocessing.SourcePositionInputRight = null; }
    void RebaseManualPositionIfNeeded(ProjectRecord project) { InvalidateManualPositions(project); }
    string MeshIdentity(string path) { try { var file = new FileInfo(path); return Path.GetFullPath(path).ToLowerInvariant() + ":" + file.Length + ":" + file.LastWriteTimeUtc.Ticks; } catch { return ""; } }

    System.Numerics.Vector3? MicrophonePosition(string meshPath)
    {
        if (selectedProject == null) return null;
        foreach (var side in new[] { "left", "right" })
        {
            var sideTitle = CultureInfo.InvariantCulture.TextInfo.ToTitleCase(side);
            var simulationMesh = Path.Combine(selectedProject.SaveLocation, "Intermediates", sideTitle, "graded_head.ply");
            if (SamePath(meshPath, simulationMesh))
            {
                // Simulation coordinates are transformed during preprocessing. Always
                // use the exported source center, not a position on the original ear.
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

        public ProjectRowUi(ProjectRecord project)
        {
            Root = new Grid { Margin = new Thickness(8, 7, 8, 7), Tag = project, HorizontalAlignment = HorizontalAlignment.Stretch };
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
        }
    }
}

record Artifact(string Title, string Path, string? Side = null)
{
    public bool Exists => File.Exists(Path);
    public bool IsMesh => new[] { ".stl", ".ply" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
    public bool IsImage => new[] { ".jpg", ".jpeg", ".png", ".bmp", ".gif" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
    public bool IsText => new[] { ".txt", ".csv", ".json", ".yaml", ".yml", ".log", ".out" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
}

record Stage(string Value, string Title)
{
    public static readonly Stage Inference = new("inference", "Mesh2PPM Inference");
    public static readonly Stage Preprocessing = new("preprocessing", "Preprocessing");
    public static readonly Stage Numcalc = new("numcalc", "NumCalc");
    public static readonly Stage Postprocessing = new("postprocessing", "Postprocess");
    public static Stage[] GetValues() => [Inference, Preprocessing, Numcalc, Postprocessing];
}

enum InputHandling { Copy, Reference }
class ProjectRegistry { public List<ProjectRecord> Projects { get; set; } = []; public Guid? SelectedProjectID { get; set; } public EnvironmentConfig Environment { get; set; } = new(); }
class WindowUiState { public double ProjectsWidth { get; set; } = 280; public double LiveLogHeight { get; set; } = 170; public double SettingsWidth { get; set; } = 390; }
class ProjectViewerState { public string? SelectedArtifactPath { get; set; } public Dictionary<string, MeshCameraState> CameraByArtifact { get; set; } = []; }
class MeshCameraState { public double Yaw { get; set; } public double Pitch { get; set; } public double Distance { get; set; } }
class SettingHelpEntry { public string Id { get; set; } = ""; public string Title { get; set; } = ""; public string Description { get; set; } = ""; public List<SettingHelpPublication> Publications { get; set; } = []; }
class SettingHelpPublication { public string Title { get; set; } = ""; public string Url { get; set; } = ""; }
class EnvironmentConfig { public string UvExecutable { get; set; } = ""; public string NumCalcExecutable { get; set; } = ""; public string MeshGradingExecutable { get; set; } = ""; public string ExternalDir { get; set; } = ""; [JsonIgnore] public bool IsEmpty => string.IsNullOrWhiteSpace(NumCalcExecutable) && string.IsNullOrWhiteSpace(MeshGradingExecutable) && string.IsNullOrWhiteSpace(ExternalDir); }
class ProjectRecord { public Guid Id { get; set; } = Guid.NewGuid(); public string Name { get; set; } = ""; public string LeftEar { get; set; } = ""; public string RightEar { get; set; } = ""; public string SaveLocation { get; set; } = ""; public InputHandling InputHandling { get; set; } = InputHandling.Copy; public ProjectSettings Settings { get; set; } = new(); [JsonIgnore] public string StatusText { get; set; } = ""; [JsonIgnore] public bool IsRunning { get; set; } }
class ProjectSettings { public InferenceSettings Inference { get; set; } = new(); public PreprocessingSettings Preprocessing { get; set; } = new(); public NumCalcSettings NumCalc { get; set; } = new(); public PostprocessingSettings? Postprocessing { get; set; } = new(); }
class InferenceSettings { public string ModelConfig { get; set; } = ""; public string ModelCheckpoint { get; set; } = ""; public string TargetLeftFolder { get; set; } = "Input/Left"; public string TargetRightFolder { get; set; } = "Input/Right"; public string PredictionLeftFolder { get; set; } = "Intermediates/Left"; public string PredictionRightFolder { get; set; } = "Intermediates/Right"; public bool UsePredictionsForPreprocessing { get; set; } = true; }
class PreprocessingSettings { public string MinFrequency { get; set; } = "0"; public string MaxFrequency { get; set; } = "24000"; public string FrequencyStepCount { get; set; } = "129"; public string? EvaluationGrid { get; set; } public string? HeadRadius { get; set; } public bool? UseCustomHeadRadius { get; set; } public string SourceAssignmentFaceCount { get; set; } = "6"; public string MeshMinEdgeLength { get; set; } = "0.5"; public string MeshMaxEdgeLength { get; set; } = "10.0"; public string MeshMaxError { get; set; } = "0.5"; public string MeshGamma { get; set; } = "0.2"; public string MeshGammaOpposite { get; set; } = "0.1"; public ManualMicrophonePosition? SourcePositionInputLeft { get; set; } public ManualMicrophonePosition? SourcePositionInputRight { get; set; } }
class ManualMicrophonePosition { public double X { get; set; } public double Y { get; set; } public double Z { get; set; } public string MeshPath { get; set; } = ""; public string MeshIdentity { get; set; } = ""; }
class PostprocessingSettings { public bool Normalize { get; set; } = true; public string LevelOffsetDB { get; set; } = "-30"; }
class NumCalcSettings { public string MaxInstances { get; set; } = "1"; public string MaxCpuLoad { get; set; } = "90"; public bool AdaptiveFmmLength { get; set; } = true; }

sealed class CursorGrid : Grid
{
    public CursorGrid(InputSystemCursorShape shape)
    {
        // Cursor is assigned after the element is connected to the visual tree.
        // Creating WinUI input cursors during construction can crash unpackaged
        // WinUI apps on some Windows App SDK versions.
        Loaded += (_, _) => ProtectedCursor = InputSystemCursor.Create(shape);
    }

    public void SetCursor(InputSystemCursorShape value)
    {
        DispatcherQueue.TryEnqueue(() => ProtectedCursor = InputSystemCursor.Create(value));
    }
}

sealed class MeshInputController : InputController
{
    // Helix's WinUI defaults use a different button mapping for pan/rotate.
    // Keep the viewer's model-inspection convention explicit and deterministic.
    protected override bool IsStartRotate(Microsoft.UI.Input.PointerPointProperties properties) =>
        properties.IsLeftButtonPressed && !properties.IsMiddleButtonPressed && !properties.IsRightButtonPressed;

    protected override bool IsStartPan(Microsoft.UI.Input.PointerPointProperties properties) =>
        properties.IsMiddleButtonPressed;
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

    public static MeshData Load(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Mesh file was not found.", path);
        var mesh = NewGeometry();
        if (Path.GetExtension(path).Equals(".ply", StringComparison.OrdinalIgnoreCase)) LoadPly(path, mesh); else LoadStl(path, mesh);
        if (mesh.Positions == null || mesh.Indices == null || mesh.Positions.Count == 0 || mesh.Indices.Count < 3) throw new InvalidDataException($"Mesh contains no usable triangles: {path}");
        var min = new System.Numerics.Vector3(mesh.Positions.Min(x => x.X), mesh.Positions.Min(x => x.Y), mesh.Positions.Min(x => x.Z));
        var max = new System.Numerics.Vector3(mesh.Positions.Max(x => x.X), mesh.Positions.Max(x => x.Y), mesh.Positions.Max(x => x.Z));
        var center = (min + max) / 2;
        var maximum = Math.Max(max.X - min.X, Math.Max(max.Y - min.Y, max.Z - min.Z));
        var scale = 180 / Math.Max(maximum, 1);
        for (var i = 0; i < mesh.Positions.Count; i++) mesh.Positions[i] = (mesh.Positions[i] - center) * (float)scale;
        CalculateNormals(mesh);
        mesh.UpdateBounds();
        return new MeshData(path, mesh, center, scale, maximum * scale);
    }

    static void LoadStl(string path, MeshGeometry3D mesh)
    {
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
                    var start = mesh.Positions.Count;
                    for (var v = 0; v < 3; v++)
                    {
                        mesh.Positions.Add(new System.Numerics.Vector3(BitConverter.ToSingle(bytes, offset), BitConverter.ToSingle(bytes, offset + 4), BitConverter.ToSingle(bytes, offset + 8)));
                        offset += 12;
                    }
                    mesh.Indices.Add(start); mesh.Indices.Add(start + 1); mesh.Indices.Add(start + 2);
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
                var start = mesh.Positions.Count;
                foreach (var vertex in vertices) mesh.Positions.Add(vertex);
                mesh.Indices.Add(start); mesh.Indices.Add(start + 1); mesh.Indices.Add(start + 2);
                vertices.Clear();
            }
        }
        if (mesh.Indices.Count == 0) throw new InvalidDataException($"STL contains no usable triangles: {path}");
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
                mesh.Positions.Add(new System.Numerics.Vector3(x, y, z));
            }
            for (var i = 0; i < faceElement.Count; i++)
            {
                var tokens = (reader.ReadLine() ?? "").Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (tokens.Length == 0 || !int.TryParse(tokens[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) || count < 3 || tokens.Length < count + 1) continue;
                var indices = new int[count]; var valid = true;
                for (var j = 0; j < count; j++) if (!int.TryParse(tokens[j + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out indices[j]) || indices[j] < 0 || indices[j] >= vertexElement.Count) { valid = false; break; }
                if (!valid) continue;
                for (var j = 1; j < count - 1; j++) { mesh.Indices.Add(indices[0]); mesh.Indices.Add(indices[j]); mesh.Indices.Add(indices[j + 1]); }
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
                        mesh.Positions.Add(new System.Numerics.Vector3(coords[0], coords[1], coords[2]));
                    }
                    else if (element == faceElement)
                    {
                        List<int>? indices = null;
                        foreach (var property in element.Properties)
                        {
                            if (!property.IsList) { _ = ReadPlyScalar(reader, property.Type); continue; }
                            var n = checked((int)ReadPlyScalar(reader, property.CountType!)); var values = new List<int>(Math.Max(0, n));
                            for (var j = 0; j < n; j++) { var value = ReadPlyScalar(reader, property.ItemType!); values.Add(value is < 0 or > int.MaxValue ? -1 : (int)value); }
                            if (ReferenceEquals(property, faceList)) indices = values;
                        }
                        if (indices == null || indices.Count < 3 || indices.Any(index => index < 0 || index >= vertexElement.Count)) continue;
                        for (var j = 1; j < indices.Count - 1; j++) { mesh.Indices.Add(indices[0]); mesh.Indices.Add(indices[j]); mesh.Indices.Add(indices[j + 1]); }
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
        if (mesh.Indices.Count == 0) throw new InvalidDataException($"PLY contains no usable faces: {path}");
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
        var mesh = NewGeometry(); const int slices = 16; const int stacks = 8;
        for (var stack = 0; stack <= stacks; stack++) { var phi = Math.PI * stack / stacks; for (var slice = 0; slice <= slices; slice++) { var theta = 2 * Math.PI * slice / slices; mesh.Positions.Add(center + new System.Numerics.Vector3((float)(radius * Math.Sin(phi) * Math.Cos(theta)), (float)(radius * Math.Sin(phi) * Math.Sin(theta)), (float)(radius * Math.Cos(phi)))); } }
        for (var stack = 0; stack < stacks; stack++) for (var slice = 0; slice < slices; slice++) { var first = stack * (slices + 1) + slice; var second = first + slices + 1; mesh.Indices.Add(first); mesh.Indices.Add(second); mesh.Indices.Add(first + 1); mesh.Indices.Add(first + 1); mesh.Indices.Add(second); mesh.Indices.Add(second + 1); }
        CalculateNormals(mesh);
        mesh.UpdateBounds(); return mesh;
    }

    static void CalculateNormals(MeshGeometry3D mesh)
    {
        if (mesh.Positions == null || mesh.Indices == null)
            return;
        var normals = new Vector3Collection();
        for (var i = 0; i < mesh.Positions.Count; i++)
            normals.Add(System.Numerics.Vector3.Zero);
        for (var i = 0; i + 2 < mesh.Indices.Count; i += 3)
        {
            var ia = mesh.Indices[i];
            var ib = mesh.Indices[i + 1];
            var ic = mesh.Indices[i + 2];
            if (ia < 0 || ib < 0 || ic < 0 || ia >= mesh.Positions.Count || ib >= mesh.Positions.Count || ic >= mesh.Positions.Count)
                continue;
            var face = System.Numerics.Vector3.Cross(mesh.Positions[ib] - mesh.Positions[ia], mesh.Positions[ic] - mesh.Positions[ia]);
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
