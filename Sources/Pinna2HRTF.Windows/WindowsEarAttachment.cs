using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    readonly ComboBox canalClosurePicker = new(), earCutPicker = new();
    readonly TextBox earCutClearanceBox = new(), projectedCutMarginBox = new(), seamPassesBox = new(), seamStrengthBox = new();
    FrameworkElement? earCutClearanceRow, projectedCutMarginRow;
    static readonly (string Value, string Title)[] CanalClosureChoices = [("legacy", "Direct"), ("interpolated", "Interpolated")];
    static readonly (string Value, string Title)[] EarCutChoices = [("ellipse", "Ellipse"), ("projected_footprint", "Bounding box"), ("exact", "Ear outline")];

    static string SelectedChoice(ComboBox box, (string Value, string Title)[] choices, string key) =>
        box.SelectedIndex >= 0 && box.SelectedIndex < choices.Length ? choices[box.SelectedIndex].Value : SettingsCatalog.Text(key);

    static int ChoiceIndex((string Value, string Title)[] choices, string? value) => Math.Max(0, Array.FindIndex(choices, choice => choice.Value == value));

    string SelectedCanalClosure => SelectedChoice(canalClosurePicker, CanalClosureChoices, "preprocessing.ear_canal_closer_mode");
    string SelectedEarCut => SelectedChoice(earCutPicker, EarCutChoices, "preprocessing.ear_cut_mode");

    void AddAttachmentTextSettings(Dictionary<string, TextSetting> settings)
    {
        settings["attachment.clearance"] = new(earCutClearanceBox, p => p.Settings.Preprocessing.EarCutClearanceScale,
            (p, v) => p.Settings.Preprocessing.EarCutClearanceScale = v.Trim(), SettingsCatalog.Text("preprocessing.ear_cut_clearance_scale"));
        settings["attachment.margin"] = new(projectedCutMarginBox, p => p.Settings.Preprocessing.ProjectedCutMargin,
            (p, v) => p.Settings.Preprocessing.ProjectedCutMargin = v.Trim(), SettingsCatalog.Text("preprocessing.projected_cut_margin"));
        settings["attachment.smoothing_passes"] = new(seamPassesBox, p => p.Settings.Preprocessing.SeamSmoothingIterations,
            (p, v) => p.Settings.Preprocessing.SeamSmoothingIterations = v.Trim(), SettingsCatalog.Text("preprocessing.seam_smoothing_iterations"));
        settings["attachment.smoothing_strength"] = new(seamStrengthBox, p => p.Settings.Preprocessing.SeamSmoothingFactor,
            (p, v) => p.Settings.Preprocessing.SeamSmoothingFactor = v.Trim(), SettingsCatalog.Text("preprocessing.seam_smoothing_factor"));
    }

    FrameworkElement CanalClosurePanel()
    {
        foreach (var (value, title) in CanalClosureChoices) canalClosurePicker.Items.Add(new ComboBoxItem { Content = title, Tag = value });
        canalClosurePicker.SelectionChanged += async (_, _) => { if (!loading) await HandleSettingChangeAsync("ear.canal_closure"); };
        return AddSettingPanel("Canal closure", "ear.canal_closure", canalClosurePicker);
    }

    StackPanel EarAttachmentPanel()
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(WorkflowGroupHeading("Ear attachment"));
        foreach (var (value, title) in EarCutChoices) earCutPicker.Items.Add(new ComboBoxItem { Content = title, Tag = value });
        panel.Children.Add(AddSettingPanel("Head opening", "attachment.cut_mode", earCutPicker));
        earCutClearanceRow = AddSettingPanel("Opening clearance", "attachment.clearance", earCutClearanceBox);
        projectedCutMarginRow = AddSettingPanel("Opening margin (mm)", "attachment.margin", projectedCutMarginBox);
        panel.Children.Add(earCutClearanceRow);
        panel.Children.Add(projectedCutMarginRow);
        panel.Children.Add(AddSettingPanel("Smoothing passes", "attachment.smoothing_passes", seamPassesBox));
        panel.Children.Add(AddSettingPanel("Smoothing strength", "attachment.smoothing_strength", seamStrengthBox));
        earCutPicker.SelectionChanged += async (_, _) =>
        {
            UpdateEarAttachmentControls();
            if (!loading) await HandleSettingChangeAsync("attachment.cut_mode");
        };
        return panel;
    }

    void UpdateEarAttachmentControls()
    {
        var mode = SelectedEarCut;
        if (earCutClearanceRow != null) earCutClearanceRow.Visibility = mode == "ellipse" ? Visibility.Visible : Visibility.Collapsed;
        if (projectedCutMarginRow != null) projectedCutMarginRow.Visibility = mode == "projected_footprint" ? Visibility.Visible : Visibility.Collapsed;
    }

    void LoadEarSettings(ProjectRecord? project)
    {
        canalClosurePicker.SelectedIndex = ChoiceIndex(CanalClosureChoices, project?.Settings.Preprocessing.EarCanalCloserMode ?? SettingsCatalog.Text("preprocessing.ear_canal_closer_mode"));
        earCutPicker.SelectedIndex = ChoiceIndex(EarCutChoices, project?.Settings.Preprocessing.EarCutMode ?? SettingsCatalog.Text("preprocessing.ear_cut_mode"));
        UpdateEarAttachmentControls();
    }
}
