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
    internal const bool MacReviewStorage = true;
    internal const string ReviewVersion = "2.0 beta";
#else
    internal static bool MacLayout => true;
    internal const bool MacReviewStorage = false;
    internal const string ReviewVersion = "2.0 beta";
#endif
    Grid? macSettingsDivider;
    TextBlock? macProjectTitle;
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
        SyncPaneMenu();
        if (projectsPaneBorder != null) projectsPaneBorder.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        if (projectsColumn != null) { projectsColumn.MinWidth = collapsed ? 0 : 180; projectsColumn.MaxWidth = 320; projectsColumn.Width = new GridLength(collapsed ? 0 : Math.Clamp(projectsExpandedWidth, 180, 320)); }
        if (projectsSplitterColumn != null) projectsSplitterColumn.Width = new GridLength(collapsed ? 0 : 6);
        if (projectsSplitter != null) projectsSplitter.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
    }

    void ToggleMacInspector()
    {
        if (settingsColumn == null || contentGrid == null || settingsPaneBorder == null) return;
        macInspectorVisible = !macInspectorVisible;
        SyncPaneMenu();
        settingsPaneBorder.Visibility = macInspectorVisible ? Visibility.Visible : Visibility.Collapsed;
        settingsColumn.MinWidth = macInspectorVisible ? 300 : 0;
        settingsColumn.Width = new GridLength(macInspectorVisible ? settingsExpandedWidth : 0);
        var divider = contentGrid.ColumnDefinitions[3];
        divider.MinWidth = 0;
        divider.Width = new GridLength(macInspectorVisible ? (MacLayout ? 6 : 12) : 0);
        if (macSettingsDivider != null) macSettingsDivider.Visibility = macInspectorVisible ? Visibility.Visible : Visibility.Collapsed;
        workflowCompact.Visibility = macInspectorVisible ? Visibility.Collapsed : Visibility.Visible;
        RefreshMacPresentation();
    }

    void RefreshMacPresentation(ArtifactInspection? inspection = null)
    {
        if (!MacLayout) return;
        if (macProjectTitle != null) macProjectTitle.Text = selectedProject?.Name ?? "Pinna2HRTF";
        if (macLogToggle != null) macLogToggle.IsChecked = !logCollapsed;
        if (macInspectorToggle != null) macInspectorToggle.IsChecked = macInspectorVisible;
        if (macLogToggle != null) ToolTipService.SetToolTip(macLogToggle, logCollapsed ? "Show Live Log (Ctrl+L)" : "Hide Live Log (Ctrl+L)");
        if (macInspectorToggle != null) ToolTipService.SetToolTip(macInspectorToggle, macInspectorVisible ? "Hide Workflow (Ctrl+Shift+I)" : "Show Workflow (Ctrl+Shift+I)");
    }
}
