using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Pinna2HRTF.Windows;

// Presentation-only build flavor. Controls, project models and pipeline services
// are shared with the Windows review; the default build keeps its original layout.
public partial class MainWindow
{
#if PINNA_MAC_LAYOUT
    internal static bool MacLayout => true;
    internal const string ReviewVersion = "2.0.0-review-main-macimitation";
#else
    internal static bool MacLayout => false;
    internal const string ReviewVersion = "2.0.0-review-main";
#endif
    Grid? macSettingsDivider;
    TextBlock? macProjectTitle;
<<<<<<< Updated upstream
=======
    readonly List<Grid> macStageRows = [];
    readonly List<Action> macPathUpdates = [];
    readonly List<(string Side, TextBlock Status)> macFitStatuses = [];
>>>>>>> Stashed changes
    ToggleButton? macLogToggle, macInspectorToggle;
    bool macInspectorVisible = true, macSidebarReady;

    Button MacTool(string glyph, string name, RoutedEventHandler action)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 16 }, Width = 34, Height = 32,
            Padding = new Thickness(6), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
        button.Click += action; AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name); return button;
    }

    ToggleButton MacToggleTool(string glyph, string name, RoutedEventHandler action)
    {
        var button = new ToggleButton { Content = new FontIcon { Glyph = glyph, FontSize = 16 }, Width = 34, Height = 32,
            Padding = new Thickness(6), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
        button.Click += action; AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name); return button;
    }

    void UseNeutralCheckedState(ToggleButton button)
    {
        // Keep native checked semantics, using the inactive hover palette.
        // Resolve aliases within each theme rather than capturing a theme's brush.
        const string aliases = """
            <StaticResource x:Key="ToggleButtonBackgroundChecked" ResourceKey="ToggleButtonBackgroundPointerOver" />
            <StaticResource x:Key="ToggleButtonBackgroundCheckedPointerOver" ResourceKey="ToggleButtonBackgroundPointerOver" />
            <StaticResource x:Key="ToggleButtonBackgroundCheckedPressed" ResourceKey="ToggleButtonBackgroundPressed" />
            <StaticResource x:Key="ToggleButtonForegroundChecked" ResourceKey="ToggleButtonForegroundPointerOver" />
            <StaticResource x:Key="ToggleButtonForegroundCheckedPointerOver" ResourceKey="ToggleButtonForegroundPointerOver" />
            <StaticResource x:Key="ToggleButtonForegroundCheckedPressed" ResourceKey="ToggleButtonForegroundPressed" />
            """;
        var themes = string.Concat(new[] { "Default", "Light", "HighContrast" }.Select(theme => $"<ResourceDictionary x:Key=\"{theme}\">{aliases}</ResourceDictionary>"));
        button.Resources.MergedDictionaries.Add((ResourceDictionary)Microsoft.UI.Xaml.Markup.XamlReader.Load($"""
            <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
              <ResourceDictionary.ThemeDictionaries>{themes}</ResourceDictionary.ThemeDictionaries>
            </ResourceDictionary>
            """));
    }

    void ApplyMacWorkspace()
    {
        if (contentGrid == null || previewPanelBorder?.Child is not Grid previewGrid || settingsPaneBorder == null) return;
        Root.RowDefinitions[0].Height = new GridLength(54);
        Root.Children.RemoveAt(0);
        var toolbar = new Grid { Padding = new Thickness(10, 4, 0, 4), ColumnSpacing = 10, Background = secondarySurfaceBrush };
        toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star), MinWidth = 60 });
        toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var navigation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        navigation.Children.Add(MacTool("\uE700", "Toggle project sidebar", (_, _) => SetProjectsCollapsed(!projectsCollapsed, true)));
        var menu = BuildMenu(); menu.Height = 36; navigation.Children.Add(menu); toolbar.Children.Add(navigation);
        macProjectTitle = new TextBlock { Text = "Pinna2HRTF", FontSize = 14, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        var dragRegion = new Grid(); dragRegion.Children.Add(macProjectTitle); Grid.SetColumn(dragRegion, 1); toolbar.Children.Add(dragRegion);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        workflowCompact.Click += (_, _) => PerformWorkflowAction();
        tools.Children.Add(workflowCompact);
        macLogToggle = MacToggleTool("\uE756", "Toggle Live Log", (_, _) => SetLogCollapsed(!logCollapsed, true)); tools.Children.Add(macLogToggle);
        macInspectorToggle = MacToggleTool("\uE90F", "Toggle Workflow", (_, _) => ToggleMacInspector()); tools.Children.Add(macInspectorToggle);
        UseNeutralCheckedState(macLogToggle); UseNeutralCheckedState(macInspectorToggle);
        Grid.SetColumn(tools, 2); toolbar.Children.Add(tools); Root.Children.Insert(0, toolbar);
        windowChrome?.Dispose(); windowChrome = new WindowChrome(this, Root, toolbar, dragRegion);


        previewPanelBorder.CornerRadius = new CornerRadius(0); previewPanelBorder.BorderThickness = new Thickness(0);
        if (logPanelBorder != null) { logPanelBorder.CornerRadius = new CornerRadius(0); logPanelBorder.Margin = new Thickness(0); }
        settingsPaneBorder.CornerRadius = new CornerRadius(0);
        macSettingsDivider = contentGrid.Children.OfType<Grid>().FirstOrDefault(child => Grid.GetColumn(child) == 3);
        contentGrid.ColumnDefinitions[2].MinWidth = 260;
        contentGrid.ColumnDefinitions[3].MinWidth = 0; contentGrid.ColumnDefinitions[3].MaxWidth = 6; contentGrid.ColumnDefinitions[3].Width = new GridLength(6);
        if (projectsPaneBorder?.Child is Grid sidebar && projectsActions != null)
        {
            // Keep all five commands in the header, with a second header line
            // when the sidebar is too narrow for the heading and commands.
            projectsActions.Spacing = 4;
            void ArrangeProjectHeader()
            {
                if (projectsHeader == null) return;
                var narrow = projectsHeader.ActualWidth < 226;
                Grid.SetRow(projectsActions, narrow ? 1 : 0);
                Grid.SetColumn(projectsActions, narrow ? 0 : 1);
                Grid.SetColumnSpan(projectsActions, narrow ? 3 : 1);
                projectsActions.HorizontalAlignment = HorizontalAlignment.Left;
                projectsActions.Margin = new Thickness(0, 0, 0, narrow ? 8 : 0);
            }
            if (projectsHeader != null) projectsHeader.SizeChanged += (_, _) => ArrangeProjectHeader();
            ArrangeProjectHeader();
            if (projectsToggle != null) projectsToggle.Visibility = Visibility.Collapsed;
            projectsPaneBorder.CornerRadius = new CornerRadius(0);
            if (projectsHeaderText != null) { projectsHeaderText.FontSize = 13; projectsHeaderText.FontWeight = FontWeights.SemiBold; }
        }
        macSidebarReady = true; SetMacSidebar(projectsCollapsed);
        SetLogCollapsed(logCollapsed, false);
        AddMacShortcut(VirtualKey.L, VirtualKeyModifiers.Control, () => SetLogCollapsed(!logCollapsed, true));
        AddMacShortcut(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, ToggleMacInspector);
        RefreshMacPresentation();
    }

    void AddMacShortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, args) => { action(); args.Handled = true; }; Root.KeyboardAccelerators.Add(accelerator);
    }

    void SetMacSidebar(bool collapsed)
    {
        projectsCollapsed = collapsed;
        if (projectsPaneBorder != null) projectsPaneBorder.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (projectsColumn != null) { projectsColumn.MinWidth = collapsed ? 0 : 180; projectsColumn.MaxWidth = 320; projectsColumn.Width = new GridLength(collapsed ? 0 : Math.Clamp(projectsExpandedWidth, 180, 320)); }
        if (projectsSplitterColumn != null) projectsSplitterColumn.Width = new GridLength(collapsed ? 0 : 6);
        if (projectsSplitter != null) projectsSplitter.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
    }

    void ToggleMacInspector()
    {
        if (settingsColumn == null || contentGrid == null || settingsPaneBorder == null) return;
        macInspectorVisible = !macInspectorVisible;
        settingsPaneBorder.Visibility = macInspectorVisible ? Visibility.Visible : Visibility.Collapsed;
        settingsColumn.MinWidth = macInspectorVisible ? 300 : 0;
        settingsColumn.Width = new GridLength(macInspectorVisible ? settingsExpandedWidth : 0);
        contentGrid.ColumnDefinitions[3].Width = new GridLength(macInspectorVisible ? 6 : 0);
        if (macSettingsDivider != null) macSettingsDivider.Visibility = macInspectorVisible ? Visibility.Visible : Visibility.Collapsed;
        workflowCompact.Visibility = macInspectorVisible ? Visibility.Collapsed : Visibility.Visible;
        RefreshMacPresentation();
    }

<<<<<<< Updated upstream
=======
    void ArrangeMacInspector(StackPanel settings, Grid outer, ScrollViewer scroll, Border stages)
    {
        var sections = settings.Children.OfType<Expander>().ToDictionary(e => (string)e.Header);
        FrameworkElement Row(Control control) => settings.Children.OfType<Grid>().Single(row => row.Children.Contains(control));
        var name = Row(projectNameBox); var left = Row(leftEarBox); var right = Row(rightEarBox); var save = Row(saveLocationBox); var inference = Row(usePredictionsBox);
        var evaluation = ((StackPanel)sections["Mesh2HRTF"].Content).Children.OfType<Grid>().Single(row => row.Children.Contains(evaluationGridBox));
        var scan = (StackPanel)sections["Optional scan preparation"].Content; var scanChildren = scan.Children.Cast<FrameworkElement>().ToArray(); scan.Children.Clear();
        var manual = (StackPanel)sections["Manual PPM Fit"].Content; var manualChildren = manual.Children.Cast<FrameworkElement>().ToArray(); manual.Children.Clear();
        var sofa = (StackPanel)sections["SOFA destination"].Content; var sofaRow = (FrameworkElement)sofa.Children[0]; sofa.Children.Clear();
        settings.Children.Clear(); settings.Margin = new Thickness(14, 0, 14, 14);
        macEarInputs = new StackPanel { Spacing = 8 }; Unparent(left); Unparent(right); macEarInputs.Children.Add(left); macEarInputs.Children.Add(right);
        macEarInputs.Children.Add(new TextBlock { Text = "Choose at least one ear mesh.", FontSize = 11, Foreground = mutedTextBrush });
        macScanInputs = new StackPanel { Spacing = 6 };
        foreach (var item in scanChildren.Skip(1).Take(4)) { Unparent(item); macScanInputs.Children.Add(item); }
        MacSection(settings, "Inputs", new[] { name, scanChildren[0], macEarInputs, macScanInputs, save, inference });
        var manualRows = new List<FrameworkElement> { new TextBlock { Text = "Fit a parametric model to either ear.", FontSize = 11, Foreground = mutedTextBrush } };
        foreach (var (side, button) in new[] { ("left", (Button)manualChildren[0]), ("right", (Button)manualChildren[1]) })
        {
            Unparent(button);
            button.Content = "Fit…"; button.MinWidth = 50; AutomationProperties.SetName(button, "Fit " + side + " ear");
            var row = new Grid(); row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var label = new StackPanel(); label.Children.Add(new TextBlock { Text = side == "left" ? "Left ear" : "Right ear", FontSize = 13 });
            var status = new TextBlock { Text = "Not fitted", FontSize = 11, Foreground = mutedTextBrush }; label.Children.Add(status); macFitStatuses.Add((side, status));
            row.Children.Add(label); Grid.SetColumn(button, 1); row.Children.Add(button); manualRows.Add(row);
        }
        Unparent(manualChildren[2]); manualRows.Add(manualChildren[2]); MacSection(settings, "Manual PPM Fit", manualRows);
        var processing = new[] { sections["Scan preparation settings"], sections["Mesh2PPM"], sections["Mesh2HRTF"], sections["Mesh Grading"], sections["NumCalc"] };
        processing[0].Header = "Scan Preparation";
        MacSection(settings, "Processing", processing);
        ((StackPanel)sections["Postprocessing"].Content).Children.Insert(0, sofaRow);
        MacSection(settings, "Results", new[] { sections["Postprocessing"] });
        foreach (var section in processing.Append(sections["Postprocessing"])) { section.Margin = new Thickness(0); section.MinHeight = 36; section.FontSize = 13; }
        outer.RowDefinitions.Insert(0, new() { Height = new GridLength(48) }); Grid.SetRow(scroll, 1); Grid.SetRow(stages, 2);
        outer.Children.Add(new Border { BorderBrush = borderBrush, BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(16, 0, 16, 0),
            Child = new TextBlock { Text = "Workflow", FontSize = 14, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center } });
        scanPreparationEnabledBox.Checked += (_, _) => RefreshMacPresentation(); scanPreparationEnabledBox.Unchecked += (_, _) => RefreshMacPresentation();
        // All event bindings remain on the original native controls.
        foreach (var box in settingControls.Values.OfType<TextBox>()) { box.FontSize = 12; box.Padding = new Thickness(7, 3, 7, 3); }
        MacPath((Grid)left, leftEarBox, false); MacPath((Grid)right, rightEarBox, false);
        MacPath((Grid)save, saveLocationBox, true, true); MacPath((Grid)scanChildren[1], scanPathBox, false);
        MacPath((Grid)sofaRow, sofaFolderBox, true); MacPath(evaluation, evaluationGridBox, true);
        ArrangeMacPipeline(stages);
    }

    void MacPath(Grid row, TextBox box, bool folder, bool openOnClick = false)
    {
        box.Visibility = Visibility.Collapsed;
        foreach (var browse in row.Children.OfType<Button>()) browse.Visibility = Visibility.Collapsed;
        var line = new Grid { ColumnSpacing = 6 }; line.ColumnDefinitions.Add(new()); line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var filename = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Left };
        var edit = new Button { Content = filename, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(0), MinWidth = 0, MinHeight = 26, Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
        AutomationProperties.SetName(edit, openOnClick ? "Open save location" : "Edit " + box.Tag + " path");
        async Task EditPath()
        {
            var project = selectedProject;
            var input = new TextBox { Text = box.Text, MinWidth = 300, AcceptsReturn = false };
            var dialog = new ContentDialog { Title = "Edit path", Content = input, PrimaryButtonText = "Apply", CloseButtonText = "Cancel", XamlRoot = Root.XamlRoot };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && project == selectedProject) { box.Text = input.Text; await CommitSettingInputAsync(box); }
        }
        edit.Click += async (_, _) =>
        {
            if (!openOnClick) { await EditPath(); return; }
            try
            {
                var location = ExistingPickerFolder(box.Text);
                if (location != null) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(location) { UseShellExecute = true });
            }
            catch (Exception error) { AppendLog(error.Message); }
        };
        if (openOnClick)
        {
            var menu = new MenuFlyout(); var editPath = new MenuFlyoutItem { Text = "Edit path…" };
            editPath.Click += async (_, _) => await EditPath(); menu.Items.Add(editPath); edit.ContextFlyout = menu;
        }
        var choose = new Button { Content = "Choose…", Padding = new Thickness(6, 2, 6, 2), MinHeight = 26, FontSize = 12 };
        if (openOnClick) AutomationProperties.SetName(choose, "Choose save location");
        choose.Click += async (_, _) =>
        {
            var project = selectedProject;
            var selected = folder ? await PickFolderAsync(box.Text) : await PickFileAsync(box.Text);
            if (selected != null && project == selectedProject) { box.Text = selected; await CommitSettingInputAsync(box); }
        };
        line.Children.Add(edit); Grid.SetColumn(choose, 1); line.Children.Add(choose);
        void Update()
        {
            var path = box.Text.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            filename.Text = string.IsNullOrWhiteSpace(path) ? folder ? "No location selected" : "No file selected" : Path.GetFileName(path);
            ToolTipService.SetToolTip(edit, box.Text + (openOnClick
                ? Directory.Exists(box.Text) ? "\nClick to open this folder. Right-click to edit the path." : "\nFolder not created yet; opens its existing parent. Right-click to edit the path."
                : "\nClick to edit the full path"));
            edit.IsEnabled = choose.IsEnabled = box.IsEnabled;
        }
        macPathUpdates.Add(Update);
        box.RegisterPropertyChangedCallback(TextBox.TextProperty, (_, _) => Update());
        box.RegisterPropertyChangedCallback(Control.IsEnabledProperty, (_, _) => Update()); Update();
        Grid.SetRow(line, 1); Grid.SetColumnSpan(line, 2); row.Children.Add(line);
    }

    void MacRunNextClicked(object sender, RoutedEventArgs args)
    {
        if (selectedProject != null && runs.ContainsKey(selectedProject.Id)) { StopClicked(sender, args); return; }
        RunNextClicked(sender, args);
    }

    void ArrangeMacPipeline(Border stages)
    {
        var stack = (StackPanel)stages.Child;
        stack.Children.Insert(0, new TextBlock { Text = "Pipeline", FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 2, 0, 6) });
        foreach (var (stage, index) in Stage.GetValues().Select((stage, index) => (stage, index)))
        {
            var button = stageButtons[index]; var row = stack.Children.OfType<Grid>().Single(row => row.Children.Contains(button));
            row.Children.Clear(); row.ColumnDefinitions.Clear();
            var content = new Grid { ColumnSpacing = 10 }; content.ColumnDefinitions.Add(new() { Width = new GridLength(20) }); content.ColumnDefinitions.Add(new());
            content.Children.Add(new FontIcon { Glyph = "\uE768", FontSize = 12, Foreground = mutedTextBrush });
            var text = new StackPanel { Spacing = 1 }; text.Children.Add(new TextBlock { Text = stage.Title, FontSize = 12 });
            Unparent(stageStatus[index]); stageStatus[index].Margin = new Thickness(0); stageStatus[index].FontSize = 10; text.Children.Add(stageStatus[index]); Grid.SetColumn(text, 1); content.Children.Add(text);
            button.Content = content; button.Width = double.NaN; button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Background = new SolidColorBrush(Colors.Transparent); button.BorderThickness = new Thickness(0);
            button.Padding = new Thickness(5, 3, 5, 3); button.MinHeight = 37; row.Children.Add(button); macStageRows.Add(row);
            AutomationProperties.SetName(button, "Run " + stage.Title);
        }
        runAllButton.Click -= RunAllClicked; runAllButton.Click += MacRunNextClicked;
        var statusRow = stack.Children.OfType<Grid>().Single(row => row.Children.Contains(numCalcStatusText));
        var reset = statusRow.Children.OfType<Button>().Single(); statusRow.Children.Remove(reset);
        var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 16 }, Width = 34, Height = 34, Padding = new Thickness(5), Margin = new Thickness(8, 8, 0, 0) };
        var menu = new MenuFlyout(); menu.Items.Add(MenuItem("Reset Outputs…", ResetOutputsClicked)); menu.Items.Add(MenuItem("Run All", RunAllClicked)); more.Flyout = menu;
        AutomationProperties.SetName(more, "Pipeline actions");
        var actions = new Grid(); actions.ColumnDefinitions.Add(new()); actions.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        stack.Children.Remove(runAllButton); actions.Children.Add(runAllButton); Grid.SetColumn(more, 1); actions.Children.Add(more); stack.Children.Add(actions);
        pipelineHintText.MaxLines = 2;
    }

>>>>>>> Stashed changes
    void RefreshMacPresentation(ArtifactInspection? inspection = null)
    {
        if (!MacLayout) return;
        if (macProjectTitle != null) macProjectTitle.Text = selectedProject?.Name ?? "Pinna2HRTF";
<<<<<<< Updated upstream
=======
        var scan = scanPreparationEnabledBox.IsChecked == true;
        if (macEarInputs != null) macEarInputs.Visibility = scan ? Visibility.Collapsed : Visibility.Visible;
        if (macScanInputs != null) macScanInputs.Visibility = scan ? Visibility.Visible : Visibility.Collapsed;
        if (macStageRows.Count > 0) macStageRows[0].Visibility = scan ? Visibility.Visible : Visibility.Collapsed;
        foreach (var (side, text) in macFitStatuses)
            text.Text = selectedProject?.Settings.ManualPPM.For(side) == null ? "Not fitted" : FitIsCurrent(selectedProject, side) ? "Saved fit available" : "Source changed; refit required";
        if (selectedProject != null && macStageRows.Count > 0)
        {
            var next = AutomaticStages(selectedProject).FirstOrDefault(stage => !StageIsComplete(stage, selectedProject, inspection));
            var running = runs.ContainsKey(selectedProject.Id);
            runAllButton.Content = running ? "Stop" : next != null ? "Run " + next.Title : "Complete";
            if (running) runAllButton.IsEnabled = true;
        }
>>>>>>> Stashed changes
        if (macLogToggle != null) macLogToggle.IsChecked = !logCollapsed;
        if (macInspectorToggle != null) macInspectorToggle.IsChecked = macInspectorVisible;
        if (macLogToggle != null) ToolTipService.SetToolTip(macLogToggle, logCollapsed ? "Show Live Log (Ctrl+L)" : "Hide Live Log (Ctrl+L)");
        if (macInspectorToggle != null) ToolTipService.SetToolTip(macInspectorToggle, macInspectorVisible ? "Hide Workflow (Ctrl+Shift+I)" : "Show Workflow (Ctrl+Shift+I)");
    }
}
