using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    static readonly string[] WorkflowTitles = ["Project", "Prepare ears & model", "Simulation setup", "Calculate", "SOFA export"];
    readonly StackPanel[] workflowPages = Enumerable.Range(0, 5).Select(_ => new StackPanel { Spacing = 10 }).ToArray();
    readonly ListBox workflowNavigation = new() { SelectionMode = SelectionMode.Single };
    readonly TextBlock[] workflowStates = Enumerable.Range(0, 5).Select(_ => new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap }).ToArray();
    readonly TextBlock[] workflowReasons = Enumerable.Range(0, 5).Select(_ => new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap }).ToArray();
    readonly RadioButtons workflowSource = new() { Header = "Input source", MaxColumns = 1, ItemsSource = new[] { "Full-head scan", "Individual ear meshes" } };
    readonly RadioButtons workflowMethod = new() { Header = "Ear modelling method", MaxColumns = 1, ItemsSource = new[] { "Mesh2PPM", "Manual PPM fitting", "No PPM" } };
    readonly StackPanel workflowEarInputs = new() { Spacing = 8 }, workflowScanInputs = new() { Spacing = 8 }, workflowPreparation = new() { Spacing = 8 }, workflowManual = new() { Spacing = 8 }, workflowInference = new() { Spacing = 8 };
    FrameworkElement? workflowLevelOffset, workflowSamplingRate;
    readonly StackPanel workflowSpatial = new() { Spacing = 8 };
    readonly TextBlock workflowDirect = new() { Text = "Using ear meshes directly. Required mesh preprocessing still runs.", TextWrapping = TextWrapping.Wrap };
    readonly List<(string Side, StackPanel Row, TextBlock Status, Button Inspect, Button Edit, Button Original)> workflowEarRows = [];
    readonly List<(string Side, StackPanel Row, TextBlock Status, Button Fit)> workflowFitRows = [];
    readonly Button workflowCompact = new() { Content = "Show workflow", MaxWidth = 260 };
    readonly ProgressBar workflowProgress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    ScrollViewer workflowScroll = new();
    bool updatingWorkflow;
    int workflowStep;

    static IEnumerable<string> WorkflowSides(ProjectRecord p) => new[] { "left", "right" }.Where(side => p.Settings.ScanPreparation.Enabled
        ? side == "left" ? p.Settings.ScanPreparation.PrepareLeft : p.Settings.ScanPreparation.PrepareRight
        : !string.IsNullOrWhiteSpace(side == "left" ? p.LeftEar : p.RightEar));

    static string? CurrentEarModel(ProjectRecord project)
    {
        var settings = project.Settings;
        if (settings.EarModelMethod is "mesh2ppm" or "manual" or "none") return settings.EarModelMethod;
        if (!settings.ManualPPM.Enabled) return settings.Inference.UsePredictionsForPreprocessing ? "mesh2ppm" : "none";
        if (settings.Inference.UsePredictionsForPreprocessing || WorkflowSides(project).Any(side => settings.ManualPPM.For(side) == null)) return null;
        return "manual";
    }

    static string WorkflowStageTitle(Stage stage) => stage == Stage.ScanPreparation ? "Prepare ears" : stage == Stage.Inference ? "Mesh2PPM" : WorkflowTitles[Math.Max(1, Array.IndexOf(Stage.GetValues(), stage))];

    TextBlock WorkflowText(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = mutedTextBrush, FontSize = 12 };
    Button WorkflowButton(string title, RoutedEventHandler action) { var b = new Button { Content = title }; b.Click += action; return b; }

    Border BuildWorkflowPane()
    {
        settingsPaneBorder = new Border { Background = secondarySurfaceBrush, BorderBrush = borderBrush, BorderThickness = new Thickness(1, 0, 0, 0) };
        var outer = new Grid();
        outer.RowDefinitions.Add(new() { Height = GridLength.Auto });
        outer.RowDefinitions.Add(new() { Height = GridLength.Auto });
        outer.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        outer.RowDefinitions.Add(new() { Height = GridLength.Auto });
        outer.Children.Add(new TextBlock { Text = "Workflow", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(14, 10, 14, 6) });
        for (var i = 0; i < 5; i++) {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = $"{i + 1}. {WorkflowTitles[i]}", VerticalAlignment = VerticalAlignment.Center, Foreground = primaryTextBrush });
            Grid.SetColumn(workflowStates[i], 1);
            workflowStates[i].VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(workflowStates[i]);
            workflowNavigation.Items.Add(new ListBoxItem { Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(8, 3, 8, 3) });
            workflowPages[i].Children.Add(new TextBlock { Text = WorkflowTitles[i], FontSize = 18, FontWeight = FontWeights.SemiBold });
        }
        AutomationProperties.SetName(workflowNavigation, "Workflow stages");
        workflowNavigation.SelectionChanged += (_, _) => { if (workflowNavigation.SelectedIndex >= 0) SelectWorkflowStep(workflowNavigation.SelectedIndex); };
        Grid.SetRow(workflowNavigation, 1); outer.Children.Add(workflowNavigation);
        var host = new Grid { Margin = new Thickness(14, 12, 14, 12) };
        foreach (var page in workflowPages) host.Children.Add(page);
        var scroll = new ScrollViewer { Content = host, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        workflowScroll = scroll;
        Grid.SetRow(scroll, 2); outer.Children.Add(scroll);

        var input = workflowPages[0];
        AddSetting(input, "Project name", "project.name", projectNameBox);
        AddPathSetting(input, "Save location", "project.save_location", saveLocationBox, BrowseSaveLocationClicked);
        input.Children.Add(workflowSource);
        AddPathSetting(workflowEarInputs, "Left ear (optional)", "project.left_ear", leftEarBox, BrowseLeftEarClicked);
        AddPathSetting(workflowEarInputs, "Right ear (optional)", "project.right_ear", rightEarBox, BrowseRightEarClicked);
        workflowEarInputs.Children.Add(WorkflowText("Choose at least one ear. Inspect and edit in Prepare ears.")); input.Children.Add(workflowEarInputs);
        AddPathSetting(workflowScanInputs, "Full-head scan", "scan_preparation.scan_path", scanPathBox, BrowseScanClicked);
        workflowScanInputs.Children.Add(WorkflowText("Choose ears beside Align scan, then extract them in Prepare ears."));
        input.Children.Add(workflowScanInputs);
        workflowSource.SelectionChanged += (_, _) => {
            if (updatingWorkflow || loading || selectedProject is not { } p || ProjectBusy(p.Id)) return;
            p.Settings.ScanPreparation.Enabled = workflowSource.SelectedIndex == 0;
            Persist(); LoadSelectedProject(); RefreshArtifacts(); RefreshPipelineStatus();
        };
        var prepare = workflowPages[1]; prepare.Children.Add(workflowPreparation);
        var alignmentRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        alignmentRow.Children.Add(alignScanButton); alignScanButton.Click += BeginScanAlignmentClicked;
        var prepareLabel = WorkflowText("Prepare"); prepareLabel.VerticalAlignment = VerticalAlignment.Center;
        alignmentRow.Children.Add(prepareLabel);
        foreach (var (side, box) in new[] { ("left", prepareLeftEarBox), ("right", prepareRightEarBox) }) {
            box.Content = side == "left" ? "Left" : "Right";
            box.MinWidth = 0; box.MinHeight = 28; box.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetName(box, "Prepare " + side + " ear");
            box.Click += (_, _) => {
                if (loading || updatingWorkflow || selectedProject is not { } project || ProjectBusy(project.Id)) return;
                if (side == "left") project.Settings.ScanPreparation.PrepareLeft = box.IsChecked == true;
                else project.Settings.ScanPreparation.PrepareRight = box.IsChecked == true;
                Persist(); LoadSelectedProject(); RefreshArtifacts(); RefreshPipelineStatus();
            };
            alignmentRow.Children.Add(box);
        }
        workflowPreparation.Children.Add(alignmentRow);
        workflowPreparation.Children.Add(WorkflowText("Use an aligned scan, or align it here before preparing ears."));
        AddExpander(workflowPreparation, "Advanced settings - scan preparation", [
            AddSettingPanel("Target edge length (mm)", "scan_preparation.target_edge", targetEdgeBox),
            AddSettingPanel("Left crop margin (mm)", "scan_preparation.left_margin", leftMarginBox),
            AddSettingPanel("Right crop margin (mm)", "scan_preparation.right_margin", rightMarginBox),
            AddSettingPanel("Inner crop limit (mm)", "scan_preparation.side_min", sideMinBox),
            AddSettingPanel("Outer crop limit (mm)", "scan_preparation.side_max", sideMaxBox), WorkflowText("Use an aligned scan in mm. A saved, current ear edit is used automatically.")]);
        requireReviewBox.Click += (_, _) => { if (!loading && selectedProject is { } p) { p.Settings.ScanPreparation.RequireManualReview = requireReviewBox.IsChecked == true; Persist(); RefreshPipelineStatus(); } };
        prepare.Children.Add(WorkflowText("Inspect and optionally edit each ear. Original files are preserved."));
        foreach (var side in new[] { "left", "right" }) {
            var row = new StackPanel { Spacing = 6 };
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            actions.Children.Add(new TextBlock { Text = $"{char.ToUpperInvariant(side[0]) + side[1..]} ear", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            var status = WorkflowText("");
            var inspect = WorkflowButton("Inspect", (_, _) => { if (selectedProject is { } p && SourceEar(p, side) is string path) OpenArtifact(new Artifact($"{side} ear", path, side)); });
            var edit = WorkflowButton("Edit...", async (_, _) => await EditPreparedEarAsync(side));
            actions.Children.Add(inspect); actions.Children.Add(edit); row.Children.Add(actions); row.Children.Add(status);
            var original = WorkflowButton("Use original ear", (_, _) => { if (selectedProject is { } p && !ProjectBusy(p.Id)) {
                p.Settings.ScanPreparation.SetEarEdit(side, null);
                InvalidateManualPositions(p); Persist(); RefreshArtifacts(); RefreshPipelineStatus();
            }}); row.Children.Add(original); prepare.Children.Add(row);
            workflowEarRows.Add((side, row, status, inspect, edit, original));
        }
        var model = prepare; model.Children.Add(workflowMethod);
        model.Children.Add(WorkflowText("One method applies to every included ear."));
        workflowMethod.SelectionChanged += (_, _) => {
            if (updatingWorkflow || loading || selectedProject is not { } p || ProjectBusy(p.Id) || workflowMethod.SelectedIndex < 0) return;
            p.Settings.SelectEarModel(new[] { "mesh2ppm", "manual", "none" }[workflowMethod.SelectedIndex]);
            InvalidateManualPositions(p); Persist(); LoadSelectedProject(); RefreshArtifacts(); RefreshPipelineStatus();
        };
        workflowInference.Children.Add(WorkflowText("Generate PPM geometry automatically."));
        workflowInference.Children.Add(AddSettingPanel("Model", "inference.model", modelPicker));
        model.Children.Add(workflowInference); model.Children.Add(workflowManual); model.Children.Add(workflowDirect);
        foreach (var side in new[] { "left", "right" }) {
            var row = new StackPanel { Spacing = 4 }; var status = WorkflowText(""); row.Children.Add(status);
            var fit = WorkflowButton($"Fit {side} ear...", async (_, _) => await TryOpenPPMFittingAsync(side)); row.Children.Add(fit);
            workflowManual.Children.Add(row); workflowFitRows.Add((side, row, status, fit));
        }
        workflowManual.Children.Add(WorkflowText("Save a current fit for every included ear to continue."));
        var simulation = workflowPages[2]; simulation.Children.Add(GeometryPanel());
        simulation.Children.Add(new TextBlock { Text = "Microphone positions", FontWeight = FontWeights.SemiBold });
        simulation.Children.Add(WorkflowText("Automatic positioning remains the default; adjust only when needed."));
        var microphoneActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        placeLeftButton.Content = "Adjust left…"; placeRightButton.Content = "Adjust right…";
        AutomationProperties.SetName(placeLeftButton, "Adjust left microphone");
        AutomationProperties.SetName(placeRightButton, "Adjust right microphone");
        microphoneActions.Children.Add(placeLeftButtonHost!); microphoneActions.Children.Add(placeRightButtonHost!);
        simulation.Children.Add(microphoneActions);
        simulation.Children.Add(PathSettingPanel("Evaluation grid", "mesh2hrtf.evaluation_grid", evaluationGridBox, BrowseEvaluationGridClicked));
        AddSetting(simulation, "Min frequency", "mesh2hrtf.min_frequency", minFrequencyBox);
        AddSetting(simulation, "Max frequency", "mesh2hrtf.max_frequency", maxFrequencyBox);
        AddSetting(simulation, "Frequency steps", "mesh2hrtf.frequency_steps", frequencyStepsBox);
        AddSetting(simulation, "Microphone faces", "mesh2hrtf.microphone_faces", microphoneFacesBox);
        AddExpander(simulation, "Advanced mesh grading", [WorkflowText("Required safety step"),
            AddSettingPanel("Min edge length", "mesh_grading.min_edge_length", meshMinEdgeBox), AddSettingPanel("Max edge length", "mesh_grading.max_edge_length", meshMaxEdgeBox),
            AddSettingPanel("Max error", "mesh_grading.max_error", meshMaxErrorBox), AddSettingPanel("Gamma", "mesh_grading.gamma", meshGammaBox), AddSettingPanel("Gamma opposite", "mesh_grading.gamma_opposite", meshGammaOppositeBox)]);
        numCalcStatusText = WorkflowText(""); workflowPages[3].Children.Add(numCalcStatusText);
        AddSetting(workflowPages[3], "Parallel instances", "numcalc.parallel_instances", maxInstancesBox);
        AddSetting(workflowPages[3], "CPU limit (%)", "numcalc.cpu_limit", maxCpuLoadBox);
        AddSetting(workflowPages[3], "Adaptive FMM expansion length", "numcalc.adaptive_fmm", adaptiveFmmLengthBox);
        var results = workflowPages[4];
        AddSetting(results, "Apply level offset", "postprocessing.normalize", normalizeHrtfsBox);
        workflowLevelOffset = AddSettingPanel("Level offset (dB)", "postprocessing.level_offset", levelOffsetBox); results.Children.Add(workflowLevelOffset);
        AddSetting(results, "Resample HRIRs", "postprocessing.resample_hrirs", resampleHrirsBox);
        workflowSamplingRate = AddSettingPanel("Sampling rate (Hz)", "postprocessing.sampling_rate", samplingRateBox); results.Children.Add(workflowSamplingRate);
        AddSetting(results, "Spatially upsample HRTFs", "postprocessing.spatial_upsampling", spatialUpsamplingBox);
        AddSetting(workflowSpatial, "Subdivision level (0–5)", "postprocessing.spatial_subdivisions", spatialSubdivisionsBox);
        AddSetting(workflowSpatial, "Normalize to frontal reference", "postprocessing.spatial_normalize", spatialNormalizeBox);
        workflowSpatial.Children.Add(WorkflowText("Adds source directions while preserving arrival times. Results are saved in Upsampled; originals are kept.")); results.Children.Add(workflowSpatial);
        results.Children.Add(PathSettingPanel("SOFA output folder (optional)", "postprocessing.output_folder", sofaFolderBox, async (_, _) => { var path = await PickFolderAsync(sofaFolderBox.Text); if (path != null) sofaFolderBox.Text = path; }));
        results.Children.Add(WorkflowButton("Open output folder", (_, _) => { if (selectedProject is { } p && Directory.Exists(SofaDirectory(p))) OpenExternal(SofaDirectory(p)); }));
        results.Children.Add(WorkflowText("Use Viewing above the viewer to inspect generated meshes, plots and pressure fields."));
        var stages = Stage.GetValues();
        for (var index = 0; index < stages.Length; index++) {
            var stage = stages[index];
            var target = stage == Stage.ScanPreparation ? workflowPreparation
                : stage == Stage.Inference ? workflowInference : workflowPages[index];
            var run = WorkflowButton("Run " + WorkflowStageTitle(stage), StageButtonClicked);
            run.Tag = stage;
            stageButtons.Add(run);
            target.Children.Add(run);
            target.Children.Add(workflowReasons[index]);
        }
        var footer = new StackPanel { Spacing = 6, Margin = new Thickness(14, 8, 14, 12) };
        runAllButton = WorkflowButton("Continue", (_, _) => PerformWorkflowAction());
        runAllButton.HorizontalAlignment = HorizontalAlignment.Stretch;
        pipelineHintText = WorkflowText("");
        footer.Children.Add(workflowProgress);
        footer.Children.Add(pipelineHintText);
        footer.Children.Add(runAllButton);
        Grid.SetRow(footer, 3); outer.Children.Add(footer);
        settingsPaneBorder.Child = outer; RegisterSettingControls();
        SelectWorkflowStep(0); return settingsPaneBorder;
    }

    void SelectWorkflowStep(int step)
    {
        workflowStep = Math.Clamp(step, 0, 4);
        foreach (var (page, i) in workflowPages.Select((page, i) => (page, i))) page.Visibility = i == workflowStep ? Visibility.Visible : Visibility.Collapsed;
        if (workflowNavigation.SelectedIndex != workflowStep) workflowNavigation.SelectedIndex = workflowStep;
    }
    sealed record WorkflowAction(string Title, int Step, Stage? Stage = null, string? Fit = null, bool Enabled = true);
    string? WorkflowInputIssue(ProjectRecord p)
    {
        if (string.IsNullOrWhiteSpace(p.SaveLocation)) return "Choose save location";
        if (p.Settings.ScanPreparation.Enabled && !File.Exists(p.Settings.ScanPreparation.ScanPath)) return "Choose full-head scan";
        if (!WorkflowSides(p).Any()) return p.Settings.ScanPreparation.Enabled ? "Select ears to prepare" : "Choose an ear mesh";
        if (!p.Settings.ScanPreparation.Enabled && WorkflowSides(p).Any(side => !File.Exists(side == "left" ? p.LeftEar : p.RightEar))) return "Locate missing ear mesh";
        return null;
    }
    WorkflowAction NextWorkflowAction(ArtifactInspection? inspection = null)
    {
        if (selectedProject is not { } p) return new("Create or select a project", 0, Enabled: false);
        if (runs.ContainsKey(p.Id)) return new("Stop", workflowStep);
        if (placementSide != null) return new("Finish microphone placement", 2);
        if (scanAlignmentMode) return new("Finish scan alignment", 1);
        if (WorkflowInputIssue(p) is string input) return new(input, p.Settings.ScanPreparation.Enabled && !WorkflowSides(p).Any() && File.Exists(p.Settings.ScanPreparation.ScanPath) && !string.IsNullOrWhiteSpace(p.SaveLocation) ? 1 : 0);
        if (p.Settings.ScanPreparation.Enabled && !StageIsComplete(Stage.ScanPreparation, p, inspection)) return new("Run " + WorkflowStageTitle(Stage.ScanPreparation), 1, Stage.ScanPreparation);
        if (WorkflowSides(p).Any(side => p.Settings.ScanPreparation.EarEdit(side) != null && !EarReviewIsCurrent(p, side, inspection))) return new("Review outdated ear edit", 1);
        if (p.Settings.ScanPreparation.Enabled && p.Settings.ScanPreparation.RequireManualReview &&
            WorkflowSides(p).FirstOrDefault(side => !EarReviewIsCurrent(p, side, inspection)) is string reviewSide)
            return new($"Review {reviewSide} ear", 1);
        if (CurrentEarModel(p) == null) return new("Choose one ear modelling method", 1);
        if (p.Settings.ManualPPM.Enabled && WorkflowSides(p).FirstOrDefault(side => !FitIsCurrent(p, side)) is string missing) return new($"Fit {missing} ear", 1, Fit: missing);
        var next = AutomaticStages(p).FirstOrDefault(stage => !StageIsComplete(stage, p, inspection));
        if (next == null) return new("Open results", 4);
        return new("Run " + WorkflowStageTitle(next), Math.Max(1, Array.IndexOf(Stage.GetValues(), next)), next);
    }
    void PerformWorkflowAction()
    {
        if (selectedProject is { } p && runs.ContainsKey(p.Id)) { StopProject(p); return; }
        var action = NextWorkflowAction(); SelectWorkflowStep(action.Step);
        if (!macInspectorVisible) ToggleMacInspector();
        if (!action.Enabled) return;
        if (action.Step == 0 && selectedProject is { } project) {
            if (string.IsNullOrWhiteSpace(project.SaveLocation)) BrowseSaveLocationClicked(this, new RoutedEventArgs());
            else if (project.Settings.ScanPreparation.Enabled && !File.Exists(project.Settings.ScanPreparation.ScanPath)) BrowseScanClicked(this, new RoutedEventArgs());
            else if (!project.Settings.ScanPreparation.Enabled) {
                if (!string.IsNullOrEmpty(project.RightEar) && !File.Exists(project.RightEar)) BrowseRightEarClicked(this, new RoutedEventArgs());
                else if (!string.IsNullOrEmpty(project.LeftEar) && !File.Exists(project.LeftEar)) BrowseLeftEarClicked(this, new RoutedEventArgs());
                else leftEarBox.Focus(FocusState.Programmatic);
            }
            return;
        }
        if (action.Step == 4 && action.Stage == null && selectedProject is { } resultProject) {
            var folder = SofaDirectory(resultProject);
            if (Directory.Exists(folder)) OpenExternal(folder);
            return;
        }
        if (action.Fit != null) _ = TryOpenPPMFittingAsync(action.Fit);
        else if (action.Stage != null && StageCanRun(action.Stage, selectedProject)) RunStage(action.Stage);
    }
    void RefreshWorkflow(ArtifactInspection? inspection = null)
    {
        updatingWorkflow = true;
        try {
            var p = selectedProject; var scan = p?.Settings.ScanPreparation.Enabled == true; var busy = p == null || ProjectBusy(p.Id);
            workflowSource.SelectedIndex = scan ? 0 : 1;
            workflowMethod.SelectedIndex = (p == null ? null : CurrentEarModel(p)) switch {
                "mesh2ppm" => 0, "manual" => 1, "none" => 2, _ => -1
            };
            workflowEarInputs.Visibility = scan ? Visibility.Collapsed : Visibility.Visible;
            workflowScanInputs.Visibility = workflowPreparation.Visibility = scan ? Visibility.Visible : Visibility.Collapsed;
            workflowInference.Visibility = workflowMethod.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            workflowManual.Visibility = workflowMethod.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            workflowDirect.Visibility = workflowMethod.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
            workflowScroll.IsEnabled = !busy;
            workflowSource.IsEnabled = workflowMethod.IsEnabled = !busy;
            var sides = p == null ? [] : WorkflowSides(p).ToArray();
            foreach (var row in workflowEarRows) {
                row.Row.Visibility = sides.Contains(row.Side) ? Visibility.Visible : Visibility.Collapsed;
                var ready = p != null && (!scan || StageIsComplete(Stage.ScanPreparation, p, inspection)) && SourceEar(p, row.Side, inspection) != null;
                row.Inspect.IsEnabled = row.Edit.IsEnabled = ready && !busy;
                var saved = p != null && p.Settings.ScanPreparation.EarEdit(row.Side) != null;
                row.Original.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
                row.Status.Text = saved ? EarReviewIsCurrent(p!, row.Side, inspection) ? "Saved edit in use" : "Saved edit outdated" : ready ? "Ready - editing optional" : "Prepare or choose an ear first";
                // Editing an outdated reviewed mesh must reopen its original source.
                row.Edit.IsEnabled = !busy && p != null && (!scan || StageIsComplete(Stage.ScanPreparation, p, inspection));
            }
            foreach (var row in workflowFitRows) {
                row.Row.Visibility = sides.Contains(row.Side) ? Visibility.Visible : Visibility.Collapsed;
                row.Status.Text = p != null && FitIsCurrent(p, row.Side) ? $"{row.Side}: complete" : $"{row.Side}: current fit required";
                row.Fit.IsEnabled = !busy && p != null && SourceEar(p, row.Side, inspection) != null;
            }
            workflowStates[0].Text = p != null && WorkflowInputIssue(p) == null ? "Complete" : "Needs input";
            for (var i = 0; i < 5; i++) {
                var stage = Stage.GetValues()[i];
                if (i != 1) workflowStates[Math.Max(1, i)].Text = p == null ? "Needs input" : stageStatus[i].Text;
                workflowReasons[i].Text = p == null ? "Select a project" : StageUnavailableReason(stage, p, inspection) ?? "Ready";
                var stopping = p != null && runs.TryGetValue(p.Id, out var active) && active.Stage == stage;
                stageButtons[i].Content = stopping ? "Stop" : "Run " + WorkflowStageTitle(stage);
                StyleWorkflowRun(stageButtons[i], stopping);
            }
            if (!scan) workflowStates[1].Text = "Optional";
            if (p != null && (!scan || StageIsComplete(Stage.ScanPreparation, p, inspection))) {
                if (workflowMethod.SelectedIndex == -1) workflowStates[1].Text = "Choose method";
                else if (workflowMethod.SelectedIndex == 1) workflowStates[1].Text = sides.Length > 0 && sides.All(side => FitIsCurrent(p, side)) ? "Complete" : "Needs fit";
                else if (workflowMethod.SelectedIndex == 0) workflowStates[1].Text = stageStatus[1].Text;
            }
            for (var index = 0; index < workflowStates.Length; index++) {
                var label = workflowStates[index].Text;
                if (label == "Blocked") label = index == 0 ? "Needs input" : "Waiting";
                if (label == "Done") label = "Complete";
                if (p != null && index >= 3 && label is "Waiting" or "Ready" && statusSnapshots.TryGetValue(p.Id, out var snapshot) &&
                    snapshot.Revision == StatusRevision(p) && snapshot.Outdated.Contains(Stage.GetValues()[index])) label = "Needs rerun";
                var symbol = label switch { "Complete" => "\u2713", "Failed" or "Needs rerun" => "!", "Not needed" or "Optional" => "\u2013",
                    "Ready" => "\u25B7", "Running\u2026" => "\u25B6", _ => "\u25CB" };
                workflowStates[index].Text = $"{symbol}  {label}";
                workflowStates[index].Foreground = WorkflowStatusBrush(label);
                var item = (ListBoxItem)workflowNavigation.Items[index];
                var selected = new SolidColorBrush(Root.ActualTheme == ElementTheme.Dark ? ColorHelper.FromArgb(255, 43, 61, 80) : ColorHelper.FromArgb(255, 224, 238, 251));
                foreach (var key in new[] { "ListBoxItemBackgroundSelected", "ListBoxItemBackgroundSelectedPointerOver", "ListBoxItemBackgroundSelectedPressed" }) item.Resources[key] = selected;
                AutomationProperties.SetName((ListBoxItem)workflowNavigation.Items[index], $"{WorkflowTitles[index]}, {label}");
            }
            var next = NextWorkflowAction(inspection);
            var reason = next.Stage != null && p != null ? StageUnavailableReason(next.Stage, p, inspection) : null;
            runAllButton.Content = reason == null ? next.Title : "Review " + WorkflowTitles[next.Step].ToLowerInvariant(); runAllButton.IsEnabled = next.Enabled && (!busy || p != null && runs.ContainsKey(p.Id));
            var retry = p != null && next.Stage != null && FailedStages(p.Id).Contains(next.Stage);
            if (retry && reason == null) runAllButton.Content = "Retry " + WorkflowStageTitle(next.Stage!);
            workflowCompact.Content = runAllButton.Content;
            StyleWorkflowRun(runAllButton, p != null && runs.ContainsKey(p.Id));
            StyleWorkflowRun(workflowCompact, p != null && runs.ContainsKey(p.Id));
            if (workflowLevelOffset != null) workflowLevelOffset.Visibility = normalizeHrtfsBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            if (workflowSamplingRate != null) workflowSamplingRate.Visibility = resampleHrirsBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            workflowSpatial.Visibility = spatialUpsamplingBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            workflowCompact.Visibility = macInspectorVisible ? Visibility.Collapsed : Visibility.Visible;
            workflowProgress.Visibility = p != null && runs.ContainsKey(p.Id) ? Visibility.Visible : Visibility.Collapsed;
            pipelineHintText.Text = reason ?? (p == null ? "Select a project" : next.Fit != null ? "Manual fit required" : next.Stage != null ? "Ready" : runs.ContainsKey(p.Id) ? "Running" : "Next action");
            if (retry && reason == null) pipelineHintText.Text = next.Stage!.Title + " failed. Review its inputs before retrying.";
            pipelineHintText.Visibility = Visibility.Visible;
        } finally { updatingWorkflow = false; }
    }

    Brush WorkflowStatusBrush(string status)
    {
        var dark = Root.ActualTheme == ElementTheme.Dark;
        if (status == "Complete") return new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 108, 203, 95) : ColorHelper.FromArgb(255, 15, 123, 15));
        if (status == "Failed") return new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 255, 153, 164) : ColorHelper.FromArgb(255, 196, 43, 28));
        if (status is "Needs rerun" or "Stopped" or "Choose method" || status.StartsWith("Needs")) return new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 255, 179, 71) : ColorHelper.FromArgb(255, 157, 83, 0));
        if (status == "Ready" || status.StartsWith("Running")) return new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 96, 175, 255) : ColorHelper.FromArgb(255, 0, 95, 184));
        return mutedTextBrush;
    }

    static void StyleWorkflowRun(Button button, bool stop)
    {
        if (Application.Current.Resources.TryGetValue("AccentButtonStyle", out var style)) button.Style = (Style)style;
        var colour = stop ? ColorHelper.FromArgb(255, 196, 43, 28) : ColorHelper.FromArgb(255, 0, 95, 184);
        var brush = new SolidColorBrush(colour);
        button.Background = brush; button.Foreground = new SolidColorBrush(Colors.White);
        foreach (var key in new[] { "AccentButtonBackground", "AccentButtonBackgroundPointerOver", "AccentButtonBackgroundPressed" }) button.Resources[key] = brush;
        foreach (var key in new[] { "AccentButtonForeground", "AccentButtonForegroundPointerOver", "AccentButtonForegroundPressed" }) button.Resources[key] = new SolidColorBrush(Colors.White);
    }
}
