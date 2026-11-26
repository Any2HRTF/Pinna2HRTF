using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Pinna2HRTF.Windows;

internal sealed class AcousticTorsoSettings
{
    public string Gain { get; set; } = SettingsCatalog.Text("acoustic_torso.gain");
    public string MinSourceElevationDeg { get; set; } = SettingsCatalog.Text("acoustic_torso.min_source_elevation_deg");
    public string MaxAngularGapDeg { get; set; } = SettingsCatalog.Text("acoustic_torso.max_angular_gap_deg");
    public string Symmetry { get; set; } = SettingsCatalog.Text("acoustic_torso.symmetry");
    public string DelayModel { get; set; } = SettingsCatalog.Text("acoustic_torso.delay_model");
    public string ModelSourceDistanceM { get; set; } = SettingsCatalog.Text("acoustic_torso.model_source_distance_m");
    public string Interpolation { get; set; } = SettingsCatalog.Text("acoustic_torso.interpolation");
    public string MissingPolicy { get; set; } = SettingsCatalog.Text("acoustic_torso.missing_policy");
    public bool ApplyShadow { get; set; } = SettingsCatalog.Flag("acoustic_torso.apply_shadow");
    public bool NormalizeReflectionMix { get; set; } = SettingsCatalog.Flag("acoustic_torso.normalize_reflection_mix");
    public static readonly string[] Keys = ["gain", "min_source_elevation_deg", "max_angular_gap_deg", "symmetry", "delay_model", "model_source_distance_m", "interpolation", "missing_policy", "apply_shadow", "normalize_reflection_mix"];
    public string Get(string key) => key switch {
        "gain" => Gain,
        "min_source_elevation_deg" => MinSourceElevationDeg,
        "max_angular_gap_deg" => MaxAngularGapDeg,
        "symmetry" => Symmetry,
        "delay_model" => DelayModel,
        "model_source_distance_m" => ModelSourceDistanceM,
        "interpolation" => Interpolation,
        "missing_policy" => MissingPolicy,
        "apply_shadow" => ApplyShadow.ToString().ToLowerInvariant(),
        "normalize_reflection_mix" => NormalizeReflectionMix.ToString().ToLowerInvariant(),
        _ => throw new ArgumentOutOfRangeException(nameof(key))
    };
    public void Set(string key, string value)
    {
        switch (key)
        {
            case "gain": Gain = value; break;
            case "min_source_elevation_deg": MinSourceElevationDeg = value; break;
            case "max_angular_gap_deg": MaxAngularGapDeg = value; break;
            case "symmetry": Symmetry = value; break;
            case "delay_model": DelayModel = value; break;
            case "model_source_distance_m": ModelSourceDistanceM = value; break;
            case "interpolation": Interpolation = value; break;
            case "missing_policy": MissingPolicy = value; break;
            case "apply_shadow": ApplyShadow = bool.TryParse(value, out var flagApplyShadow) && flagApplyShadow; break;
            case "normalize_reflection_mix": NormalizeReflectionMix = bool.TryParse(value, out var flagNormalizeReflectionMix) && flagNormalizeReflectionMix; break;
        }
    }
}

internal sealed class AcousticTorsoPreferences
{
    public double Gain { get; set; } = SettingsCatalog.Decimal("acoustic_torso.gain");
    public double? MinSourceElevationDeg { get; set; } = null;
    public double MaxAngularGapDeg { get; set; } = SettingsCatalog.Decimal("acoustic_torso.max_angular_gap_deg");
    public string Symmetry { get; set; } = SettingsCatalog.Text("acoustic_torso.symmetry");
    public string DelayModel { get; set; } = SettingsCatalog.Text("acoustic_torso.delay_model");
    public double ModelSourceDistanceM { get; set; } = SettingsCatalog.Decimal("acoustic_torso.model_source_distance_m");
    public string Interpolation { get; set; } = SettingsCatalog.Text("acoustic_torso.interpolation");
    public string MissingPolicy { get; set; } = SettingsCatalog.Text("acoustic_torso.missing_policy");
    public bool ApplyShadow { get; set; } = SettingsCatalog.Flag("acoustic_torso.apply_shadow");
    public bool NormalizeReflectionMix { get; set; } = SettingsCatalog.Flag("acoustic_torso.normalize_reflection_mix");
}

public partial class MainWindow
{
    readonly Dictionary<string, TextBox> acousticNumbers = new();
    readonly Dictionary<string, ComboBox> acousticChoices = new();
    readonly Dictionary<string, CheckBox> acousticFlags = new();
    readonly TextBlock acousticGridSummary = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    StackPanel? acousticGridPanel;
    StackPanel? acousticExportPanel;
    FrameworkElement? acousticModelDistanceRow;
    bool acousticStatusPending;
    string? acousticStatusKey;

    void AddAcousticTextSettings(Dictionary<string, TextSetting> settings)
    {
        acousticNumbers["gain"] = new TextBox();
        settings["acoustic_torso.gain"] = new(acousticNumbers["gain"], p => ProjectDocument.Acoustic(p).Get("gain"), (p, value) => ProjectDocument.Acoustic(p).Set("gain", value.Trim()), SettingsCatalog.Text("acoustic_torso.gain"));
        acousticNumbers["min_source_elevation_deg"] = new TextBox();
        settings["acoustic_torso.min_source_elevation_deg"] = new(acousticNumbers["min_source_elevation_deg"], p => ProjectDocument.Acoustic(p).Get("min_source_elevation_deg"), (p, value) => ProjectDocument.Acoustic(p).Set("min_source_elevation_deg", value.Trim()), SettingsCatalog.Text("acoustic_torso.min_source_elevation_deg"));
        acousticNumbers["max_angular_gap_deg"] = new TextBox();
        settings["acoustic_torso.max_angular_gap_deg"] = new(acousticNumbers["max_angular_gap_deg"], p => ProjectDocument.Acoustic(p).Get("max_angular_gap_deg"), (p, value) => ProjectDocument.Acoustic(p).Set("max_angular_gap_deg", value.Trim()), SettingsCatalog.Text("acoustic_torso.max_angular_gap_deg"));
        acousticNumbers["model_source_distance_m"] = new TextBox();
        settings["acoustic_torso.model_source_distance_m"] = new(acousticNumbers["model_source_distance_m"], p => ProjectDocument.Acoustic(p).Get("model_source_distance_m"), (p, value) => ProjectDocument.Acoustic(p).Set("model_source_distance_m", value.Trim()), SettingsCatalog.Text("acoustic_torso.model_source_distance_m"));
        acousticNumbers["min_source_elevation_deg"].PlaceholderText = "All directions";
    }

    FrameworkElement AcousticChoice(string label, string key, (string Label, string Value)[] options)
    {
        var box = new ComboBox();
        foreach (var option in options) box.Items.Add(new ComboBoxItem { Content = option.Label, Tag = option.Value });
        acousticChoices[key] = box;
        box.SelectionChanged += async (_, _) => { if (!loading) await HandleSettingChangeAsync("acoustic_torso." + key); UpdateAcousticControls(); };
        return AddSettingPanel(label, "acoustic_torso." + key, box);
    }

    FrameworkElement AcousticFlag(string label, string key)
    {
        var box = new CheckBox();
        acousticFlags[key] = box;
        box.Click += async (_, _) => { if (!loading) await HandleSettingChangeAsync("acoustic_torso." + key); };
        return AddSettingPanel(label, "acoustic_torso." + key, box);
    }

    StackPanel AcousticGridPanel()
    {
        var panel = new StackPanel();
        var controls = new List<FrameworkElement> {
            AddSettingPanel("Maximum angular gap (°)", "acoustic_torso.max_angular_gap_deg", acousticNumbers["max_angular_gap_deg"]),
            AddSettingPanel("Minimum elevation (°)", "acoustic_torso.min_source_elevation_deg", acousticNumbers["min_source_elevation_deg"]),
            AcousticChoice("Grid symmetry", "symmetry", [("Automatic", "auto"), ("Require symmetry", "require"), ("Off", "off")])
        };
        AddExpander(panel, "Acoustic torso grid", controls);
        panel.Children.Add(acousticGridSummary);
        acousticGridPanel = panel;
        return panel;
    }

    StackPanel AcousticExportPanel()
    {
        var panel = new StackPanel();
        panel.Children.Add(AddSettingPanel("Reflection gain", "acoustic_torso.gain", acousticNumbers["gain"]));
        panel.Children.Add(AcousticFlag("Apply torso shadow", "apply_shadow"));
        panel.Children.Add(AcousticFlag("Normalize reflection mix", "normalize_reflection_mix"));
        panel.Children.Add(AcousticChoice("Delay model", "delay_model", [("Algazi", "algazi"), ("Reijniers delay", "reijniers")]));
        acousticModelDistanceRow = AddSettingPanel("Model source distance (m)", "acoustic_torso.model_source_distance_m", acousticNumbers["model_source_distance_m"]);
        panel.Children.Add(acousticModelDistanceRow);
        AddExpander(panel, "Advanced acoustic options", [
            AcousticChoice("HRIR interpolation", "interpolation", [("Peak-aligned interpolation", "aligned_idw"), ("Nearest direction", "nearest")]),
            AcousticChoice("Missing reflection coverage", "missing_policy", [("Stop export", "error"), ("Skip uncovered directions", "skip")])
        ]);
        acousticExportPanel = panel;
        return panel;
    }

    string AcousticControlValue(string key) => acousticChoices.TryGetValue(key, out var choice)
        ? (choice.SelectedItem as ComboBoxItem)?.Tag as string ?? "" : acousticFlags.TryGetValue(key, out var flag)
        ? (flag.IsChecked == true).ToString().ToLowerInvariant() : acousticNumbers[key].Text;

    void SetAcousticControl(string key, string value)
    {
        if (acousticChoices.TryGetValue(key, out var choice)) choice.SelectedItem = choice.Items.Cast<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == value);
        else if (acousticFlags.TryGetValue(key, out var flag)) flag.IsChecked = bool.TryParse(value, out var enabled) && enabled;
        else if (acousticNumbers.TryGetValue(key, out var number)) number.Text = value;
    }

    void LoadAcousticControls(ProjectRecord? project)
    {
        var settings = project == null ? new AcousticTorsoSettings() : ProjectDocument.Acoustic(project);
        foreach (var key in AcousticTorsoSettings.Keys) SetAcousticControl(key, settings.Get(key));
        UpdateAcousticControls();
    }

    void UpdateAcousticControls()
    {
        var enabled = SelectedTorsoMode == "acoustic";
        if (acousticGridPanel != null) acousticGridPanel.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        if (acousticExportPanel != null) acousticExportPanel.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        if (acousticModelDistanceRow != null) acousticModelDistanceRow.Visibility = AcousticControlValue("delay_model") == "reijniers" ? Visibility.Visible : Visibility.Collapsed;
    }

    async void RefreshAcousticGridStatus()
    {
        if (SelectedTorsoMode != "acoustic" || selectedProject is not { } project || acousticStatusPending) return;
        JsonObject config;
        try { config = ProjectDocument.Build(project, currentEnvironment); } catch { return; }
        var key = project.Id + "|" + config.ToJsonString() + "|" + StageIsComplete(Stage.Preprocessing, project);
        if (key == acousticStatusKey) return;
        acousticStatusPending = true;
        try {
            var reply = await RequestPythonAsync("project", new { action = "acoustic-torso-status", config });
            if (selectedProject?.Id != project.Id || SelectedTorsoMode != "acoustic" || ProjectDocument.Build(project, currentEnvironment).ToJsonString() != config.ToJsonString()) return;
            acousticGridSummary.Text = reply.GetProperty("message").GetString() ?? "";
            acousticStatusKey = key;
        } catch (Exception error) { if (selectedProject?.Id == project.Id) acousticGridSummary.Text = error.Message; }
        finally { acousticStatusPending = false; if (selectedProject?.Id != project.Id || ProjectDocument.Build(project, currentEnvironment).ToJsonString() != config.ToJsonString()) RefreshAcousticGridStatus(); }
    }
    void AcousticDefaultsGrid(StackPanel panel, AcousticTorsoPreferences settings)
    {
        NumberRow(panel, "Maximum angular gap (°)", "acoustic_torso.max_angular_gap_deg", () => settings.MaxAngularGapDeg, value => settings.MaxAngularGapDeg = value);
        OptionalAcousticNumber(panel, "Minimum elevation (°)", "acoustic_torso.min_source_elevation_deg", () => settings.MinSourceElevationDeg, value => settings.MinSourceElevationDeg = value);
        ChoiceRow(panel, "Grid symmetry", ["Automatic", "Require symmetry", "Off"], Array.IndexOf(new[] { "auto", "require", "off" }, settings.Symmetry), index => settings.Symmetry = new[] { "auto", "require", "off" }[index], "acoustic_torso.symmetry");
    }

    void AcousticDefaultsExport(StackPanel panel, AcousticTorsoPreferences settings)
    {
        NumberRow(panel, "Reflection gain", "acoustic_torso.gain", () => settings.Gain, value => settings.Gain = value);
        SwitchRow(panel, "Apply torso shadow", settings.ApplyShadow, value => settings.ApplyShadow = value);
        SwitchRow(panel, "Normalize reflection mix", settings.NormalizeReflectionMix, value => settings.NormalizeReflectionMix = value);
        var distance = new StackPanel { Visibility = settings.DelayModel == "reijniers" ? Visibility.Visible : Visibility.Collapsed };
        NumberRow(distance, "Model source distance (m)", "acoustic_torso.model_source_distance_m", () => settings.ModelSourceDistanceM, value => settings.ModelSourceDistanceM = value);
        ChoiceRow(panel, "Delay model", ["Algazi", "Reijniers delay"], settings.DelayModel == "reijniers" ? 1 : 0, index => {
            settings.DelayModel = index == 1 ? "reijniers" : "algazi";
            distance.Visibility = index == 1 ? Visibility.Visible : Visibility.Collapsed;
        }, "acoustic_torso.delay_model");
        panel.Children.Add(distance);
        ChoiceRow(panel, "HRIR interpolation", ["Peak-aligned interpolation", "Nearest direction"], settings.Interpolation == "nearest" ? 1 : 0, index => settings.Interpolation = index == 1 ? "nearest" : "aligned_idw", "acoustic_torso.interpolation");
        ChoiceRow(panel, "Missing reflection coverage", ["Stop export", "Skip uncovered directions"], settings.MissingPolicy == "skip" ? 1 : 0, index => settings.MissingPolicy = index == 1 ? "skip" : "error", "acoustic_torso.missing_policy");
    }

    void OptionalAcousticNumber(StackPanel panel, string title, string id, Func<double?> read, Action<double?> write)
    {
        string Display() => read()?.ToString("G", CultureInfo.CurrentCulture) ?? "";
        var box = new TextBox { Text = Display(), PlaceholderText = "All directions", Width = 144 };
        void Commit() {
            if (string.IsNullOrWhiteSpace(box.Text)) { write(null); SaveAppPreferences(); box.Description = null; return; }
            if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var number) || !double.IsFinite(number)) { box.Description = "Enter a finite elevation, or leave it blank for all directions."; return; }
            if (SettingsCatalog.FieldMessage(id, number.ToString("R", CultureInfo.InvariantCulture)) is string error) { box.Description = error; return; }
            write(number); SaveAppPreferences(); box.Description = null;
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => {
            if (args.Key == global::Windows.System.VirtualKey.Enter) { Commit(); args.Handled = true; }
            if (args.Key == global::Windows.System.VirtualKey.Escape) { box.Text = Display(); box.Description = null; args.Handled = true; }
        };
        panel.Children.Add(new CommunityToolkit.WinUI.Controls.SettingsCard { Header = DefaultsLabel(title, id), Content = box });
    }

}

