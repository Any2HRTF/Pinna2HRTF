using HelixToolkit.Maths;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
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
using Windows.Foundation;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

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
    readonly DispatcherQueueTimer statusTimer;
    readonly Dictionary<string, Control> settingControls = [];
    readonly List<Button> stageButtons = [];
    readonly List<TextBlock> stageStatusLabels = [];
    readonly List<Expander> settingSections = [];
    ProjectRegistry registry = new();
    EnvironmentConfig environment = new();
    ProjectRecord? selectedProject;
    MeshGeometryModel3D? meshVisual;
    MeshGeometryModel3D? microphoneVisual;
    MeshData? currentMesh;
    string? selectedArtifactPath;
    string packageRoot = "";
    string appData = "";
    string registryPath = "";
    string viewerStatePath = "";
    string uiStatePath = "";
    double projectsExpandedWidth = 280;
    double liveLogExpandedHeight = 170;
    bool loading;
    bool refreshingArtifacts;
    bool rotatingMesh;
    bool pointerMoved;
    Point lastPointer;
    string? placementSide;
    ManualMicrophonePosition? pendingMicrophonePosition;
    bool closingConfirmed;
    Grid? contentGrid;
    ColumnDefinition? projectsColumn;
    ColumnDefinition? mainProjectsColumn;
    RowDefinition? liveLogRow;
    RowDefinition? mainLiveLogRow;
    ListView projectList = new();
    ComboBox artifactPicker = new();
    TextBlock selectedArtifactText = new();
    Image imagePreview = new();
    TextBlock viewerPlaceholder = new();
    Viewport3DX meshViewport = new();
    Border meshViewerBackground = new();
    TextBox logText = new();
    TextBlock numCalcStatusText = new();
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
        statusTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        statusTimer.Interval = TimeSpan.FromSeconds(2);
        statusTimer.Tick += (_, _) => { RefreshNumCalcStatus(); RefreshPipelineStatus(); };
        ExtendsContentIntoTitleBar = false;
        Activated += (_, _) => UpdateViewerAppearance();
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(id);
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
        if (projectsColumn != null) projectsColumn.Width = new GridLength(Math.Clamp(projectsExpandedWidth, 240, 520));
        if (liveLogRow != null) liveLogRow.Height = new GridLength(Math.Clamp(liveLogExpandedHeight, 100, 600));
        if (mainProjectsColumn != null) mainProjectsColumn.Width = new GridLength(Math.Clamp(projectsExpandedWidth, 240, 520));
        if (mainLiveLogRow != null) mainLiveLogRow.Height = new GridLength(Math.Clamp(liveLogExpandedHeight, 100, 600));
        environment = registry.Environment.IsEmpty ? DefaultEnvironment() : registry.Environment;
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
        RefreshArtifacts();
        UpdateViewerAppearance();
        statusTimer.Start();
        RefreshPipelineStatus();
    }

    void BuildInterface()
    {
        Root.Children.Clear();
        Root.Background = new SolidColorBrush(Colors.White);
        contentGrid = new Grid { Background = new SolidColorBrush(Colors.White) };
        projectsColumn = new ColumnDefinition { Width = new GridLength(projectsExpandedWidth), MinWidth = 240, MaxWidth = 420 };
        contentGrid.ColumnDefinitions.Add(projectsColumn);
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 420 });
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(390), MinWidth = 320, MaxWidth = 520 });
        contentGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        liveLogRow = new RowDefinition { Height = new GridLength(liveLogExpandedHeight) };
        contentGrid.RowDefinitions.Add(liveLogRow);
        Root.Children.Add(contentGrid);
        var menu = BuildMenu();
        Grid.SetColumnSpan(menu, 3);
        Grid.SetRow(menu, 0);
        menu.Margin = new Thickness(0, 0, 0, 0);
        var main = new Grid { Margin = new Thickness(0, 34, 0, 0) };
        mainProjectsColumn = new ColumnDefinition { Width = new GridLength(projectsExpandedWidth), MinWidth = 240, MaxWidth = 520 };
        main.ColumnDefinitions.Add(mainProjectsColumn);
        main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 420 });
        main.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(390), MinWidth = 320, MaxWidth = 520 });
        main.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        mainLiveLogRow = new RowDefinition { Height = new GridLength(liveLogExpandedHeight) };
        main.RowDefinitions.Add(mainLiveLogRow);
        Grid.SetColumnSpan(main, 3);
        Grid.SetRowSpan(main, 2);
        contentGrid.Children.Add(main);
        contentGrid.Children.Add(menu);
        var projectsPane = BuildProjectsPane();
        Grid.SetColumn(projectsPane, 0);
        main.Children.Add(projectsPane);
        var center = BuildCenterPane();
        Grid.SetColumn(center, 1);
        main.Children.Add(center);
        var settings = BuildSettingsPane();
        Grid.SetColumn(settings, 2);
        main.Children.Add(settings);
        Grid.SetRow(center, 0);
        Grid.SetRowSpan(center, 2);
        Grid.SetRow(settings, 0);
        Grid.SetRowSpan(settings, 2);
    }

    MenuBar BuildMenu()
    {
        var bar = new MenuBar { Background = new SolidColorBrush(Colors.Transparent) };
        var project = new MenuBarItem { Title = "Project" };
        project.Items.Add(MenuItem("New Project", CreateProjectClicked, "Ctrl+N"));
        project.Items.Add(MenuItem("Import Project", ImportProjectClicked, "Ctrl+Shift+O"));
        project.Items.Add(MenuItem("Duplicate Project", DuplicateProjectClicked, "Ctrl+D"));
        project.Items.Add(new MenuFlyoutSeparator());
        project.Items.Add(MenuItem("Delete Project", RemoveProjectClicked, "Ctrl+Delete"));
        var pipeline = new MenuBarItem { Title = "Pipeline" };
        pipeline.Items.Add(MenuItem("Run Next Step", RunNextClicked, "Ctrl+R"));
        pipeline.Items.Add(MenuItem("BezierPPM Inference", RunInferenceClicked));
        pipeline.Items.Add(MenuItem("Preprocessing", RunPreprocessingClicked));
        pipeline.Items.Add(MenuItem("NumCalc", RunNumCalcClicked));
        pipeline.Items.Add(MenuItem("Postprocessing", RunPostprocessingClicked));
        pipeline.Items.Add(new MenuFlyoutSeparator());
        pipeline.Items.Add(MenuItem("Stop", StopClicked, "Ctrl+."));
        pipeline.Items.Add(MenuItem("Run All", RunAllClicked));
        pipeline.Items.Add(MenuItem("Reset Outputs", ResetOutputsClicked));
        var help = new MenuBarItem { Title = "Help" };
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
        var pane = new Border { Background = new SolidColorBrush(Colors.White), BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(255, 220, 225, 228)), BorderThickness = new Thickness(0, 0, 1, 0) };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(14, 12, 10, 10) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = "Projects", FontSize = 20, VerticalAlignment = VerticalAlignment.Center });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        buttons.Children.Add(ProjectButton("＋", "New project", CreateProjectClicked));
        buttons.Children.Add(ProjectButton("⇧", "Import project", ImportProjectClicked));
        buttons.Children.Add(ProjectButton("⧉", "Duplicate selected project", DuplicateProjectClicked));
        buttons.Children.Add(ProjectButton("−", "Delete selected project", RemoveProjectClicked));
        Grid.SetColumn(buttons, 1);
        header.Children.Add(buttons);
        grid.Children.Add(header);
        projectList.SelectionChanged += ProjectSelectionChanged;
        projectList.Background = new SolidColorBrush(Colors.Transparent);
        projectList.BorderThickness = new Thickness(0);
        projectList.Margin = new Thickness(10, 0, 10, 10);
        Grid.SetRow(projectList, 1);
        grid.Children.Add(projectList);
        pane.Child = grid;
        return pane;
    }

    Button ProjectButton(string glyph, string tip, RoutedEventHandler handler)
    {
        var button = new Button { Content = glyph, Width = 32, Height = 32, Padding = new Thickness(0), ToolTip = tip };
        button.Click += handler;
        return button;
    }

    Grid BuildCenterPane()
    {
        var grid = new Grid { Margin = new Thickness(14, 48, 14, 14) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var preview = new Border { CornerRadius = new CornerRadius(8), BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(255, 220, 225, 228)), BorderThickness = new Thickness(1), Background = new SolidColorBrush(Colors.White) };
        var previewGrid = new Grid();
        previewGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(86) });
        previewGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(16, 10, 16, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titlePanel = new StackPanel();
        titlePanel.Children.Add(new TextBlock { Text = "Preview", FontSize = 20, FontWeight = FontWeights.SemiBold });
        selectedArtifactText = new TextBlock { Text = "Select a file to preview", Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)), TextTrimming = TextTrimming.CharacterEllipsis };
        titlePanel.Children.Add(selectedArtifactText);
        header.Children.Add(titlePanel);
        var pickerPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        placeLeftButton = new Button { Content = "Place Left Mic", MinWidth = 108 };
        placeRightButton = new Button { Content = "Place Right Mic", MinWidth = 112 };
        placeLeftButton.Click += (_, _) => BeginPlacement("left");
        placeRightButton.Click += (_, _) => BeginPlacement("right");
        pickerPanel.Children.Add(placeLeftButton);
        pickerPanel.Children.Add(placeRightButton);
        artifactPicker.Width = 230;
        artifactPicker.ItemsSource = artifacts;
        artifactPicker.DisplayMemberPath = "Title";
        artifactPicker.SelectionChanged += ArtifactSelectionChanged;
        pickerPanel.Children.Add(artifactPicker);
        Grid.SetColumn(pickerPanel, 1);
        header.Children.Add(pickerPanel);
        previewGrid.Children.Add(header);
        meshViewerBackground = new Border { Background = new SolidColorBrush(ColorHelper.FromArgb(255, 237, 243, 242)) };
        Grid.SetRow(meshViewerBackground, 1);
        var viewerGrid = new Grid();
        meshViewport = new Viewport3DX { IsRotationEnabled = true, IsZoomEnabled = true, EnableMouseButtonHitTest = true, ModelUpDirection = new System.Numerics.Vector3(0, 0, 1), BackgroundColor = new Color4(0.93f, 0.95f, 0.95f, 1) };
        meshViewport.PointerPressed += MeshViewportPointerPressed;
        meshViewport.PointerMoved += MeshViewportPointerMoved;
        meshViewport.PointerReleased += MeshViewportPointerReleased;
        meshViewport.PointerWheelChanged += MeshViewportPointerWheelChanged;
        viewerGrid.Children.Add(meshViewport);
        imagePreview = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(18), Visibility = Visibility.Collapsed };
        viewerGrid.Children.Add(imagePreview);
        viewerPlaceholder = new TextBlock { Text = "No preview selected", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontSize = 18, Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)) };
        viewerGrid.Children.Add(viewerPlaceholder);
        placementBorder = new Border { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(10), Visibility = Visibility.Collapsed, Background = new SolidColorBrush(ColorHelper.FromArgb(230, 255, 255, 255)), Padding = new Thickness(10, 7, 10, 7) };
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
        var log = BuildLogPane();
        Grid.SetRow(log, 1);
        grid.Children.Add(log);
        return grid;
    }

    Border BuildLogPane()
    {
        var panel = new Border { Margin = new Thickness(0, 10, 0, 0), Background = new SolidColorBrush(Colors.White), BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(255, 220, 225, 228)), BorderThickness = new Thickness(1) };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(34) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid { Margin = new Thickness(10, 0, 6, 0) };
        header.Children.Add(new TextBlock { Text = "Live Log", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var clear = new Button { Content = "Clear", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(10, 2, 10, 2) };
        clear.Click += ClearLogClicked;
        header.Children.Add(clear);
        grid.Children.Add(header);
        logText = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), FontSize = 12, BorderThickness = new Thickness(0), Margin = new Thickness(10) };
        ScrollViewer.SetVerticalScrollBarVisibility(logText, ScrollBarVisibility.Auto);
        Grid.SetRow(logText, 1);
        grid.Children.Add(logText);
        panel.Child = grid;
        return panel;
    }

    Border BuildSettingsPane()
    {
        var pane = new Border { Background = new SolidColorBrush(ColorHelper.FromArgb(255, 251, 251, 252)), BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(255, 220, 225, 228)), BorderThickness = new Thickness(1, 0, 0, 0) };
        var outer = new Grid();
        outer.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        outer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var settings = new StackPanel { Margin = new Thickness(14) };
        settings.Children.Add(new TextBlock { Text = "Project", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        AddSetting(settings, "Project name", "project.name", projectNameBox);
        AddPathSetting(settings, "Left ear (optional)", "project.left_ear", leftEarBox, BrowseLeftEarClicked);
        AddPathSetting(settings, "Right ear (optional)", "project.right_ear", rightEarBox, BrowseRightEarClicked);
        AddPathSetting(settings, "Save location", "project.save_location", saveLocationBox, BrowseSaveLocationClicked);
        settings.Children.Add(new TextBlock { Text = "Choose at least one ear mesh.", Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)), Margin = new Thickness(0, 3, 0, 4) });
        AddSetting(settings, "Use BezierPPM", "project.use_bezierppm", usePredictionsBox, "Use BezierPPM");
        AddExpander(settings, "BezierPPM Inference", [AddSettingPanel("Model", "inference.model", modelPicker)]);
        AddPathSetting(settings, "Evaluation grid", "mesh2hrtf.evaluation_grid", evaluationGridBox, BrowseEvaluationGridClicked, true);
        AddExpander(settings, "Mesh2HRTF", [AddSettingPanel("Use custom head radius", "mesh2hrtf.use_head_radius", useHeadRadiusBox, "Use custom head radius"), AddSettingPanel("Head radius", "mesh2hrtf.head_radius", headRadiusBox), AddSettingPanel("Min frequency", "mesh2hrtf.min_frequency", minFrequencyBox), AddSettingPanel("Max frequency", "mesh2hrtf.max_frequency", maxFrequencyBox), AddSettingPanel("Frequency steps (minimum 2)", "mesh2hrtf.frequency_steps", frequencyStepsBox), AddSettingPanel("Microphone faces", "mesh2hrtf.microphone_faces", microphoneFacesBox)]);
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
        var row = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        if (control is CheckBox checkBox)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            checkBox.Content = checkBoxText ?? label;
            checkBox.HorizontalAlignment = HorizontalAlignment.Left;
            row.Children.Add(checkBox);
            var info = new Button { Content = "ⓘ", Width = 25, Height = 25, Padding = new Thickness(0), Margin = new Thickness(6, 0, 0, 0), Tag = id, ToolTip = "Show information" };
            info.Click += SettingInfoClicked;
            Grid.SetColumn(info, 1);
            row.Children.Add(info);
        }
        else
        {
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var labelPanel = new StackPanel { Orientation = Orientation.Horizontal };
            labelPanel.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
            var info = new Button { Content = "ⓘ", Width = 25, Height = 25, Padding = new Thickness(0), Margin = new Thickness(6, 0, 0, 0), Tag = id, ToolTip = "Show information" };
            info.Click += SettingInfoClicked;
            labelPanel.Children.Add(info);
            row.Children.Add(labelPanel);
            Grid.SetRow(control, 1);
            row.Children.Add(control);
        }
        control.Tag = id;
        settingControls[id] = control;
        if (control is TextBox textBox)
            textBox.TextChanged += ProjectEdited;
        if (control is CheckBox box)
        {
            box.Checked += ProjectEdited;
            box.Unchecked += ProjectEdited;
        }
        if (control is ComboBox combo)
            combo.SelectionChanged += ModelSelectionChanged;
        return row;
    }

    void AddPathSetting(StackPanel parent, string label, string id, TextBox box, RoutedEventHandler handler, bool nested = false)
    {
        AddSetting(parent, label, id, box);
        var browse = new Button { Content = "Browse", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, -2, 0, 2) };
        browse.Click += handler;
        parent.Children.Add(browse);
    }

    void AddExpander(StackPanel parent, string title, IEnumerable<Grid> children)
    {
        var panel = new StackPanel { Spacing = 3 };
        foreach (var child in children)
            panel.Children.Add(child);
        var expander = new Expander { Header = title, Content = panel, IsExpanded = false, Margin = new Thickness(0, 8, 0, 0) };
        settingSections.Add(expander);
        parent.Children.Add(expander);
    }

    Border BuildStagesPane()
    {
        var border = new Border { BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(255, 220, 225, 228)), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(14, 8, 14, 12) };
        var stack = new StackPanel();
        var stages = Stage.GetValues();
        for (var i = 0; i < stages.Length; i++)
        {
            var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = stages[i].Title, VerticalAlignment = VerticalAlignment.Center });
            Grid.SetColumn(stageStatus[i], 1);
            stageStatus[i].Margin = new Thickness(10, 0, 12, 0);
            stageStatus[i].VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(stageStatus[i]);
            var button = new Button { Content = "Run", Width = 62, Padding = new Thickness(8, 3, 8, 3), Tag = stages[i] };
            button.Click += StageButtonClicked;
            stageButtons.Add(button);
            Grid.SetColumn(button, 2);
            row.Children.Add(button);
            stack.Children.Add(row);
        }
        runAllButton = new Button { Content = "Run All", Height = 34, Margin = new Thickness(0, 8, 0, 0), Background = new SolidColorBrush(ColorHelper.FromArgb(255, 111, 159, 156)), Foreground = new SolidColorBrush(Colors.White), HorizontalContentAlignment = HorizontalAlignment.Center };
        runAllButton.Click += RunAllClicked;
        stack.Children.Add(runAllButton);
        var statusRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        numCalcStatusText = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)) };
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

    void RefreshProjectList()
    {
        var index = selectedProject == null ? -1 : projects.IndexOf(selectedProject);
        projectList.Items.Clear();
        foreach (var project in projects)
        {
            project.IsRunning = runningProcesses.ContainsKey(project.Id);
            project.StatusText = NextStageSummary(project);
            var row = new Grid { Margin = new Thickness(8, 7, 8, 7), Tag = project };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = project.Name, FontWeight = FontWeights.SemiBold, FontSize = 14 });
            text.Children.Add(new TextBlock { Text = project.StatusText, FontSize = 11, Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 105, 113, 125)) });
            row.Children.Add(text);
            var spinner = new ProgressRing { Width = 17, Height = 17, IsActive = project.IsRunning, Visibility = project.IsRunning ? Visibility.Visible : Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(spinner, 1);
            row.Children.Add(spinner);
            projectList.Items.Add(row);
        }
        if (index >= 0 && index < projectList.Items.Count && projectList.SelectedIndex != index)
            projectList.SelectedIndex = index;
    }

    void LoadSelectedProjectLog()
    {
        logText.Text = selectedProject != null && projectLogs.TryGetValue(selectedProject.Id, out var value) ? value : "";
    }

    void RefreshModelOptions()
    {
        modelPicker.Items.Clear();
        var resources = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        foreach (var path in Directory.Exists(resources) ? Directory.GetFiles(resources, "*.yaml").OrderBy(x => x) : [])
            modelPicker.Items.Add(Path.GetFileNameWithoutExtension(path));
    }

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
        }
        InvalidateManualPositions(duplicate);
        projects.Add(duplicate);
        failedStages[duplicate.Id] = [];
        selectedProject = duplicate;
        Persist();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
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

    async void BrowseLeftEarClicked(object sender, RoutedEventArgs e) { var path = await PickFileAsync(); if (path != null) leftEarBox.Text = path; }
    async void BrowseRightEarClicked(object sender, RoutedEventArgs e) { var path = await PickFileAsync(); if (path != null) rightEarBox.Text = path; }
    async void BrowseSaveLocationClicked(object sender, RoutedEventArgs e) { var path = await PickFolderAsync(); if (path != null) saveLocationBox.Text = path; }
    async void BrowseEvaluationGridClicked(object sender, RoutedEventArgs e) { var path = await PickFolderAsync(); if (path != null) evaluationGridBox.Text = path; }

    async Task<string?> PickFileAsync()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    async Task<string?> PickFolderAsync()
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    void RefreshArtifacts()
    {
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
        if (Directory.Exists(hrtf))
            foreach (var file in Directory.EnumerateFiles(hrtf).Where(x => new[] { ".jpg", ".jpeg", ".png" }.Contains(Path.GetExtension(x).ToLowerInvariant())).OrderBy(x => x))
                list.Add(new Artifact(Path.GetFileNameWithoutExtension(file), file));
        if (!string.IsNullOrWhiteSpace(project.LeftEar))
        {
            list.Add(new Artifact("Input left ear", project.LeftEar));
            list.Add(new Artifact("Left simulation mesh", Path.Combine(project.SaveLocation, "Intermediates", "Left", "graded_head.ply")));
            AddMeshFolder(list, "Predicted left ear", Path.Combine(project.SaveLocation, project.Settings.Inference.PredictionLeftFolder));
        }
        if (!string.IsNullOrWhiteSpace(project.RightEar))
        {
            list.Add(new Artifact("Input right ear", project.RightEar));
            list.Add(new Artifact("Right simulation mesh", Path.Combine(project.SaveLocation, "Intermediates", "Right", "graded_head.ply")));
            AddMeshFolder(list, "Predicted right ear", Path.Combine(project.SaveLocation, project.Settings.Inference.PredictionRightFolder));
        }
        return list;
    }

    void AddMeshFolder(List<Artifact> list, string title, string folder)
    {
        if (!Directory.Exists(folder))
            return;
        foreach (var file in Directory.EnumerateFiles(folder).Where(IsMesh).OrderBy(x => x))
            if (Path.GetFileName(file).StartsWith("Prediction_", StringComparison.OrdinalIgnoreCase))
                list.Add(new Artifact(title + " - " + Path.GetFileNameWithoutExtension(file), file));
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
        RememberSelectedArtifact(artifact.Path);
        selectedArtifactText.Text = Path.GetFileName(artifact.Path);
        if (artifact.IsImage)
        {
            try { imagePreview.Source = new BitmapImage(new Uri(artifact.Path)); imagePreview.Visibility = Visibility.Visible; viewerPlaceholder.Visibility = Visibility.Collapsed; }
            catch (Exception error) { AppendLog("Cannot open image: " + error.Message); }
            return;
        }
        if (artifact.IsMesh)
        {
            try
            {
                currentMesh = MeshLoader.Load(artifact.Path);
                meshVisual = new MeshGeometryModel3D { Geometry = currentMesh.Geometry, Material = new PhongMaterial { DiffuseColor = new Color4(0.38f, 0.57f, 0.56f, 1), SpecularColor = new Color4(0.7f, 0.78f, 0.76f, 1) }, CullMode = SharpDX.Direct3D11.CullMode.None };
                meshVisual.RenderWireframe = string.Equals(Path.GetExtension(artifact.Path), ".ply", StringComparison.OrdinalIgnoreCase);
                meshVisual.WireframeColor = new Color4(0.12f, 0.22f, 0.22f, 0.55f);
                meshViewport.Items.Add(meshVisual);
                AddMicrophoneMarker(artifact.Path);
                ResetMeshCamera();
                viewerPlaceholder.Visibility = Visibility.Collapsed;
                meshViewport.Visibility = Visibility.Visible;
                placeLeftButton.IsEnabled = placementSide == null && currentMesh != null && IsLeftMesh(artifact.Path);
                placeRightButton.IsEnabled = placementSide == null && currentMesh != null && IsRightMesh(artifact.Path);
            }
            catch (Exception error) { AppendLog("Cannot open mesh: " + error.Message); }
            return;
        }
        viewerPlaceholder.Text = artifact.IsText ? SafeReadText(artifact.Path) : "Preview unavailable for " + Path.GetFileName(artifact.Path);
        viewerPlaceholder.Visibility = Visibility.Visible;
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
        microphoneVisual = new MeshGeometryModel3D { Geometry = MeshLoader.CreateSphere(p, Math.Max(currentMesh.MaximumDimension * 0.003, 0.18)), Material = new PhongMaterial { DiffuseColor = new Color4(1f, 0.58f, 0f, 1), EmissiveColor = new Color4(0.35f, 0.12f, 0f, 1) }, IsHitTestVisible = false };
        meshViewport.Items.Add(microphoneVisual);
    }

    void ResetViewer()
    {
        if (meshVisual != null) meshViewport.Items.Remove(meshVisual);
        if (microphoneVisual != null) meshViewport.Items.Remove(microphoneVisual);
        meshVisual = null;
        microphoneVisual = null;
        currentMesh = null;
        imagePreview.Source = null;
        imagePreview.Visibility = Visibility.Collapsed;
        meshViewport.Visibility = Visibility.Visible;
        viewerPlaceholder.Text = "No preview selected";
        viewerPlaceholder.Visibility = Visibility.Visible;
        selectedArtifactText.Text = "Select a file to preview";
        selectedArtifactPath = null;
        placeLeftButton.IsEnabled = false;
        placeRightButton.IsEnabled = false;
    }

    void MeshViewportPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (meshVisual == null)
            return;
        lastPointer = e.GetCurrentPoint(meshViewport).Position;
        pointerMoved = false;
        rotatingMesh = true;
        meshViewport.CapturePointer(e.Pointer);
    }

    void MeshViewportPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!rotatingMesh)
            return;
        var point = e.GetCurrentPoint(meshViewport).Position;
        if (Math.Abs(point.X - lastPointer.X) + Math.Abs(point.Y - lastPointer.Y) > 4)
            pointerMoved = true;
        lastPointer = point;
    }

    void MeshViewportPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(meshViewport).Position;
        meshViewport.ReleasePointerCapture(e.Pointer);
        rotatingMesh = false;
        SaveMeshCamera();
        if (placementSide != null && !pointerMoved && currentMesh != null && meshVisual != null)
        {
            var hit = meshViewport.FindHits(point).FirstOrDefault(x => ReferenceEquals(x.ModelHit, meshVisual));
            if (hit != null)
            {
                var raw = currentMesh.ToRaw(hit.PointHit);
                pendingMicrophonePosition = new ManualMicrophonePosition { X = raw.X, Y = raw.Y, Z = raw.Z, MeshPath = currentMesh.Path, MeshIdentity = MeshIdentity(currentMesh.Path) };
                UpdateMicrophoneMarker(raw);
                placementCoordinates.Text = $"{placementSide} mic: {raw.X:0.##}, {raw.Y:0.##}, {raw.Z:0.##} mm";
                donePositionButton.IsEnabled = true;
            }
        }
    }

    void MeshViewportPointerWheelChanged(object sender, PointerRoutedEventArgs e) => SaveMeshCamera();

    void UpdateMicrophoneMarker(System.Numerics.Vector3 raw)
    {
        if (currentMesh == null)
            return;
        if (microphoneVisual != null) meshViewport.Items.Remove(microphoneVisual);
        microphoneVisual = new MeshGeometryModel3D { Geometry = MeshLoader.CreateSphere(currentMesh.ToDisplay(raw), Math.Max(currentMesh.MaximumDimension * 0.003, 0.18)), Material = new PhongMaterial { DiffuseColor = new Color4(1f, 0.58f, 0f, 1), EmissiveColor = new Color4(0.35f, 0.12f, 0f, 1) }, IsHitTestVisible = false };
        meshViewport.Items.Add(microphoneVisual);
    }

    void BeginPlacement(string side)
    {
        if (selectedProject == null || selectedArtifactPath == null || currentMesh == null)
            return;
        if (!string.Equals(side, SideForPath(selectedArtifactPath), StringComparison.OrdinalIgnoreCase))
            return;
        var mesh = PreprocessingMesh(selectedProject, side);
        if (mesh == null)
        {
            AppendLog("Select the mesh used for preprocessing before placing the microphone.", selectedProject.Id);
            return;
        }
        if (!Path.GetFullPath(currentMesh.Path).Equals(Path.GetFullPath(mesh), StringComparison.OrdinalIgnoreCase))
        {
            var artifact = artifacts.FirstOrDefault(x => Path.GetFullPath(x.Path).Equals(Path.GetFullPath(mesh), StringComparison.OrdinalIgnoreCase));
            if (artifact != null) OpenArtifact(artifact);
            if (currentMesh == null || !Path.GetFullPath(currentMesh.Path).Equals(Path.GetFullPath(mesh), StringComparison.OrdinalIgnoreCase)) return;
        }
        placementSide = side;
        pendingMicrophonePosition = null;
        placementCoordinates.Text = "Click the mesh to place the microphone";
        donePositionButton.IsEnabled = false;
        placementBorder.Visibility = Visibility.Visible;
        artifactPicker.IsEnabled = false;
        foreach (var button in stageButtons) button.IsEnabled = false;
        runAllButton.IsEnabled = false;
        placeLeftButton.IsEnabled = false;
        placeRightButton.IsEnabled = false;
    }

    async void AutomaticPositionClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null || placementSide == null)
            return;
        var mesh = PreprocessingMesh(selectedProject, placementSide);
        if (mesh == null)
        {
            AppendLog("The preprocessing mesh is not available.", selectedProject.Id);
            return;
        }
        automaticPositionButton.IsEnabled = false;
        try
        {
            var position = await CalculateAutomaticPosition(mesh, placementSide);
            pendingMicrophonePosition = new ManualMicrophonePosition { X = position.X, Y = position.Y, Z = position.Z, MeshPath = mesh, MeshIdentity = MeshIdentity(mesh) };
            if (string.Equals(SideForPath(selectedArtifactPath ?? ""), placementSide, StringComparison.OrdinalIgnoreCase))
            {
                UpdateMicrophoneMarker(position);
                placementCoordinates.Text = $"{placementSide} mic: {position.X:0.##}, {position.Y:0.##}, {position.Z:0.##} mm";
            }
            donePositionButton.IsEnabled = true;
        }
        catch (Exception error) { AppendLog("Automatic microphone position failed: " + error.Message, selectedProject.Id); }
        finally { automaticPositionButton.IsEnabled = true; }
    }

    async Task<System.Numerics.Vector3> CalculateAutomaticPosition(string mesh, string side)
    {
        var landmark = Path.Combine(appData, "Cache", "automatic-landmark-" + Guid.NewGuid().ToString("N") + ".json");
        var executable = BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        var info = new ProcessStartInfo(executable, $"-m HRTFCalculation.Preprocessing.src.ear_canal_closer --ear_path {QuoteArgument(mesh)} --landmark_path {QuoteArgument(landmark)} --side {side} --estimate-only") { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        ApplyProcessEnvironment(info);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Could not start the bundled Python environment.");
        var output = await process.StandardOutput.ReadToEndAsync();
        var error = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        try
        {
            if (process.ExitCode != 0)
                throw new InvalidOperationException(error.Trim());
            using var document = JsonDocument.Parse(File.Exists(landmark) ? File.ReadAllText(landmark) : output);
            var values = document.RootElement.GetProperty("position").EnumerateArray().Select(x => (float)x.GetDouble()).ToArray();
            if (values.Length != 3) throw new InvalidDataException("The estimator returned an invalid position.");
            return new System.Numerics.Vector3(values[0], values[1], values[2]);
        }
        finally { if (File.Exists(landmark)) File.Delete(landmark); }
    }

    void DonePositionClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null || placementSide == null || pendingMicrophonePosition == null)
            return;
        if (placementSide == "left") selectedProject.Settings.Preprocessing.SourcePositionInputLeft = pendingMicrophonePosition; else selectedProject.Settings.Preprocessing.SourcePositionInputRight = pendingMicrophonePosition;
        Persist();
        AppendLog($"Saved {placementSide} microphone position.", selectedProject.Id);
        EndPlacement();
        RefreshArtifacts();
    }

    void CancelPositionClicked(object sender, RoutedEventArgs e) => EndPlacement();

    void EndPlacement()
    {
        placementSide = null;
        pendingMicrophonePosition = null;
        placementBorder.Visibility = Visibility.Collapsed;
        artifactPicker.IsEnabled = true;
        placeLeftButton.IsEnabled = currentMesh != null && IsLeftMesh(selectedArtifactPath ?? "");
        placeRightButton.IsEnabled = currentMesh != null && IsRightMesh(selectedArtifactPath ?? "");
        RefreshPipelineStatus();
    }

    void ResetMeshCamera()
    {
        var state = selectedProject != null && selectedArtifactPath != null && viewerStates.TryGetValue(selectedProject.Id, out var projectState) && projectState.CameraByArtifact.TryGetValue(selectedArtifactPath, out var saved) ? saved : new MeshCameraState { Yaw = IsLeftMesh(selectedArtifactPath ?? "") ? 180 : 0, Pitch = 8, Distance = Math.Max(currentMesh?.MaximumDimension * 1.7 ?? 300, 120) };
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
        if (project == null || runningProcesses.ContainsKey(project.Id) || !StageCanRun(stage, project)) return;
        if (!continueQueued) queuedStages.Remove(project.Id);
        try
        {
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
            using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, args) => AppendLog(args.Data, project.Id);
            process.ErrorDataReceived += (_, args) => AppendLog(args.Data, project.Id);
            process.Exited += (_, _) => DispatcherQueue.TryEnqueue(() => ProcessFinished(process, project, stage));
            runningProcesses[project.Id] = process;
            runningStages[project.Id] = stage;
            FailedStages(project.Id).Remove(stage);
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            AppendLog(stage.Title + " started.", project.Id);
            RefreshPipelineStatus();
        }
        catch (Exception error) { FailedStages(project.Id).Add(stage); AppendLog("Could not start " + stage.Title + ": " + error.Message, project.Id); RefreshPipelineStatus(); }
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

    string? BundledPythonExecutable() { var path = Path.Combine(packageRoot, ".venv", "Scripts", "python.exe"); return File.Exists(path) ? path : null; }

    string PrepareConfig(ProjectRecord project)
    {
        var prepared = Clone(project);
        if (prepared.InputHandling == InputHandling.Copy)
        {
            if (!string.IsNullOrWhiteSpace(project.LeftEar)) prepared.LeftEar = CopyInput(project.LeftEar, Path.Combine(project.SaveLocation, "Input", "Left"));
            if (!string.IsNullOrWhiteSpace(project.RightEar)) prepared.RightEar = CopyInput(project.RightEar, Path.Combine(project.SaveLocation, "Input", "Right"));
            RebaseManualPosition(prepared.Settings.Preprocessing.SourcePositionInputLeft, prepared.LeftEar);
            RebaseManualPosition(prepared.Settings.Preprocessing.SourcePositionInputRight, prepared.RightEar);
        }
        var config = Path.Combine(project.SaveLocation, "Project Settings.yaml");
        File.WriteAllText(config, Yaml(prepared), Encoding.UTF8);
        return config;
    }

    void RebaseManualPosition(ManualMicrophonePosition? position, string path)
    {
        if (position != null && !string.IsNullOrWhiteSpace(path)) { position.MeshPath = path; position.MeshIdentity = MeshIdentity(path); }
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
        return $"""paths:
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
  speed_of_sound: "346.18"
  air_density: "1.1839"
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
""";
    }

    string YamlScalar(string value) => "'" + value.Replace("'", "''") + "'";
    string YamlPath(string value) => string.IsNullOrWhiteSpace(value) ? "null" : YamlScalar(value);
    string Bool(bool value) => value ? "true" : "false";
    string QuoteArgument(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    void StopClicked(object sender, RoutedEventArgs e) { if (selectedProject != null) StopProject(selectedProject); }
    void StopProject(ProjectRecord project) { queuedStages.Remove(project.Id); if (runningProcesses.TryGetValue(project.Id, out var process)) { TryTerminate(process); AppendLog("Stopping task.", project.Id); } RefreshPipelineStatus(); }
    void TryTerminate(Process process) { try { if (!process.HasExited) process.Kill(true); } catch { } }
    void ResetOutputsClicked(object sender, RoutedEventArgs e)
    {
        if (selectedProject == null || runningProcesses.ContainsKey(selectedProject.Id)) return;
        foreach (var name in new[] { selectedProject.Settings.Inference.TargetLeftFolder, selectedProject.Settings.Inference.TargetRightFolder, selectedProject.Settings.Inference.PredictionLeftFolder, selectedProject.Settings.Inference.PredictionRightFolder, "Intermediates", "intermediates", "Projects", "HRTF", "Results Inference.csv", "Project Settings.yaml" })
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

    void AppendLog(string? text, Guid? projectId = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var compact = string.Join(Environment.NewLine, text.Replace("\r\n", "\n").Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0 && !Path.IsPathRooted(x) && !x.Contains("Mem:") && !x.StartsWith("Fra:") && !x.StartsWith("Blender", StringComparison.OrdinalIgnoreCase)));
        if (compact.Length == 0) return;
        var id = projectId ?? selectedProject?.Id;
        if (id == null) return;
        void Append()
        {
            var current = projectLogs.TryGetValue(id.Value, out var value) ? value : "";
            projectLogs[id.Value] = current.Length == 0 ? compact : current + Environment.NewLine + compact;
            if (selectedProject?.Id == id) logText.Text = projectLogs[id.Value];
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
            stageStatus[i].Text = skipped ? "Skipped" : running ? "Running…" : failed ? "Failed" : StageIsComplete(stage, selectedProject) ? "Done" : "Ready";
            stageStatus[i].Foreground = new SolidColorBrush(skipped ? ColorHelper.FromArgb(255, 130, 130, 130) : running ? Colors.DarkOrange : failed ? Colors.Firebrick : StageIsComplete(stage, selectedProject) ? Colors.ForestGreen : Colors.Gray);
            stageButtons[i].Content = running ? "Stop" : "Run";
            stageButtons[i].IsEnabled = placementSide == null && (running || StageCanRun(stage, selectedProject));
        }
        var pending = AutomaticStages(selectedProject).Where(x => !StageIsComplete(x, selectedProject)).ToList();
        runAllButton.IsEnabled = placementSide == null && pending.Count > 0 && StageCanRun(pending[0], selectedProject);
        RefreshProjectList();
        RefreshNumCalcStatus();
    }

    bool InferenceIsAutomatic(ProjectRecord project) => project.Settings.Inference.UsePredictionsForPreprocessing && !string.IsNullOrWhiteSpace(project.LeftEar) && !string.IsNullOrWhiteSpace(project.RightEar);
    bool PreprocessingBlocked(ProjectRecord project) => InferenceIsAutomatic(project) && !StageIsComplete(Stage.Inference, project);
    bool StageCanRun(Stage stage, ProjectRecord? project)
    {
        if (project == null || runningProcesses.ContainsKey(project.Id) || string.IsNullOrWhiteSpace(project.SaveLocation) || (string.IsNullOrWhiteSpace(project.LeftEar) && string.IsNullOrWhiteSpace(project.RightEar))) return false;
        if ((!string.IsNullOrWhiteSpace(project.LeftEar) && !File.Exists(project.LeftEar)) || (!string.IsNullOrWhiteSpace(project.RightEar) && !File.Exists(project.RightEar))) return false;
        if (stage == Stage.Inference) return InferenceIsAutomatic(project) && File.Exists(project.Settings.Inference.ModelConfig) && File.Exists(project.Settings.Inference.ModelCheckpoint);
        if (stage == Stage.Preprocessing) return !PreprocessingBlocked(project) && File.Exists(environment.MeshGradingExecutable) && Directory.Exists(Path.Combine(environment.ExternalDir, "src", "Mesh2HRTF", "mesh2hrtf"));
        if (stage == Stage.Numcalc) return StageIsComplete(Stage.Preprocessing, project) && File.Exists(environment.NumCalcExecutable);
        return stage == Stage.Postprocessing && StageIsComplete(Stage.Numcalc, project);
    }

    Stage[] AutomaticStages(ProjectRecord project) => InferenceIsAutomatic(project) ? Stage.GetValues() : [Stage.Preprocessing, Stage.Numcalc, Stage.Postprocessing];
    bool StageIsComplete(Stage stage, ProjectRecord project)
    {
        var output = project.SaveLocation;
        if (stage == Stage.Inference) return !project.Settings.Inference.UsePredictionsForPreprocessing || (InferenceIsAutomatic(project) && ContainsMesh(Path.Combine(output, project.Settings.Inference.PredictionLeftFolder)) && ContainsMesh(Path.Combine(output, project.Settings.Inference.PredictionRightFolder)));
        if (stage == Stage.Preprocessing) return (string.IsNullOrWhiteSpace(project.LeftEar) || (File.Exists(Path.Combine(output, "Projects", "Left", "parameters.json")) && File.Exists(Path.Combine(output, "Intermediates", "Left", "graded_head.ply")))) && (string.IsNullOrWhiteSpace(project.RightEar) || (File.Exists(Path.Combine(output, "Projects", "Right", "parameters.json")) && File.Exists(Path.Combine(output, "Intermediates", "Right", "graded_head.ply"))));
        if (stage == Stage.Numcalc) return (string.IsNullOrWhiteSpace(project.LeftEar) || ContainsOutput2HRTF(Path.Combine(output, "Projects", "Left", "Output2HRTF"))) && (string.IsNullOrWhiteSpace(project.RightEar) || ContainsOutput2HRTF(Path.Combine(output, "Projects", "Right", "Output2HRTF")));
        return stage == Stage.Postprocessing && Directory.Exists(Path.Combine(output, "HRTF")) && Directory.GetFiles(Path.Combine(output, "HRTF"), "*.sofa").Any();
    }

    string NextStageSummary(ProjectRecord project) { if (runningStages.TryGetValue(project.Id, out var active)) return active.Title + ": Running"; var next = AutomaticStages(project).FirstOrDefault(x => !StageIsComplete(x, project)); return next == null ? "Complete" : next.Title + ": Ready"; }
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
        var dialog = new ContentDialog { Title = "About Pinna2HRTF", Content = new StackPanel { Spacing = 8, Children = { new TextBlock { Text = "Pinna2HRTF", FontSize = 24, FontWeight = FontWeights.Bold }, new TextBlock { Text = "Version " + version }, new TextBlock { Text = "A desktop pipeline for ear-mesh preprocessing, Mesh2PPM inference, Mesh2HRTF simulation, and SOFA export.", TextWrapping = TextWrapping.Wrap } } }, CloseButtonText = "Close", XamlRoot = Root.XamlRoot };
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
        var background = dark ? ColorHelper.FromArgb(255, 32, 32, 32) : Colors.White;
        Root.Background = new SolidColorBrush(background);
        if (contentGrid != null) contentGrid.Background = new SolidColorBrush(background);
        if (meshViewerBackground != null) { meshViewerBackground.Background = new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 31, 36, 38) : ColorHelper.FromArgb(255, 237, 243, 242)); meshViewport.BackgroundColor = new Color4(dark ? 0.12f : 0.93f, dark ? 0.14f : 0.95f, dark ? 0.15f : 0.95f, 1); }
    }

    void AppWindowClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (closingConfirmed || runningProcesses.Count == 0) { statusTimer.Stop(); Persist(); SaveUiState(); return; }
        args.Cancel = true;
        _ = ConfirmQuitAsync(sender);
    }

    async Task ConfirmQuitAsync(Microsoft.UI.Windowing.AppWindow appWindow)
    {
        var dialog = new ContentDialog { Title = "Quit Pinna2HRTF?", Content = "A pipeline task is still running. Quitting will stop it and may leave incomplete outputs.", PrimaryButtonText = "Quit", CloseButtonText = "Keep Running", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        closingConfirmed = true;
        foreach (var process in runningProcesses.Values.ToList()) TryTerminate(process);
        appWindow.Close();
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
    void LoadUiState() { if (!File.Exists(uiStatePath)) return; try { var state = JsonSerializer.Deserialize<WindowUiState>(File.ReadAllText(uiStatePath), jsonOptions); if (state != null) { projectsExpandedWidth = state.ProjectsWidth; liveLogExpandedHeight = state.LiveLogHeight; } } catch { } }
    void SaveUiState() { if (!string.IsNullOrWhiteSpace(uiStatePath)) File.WriteAllText(uiStatePath, JsonSerializer.Serialize(new WindowUiState { ProjectsWidth = projectsExpandedWidth, LiveLogHeight = liveLogExpandedHeight }, jsonOptions)); }
    string FindPackageRoot() { var current = new DirectoryInfo(AppContext.BaseDirectory); while (current != null) { if (File.Exists(Path.Combine(current.FullName, "pyproject.toml")) && Directory.Exists(Path.Combine(current.FullName, "HRTFCalculation"))) return current.FullName; current = current.Parent; } return AppContext.BaseDirectory; }
    EnvironmentConfig DefaultEnvironment() { var external = Path.Combine(packageRoot, "External"); var bin = Path.Combine(external, "bin"); return new EnvironmentConfig { UvExecutable = Path.Combine(bin, "uv.exe"), NumCalcExecutable = Path.Combine(bin, "NumCalc.exe"), MeshGradingExecutable = Path.Combine(bin, "hrtf_mesh_grading.exe"), ExternalDir = external }; }
    ProjectRecord Clone(ProjectRecord project) => JsonSerializer.Deserialize<ProjectRecord>(JsonSerializer.Serialize(project, jsonOptions), jsonOptions) ?? project;

    string? PreprocessingMesh(ProjectRecord project, string side)
    {
        if (project.Settings.Inference.UsePredictionsForPreprocessing)
        {
            var predicted = Path.Combine(project.SaveLocation, side == "left" ? project.Settings.Inference.PredictionLeftFolder : project.Settings.Inference.PredictionRightFolder);
            var file = Directory.Exists(predicted) ? Directory.EnumerateFiles(predicted).Where(IsMesh).OrderBy(x => x).FirstOrDefault() : null;
            if (file != null) return file;
        }
        var raw = side == "left" ? project.LeftEar : project.RightEar;
        return !string.IsNullOrWhiteSpace(raw) && File.Exists(raw) ? raw : null;
    }

    string SideForPath(string path) => IsLeftMesh(path) ? "left" : IsRightMesh(path) ? "right" : "";
    bool IsLeftMesh(string path) => path.Contains("left", StringComparison.OrdinalIgnoreCase);
    bool IsRightMesh(string path) => path.Contains("right", StringComparison.OrdinalIgnoreCase);
    ManualMicrophonePosition? ManualPosition(ProjectRecord project, string side) => side == "left" ? project.Settings.Preprocessing.SourcePositionInputLeft : project.Settings.Preprocessing.SourcePositionInputRight;
    bool ValidManualPosition(ProjectRecord project, string side) { var position = ManualPosition(project, side); var mesh = PreprocessingMesh(project, side); return position != null && !string.IsNullOrWhiteSpace(position.MeshPath) && mesh != null && string.Equals(Path.GetFullPath(position.MeshPath), Path.GetFullPath(mesh), StringComparison.OrdinalIgnoreCase) && position.MeshIdentity == MeshIdentity(mesh); }
    void InvalidateManualPositions(ProjectRecord project) { if (!ValidManualPosition(project, "left")) project.Settings.Preprocessing.SourcePositionInputLeft = null; if (!ValidManualPosition(project, "right")) project.Settings.Preprocessing.SourcePositionInputRight = null; }
    void RebaseManualPositionIfNeeded(ProjectRecord project) { InvalidateManualPositions(project); }
    string MeshIdentity(string path) { try { var file = new FileInfo(path); return Path.GetFullPath(path).ToLowerInvariant() + ":" + file.Length + ":" + file.LastWriteTimeUtc.Ticks; } catch { return ""; } }

    System.Numerics.Vector3? MicrophonePosition(string meshPath)
    {
        if (selectedProject == null) return null;
        var side = SideForPath(meshPath);
        if (side.Length == 0) return null;
        if (placementSide == side && pendingMicrophonePosition != null) return new System.Numerics.Vector3((float)pendingMicrophonePosition.X, (float)pendingMicrophonePosition.Y, (float)pendingMicrophonePosition.Z);
        if (ValidManualPosition(selectedProject, side)) { var p = ManualPosition(selectedProject, side)!; return new System.Numerics.Vector3((float)p.X, (float)p.Y, (float)p.Z); }
        var parameters = Path.Combine(selectedProject.SaveLocation, "Projects", CultureInfo.InvariantCulture.TextInfo.ToTitleCase(side), "parameters.json");
        try { using var document = JsonDocument.Parse(File.ReadAllText(parameters)); var values = document.RootElement.GetProperty("sourceCenter").EnumerateArray().Select(x => (float)x.GetDouble() * 1000).ToArray(); return values.Length == 3 ? new System.Numerics.Vector3(values[0], values[1], values[2]) : null; } catch { return null; }
    }
}

record Artifact(string Title, string Path)
{
    public bool Exists => File.Exists(Path);
    public bool IsMesh => new[] { ".stl", ".ply" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
    public bool IsImage => new[] { ".jpg", ".jpeg", ".png", ".bmp", ".gif" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
    public bool IsText => new[] { ".txt", ".csv", ".json", ".yaml", ".yml", ".log", ".out" }.Contains(System.IO.Path.GetExtension(Path), StringComparer.OrdinalIgnoreCase);
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
class ProjectRegistry { public List<ProjectRecord> Projects { get; set; } = []; public Guid? SelectedProjectID { get; set; } public EnvironmentConfig Environment { get; set; } = new(); }
class WindowUiState { public double ProjectsWidth { get; set; } = 280; public double LiveLogHeight { get; set; } = 170; }
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
    public static MeshData Load(string path)
    {
        var mesh = new MeshGeometry3D();
        if (Path.GetExtension(path).Equals(".ply", StringComparison.OrdinalIgnoreCase)) LoadPly(path, mesh); else LoadStl(path, mesh);
        if (mesh.Positions.Count == 0) throw new InvalidDataException("Mesh contains no vertices.");
        var min = new System.Numerics.Vector3(mesh.Positions.Min(x => x.X), mesh.Positions.Min(x => x.Y), mesh.Positions.Min(x => x.Z));
        var max = new System.Numerics.Vector3(mesh.Positions.Max(x => x.X), mesh.Positions.Max(x => x.Y), mesh.Positions.Max(x => x.Z));
        var center = (min + max) / 2;
        var maximum = Math.Max(max.X - min.X, Math.Max(max.Y - min.Y, max.Z - min.Z));
        var scale = 180 / Math.Max(maximum, 1);
        for (var i = 0; i < mesh.Positions.Count; i++) mesh.Positions[i] = (mesh.Positions[i] - center) * (float)scale;
        mesh.UpdateBounds();
        return new MeshData(path, mesh, center, scale, maximum * scale);
    }

    static void LoadStl(string path, MeshGeometry3D mesh)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length >= 84 && 84L + BitConverter.ToUInt32(bytes, 80) * 50L == bytes.Length)
        {
            var offset = 84;
            var count = BitConverter.ToUInt32(bytes, 80);
            for (var i = 0; i < count; i++) { offset += 12; var start = mesh.Positions.Count; for (var v = 0; v < 3; v++) { mesh.Positions.Add(new System.Numerics.Vector3(BitConverter.ToSingle(bytes, offset), BitConverter.ToSingle(bytes, offset + 4), BitConverter.ToSingle(bytes, offset + 8))); offset += 12; } mesh.TriangleIndices.Add(start); mesh.TriangleIndices.Add(start + 1); mesh.TriangleIndices.Add(start + 2); offset += 2; }
            return;
        }
        var vertices = new List<System.Numerics.Vector3>();
        foreach (var line in File.ReadLines(path)) { var p = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries); if (p.Length == 4 && p[0].Equals("vertex", StringComparison.OrdinalIgnoreCase)) { vertices.Add(new System.Numerics.Vector3(Parse(p[1]), Parse(p[2]), Parse(p[3]))); if (vertices.Count == 3) { var start = mesh.Positions.Count; foreach (var vertex in vertices) mesh.Positions.Add(vertex); mesh.TriangleIndices.Add(start); mesh.TriangleIndices.Add(start + 1); mesh.TriangleIndices.Add(start + 2); vertices.Clear(); } } }
    }

    static void LoadPly(string path, MeshGeometry3D mesh)
    {
        using var reader = new StreamReader(path);
        var vertices = 0; var faces = 0; string? line;
        while ((line = reader.ReadLine()) != null && line != "end_header") { var p = line.Split(' ', StringSplitOptions.RemoveEmptyEntries); if (p.Length == 3 && p[0] == "element" && p[1] == "vertex") vertices = int.Parse(p[2], CultureInfo.InvariantCulture); if (p.Length == 3 && p[0] == "element" && p[1] == "face") faces = int.Parse(p[2], CultureInfo.InvariantCulture); }
        for (var i = 0; i < vertices; i++) { var p = (reader.ReadLine() ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries); mesh.Positions.Add(new System.Numerics.Vector3(Parse(p[0]), Parse(p[1]), Parse(p[2]))); }
        for (var i = 0; i < faces; i++) { var p = (reader.ReadLine() ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => int.Parse(x, CultureInfo.InvariantCulture)).ToArray(); if (p.Length < 4) continue; for (var j = 2; j < p[0]; j++) { mesh.TriangleIndices.Add(p[1]); mesh.TriangleIndices.Add(p[j]); mesh.TriangleIndices.Add(p[j + 1]); } }
    }

    public static MeshGeometry3D CreateSphere(System.Numerics.Vector3 center, double radius)
    {
        var mesh = new MeshGeometry3D(); const int slices = 16; const int stacks = 8;
        for (var stack = 0; stack <= stacks; stack++) { var phi = Math.PI * stack / stacks; for (var slice = 0; slice <= slices; slice++) { var theta = 2 * Math.PI * slice / slices; mesh.Positions.Add(center + new System.Numerics.Vector3((float)(radius * Math.Sin(phi) * Math.Cos(theta)), (float)(radius * Math.Sin(phi) * Math.Sin(theta)), (float)(radius * Math.Cos(phi)))); } }
        for (var stack = 0; stack < stacks; stack++) for (var slice = 0; slice < slices; slice++) { var first = stack * (slices + 1) + slice; var second = first + slices + 1; mesh.TriangleIndices.Add(first); mesh.TriangleIndices.Add(second); mesh.TriangleIndices.Add(first + 1); mesh.TriangleIndices.Add(first + 1); mesh.TriangleIndices.Add(second); mesh.TriangleIndices.Add(second + 1); }
        mesh.UpdateBounds(); return mesh;
    }
    static float Parse(string value) => float.Parse(value, CultureInfo.InvariantCulture);
}
