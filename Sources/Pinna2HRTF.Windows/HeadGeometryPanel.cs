using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    readonly TextBox earDistanceBox = new();
    readonly TextBlock geometryDescription = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    readonly Dictionary<string, GeometryValues> geometryCache = [];
    readonly Dictionary<string, Task<GeometryValues>> geometryRequests = [];
    GeometryValues? displayedGeometry;
    bool geometryEditing;
    bool registrySavingBlocked;
    static string GeometryDisplay(double value) => value.ToString("F2", System.Globalization.CultureInfo.InvariantCulture);

    Grid GeometryPanel()
    {
        var panel = new StackPanel();
        panel.Children.Add(AddSettingPanel("Ear distance from head center (mm)", "mesh2hrtf.ear_distance", earDistanceBox));
        var footer = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        geometryDescription.VerticalAlignment = VerticalAlignment.Top;
        footer.Children.Add(geometryDescription);
        var reset = new Button { Content = "Reset from meshes", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
        reset.Click += async (_, _) => await EditGeometryAsync("reset", "");
        Grid.SetColumn(reset, 1);
        footer.Children.Add(reset);
        panel.Children.Add(footer);
        var grid = new Grid();
        grid.Children.Add(panel);
        return grid;
    }

    GeometryValues ApplyGeometrySettings(GeometryValues measured, PreprocessingSettings settings) =>
        settings.EarDistance == null ? measured : measured.AtDistance(HeadGeometry.Parse(settings.EarDistance));

    async void RefreshGeometry()
    {
        try
        {
            var project = selectedProject;
            if (project == null || geometryEditing) return;
            var left = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
            var right = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
            var key = project.Id + "|" + left + "|" + (left == null ? "" : MeshIdentity(left)) + "|" + right + "|" + (right == null ? "" : MeshIdentity(right));
            if (left == null && right == null)
            {
                displayedGeometry = null;
                loading = true;
                SetGeometryInputText("");
                loading = false;
                geometryDescription.Text = "Load an ear mesh to calculate its distance from the head center.";
                return;
            }
            if (!geometryCache.TryGetValue(key, out var measured))
            {
                displayedGeometry = null;
                geometryDescription.Text = "Calculating geometry…";
                if (!geometryRequests.TryGetValue(key, out var request)) geometryRequests[key] = request = InspectGeometry(left, right);
                try { measured = await request; geometryCache[key] = measured; }
                finally { geometryRequests.Remove(key); }
            }
            if (selectedProject != project || geometryEditing) return;
            // A newer input selection must win over a completed old request.
            var nowLeft = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
            var nowRight = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
            var currentKey = project.Id + "|" + nowLeft + "|" + (nowLeft == null ? "" : MeshIdentity(nowLeft)) + "|" + nowRight + "|" + (nowRight == null ? "" : MeshIdentity(nowRight));
            if (currentKey != key) { RefreshGeometry(); return; }
            try { displayedGeometry = ApplyGeometrySettings(measured, project.Settings.Preprocessing); }
            catch (Exception error)
            {
                displayedGeometry = measured;
                SetGeometryInputText(project.Settings.Preprocessing.EarDistance ?? GeometryDisplay(measured.Distance));
                geometryDescription.Text = error.Message;
                return;
            }
            loading = true;
            SetGeometryInputText(GeometryDisplay(displayedGeometry.Distance));
            loading = false;
            geometryDescription.Text = $"Left: {(displayedGeometry.Left is double l ? GeometryDisplay(l) : "—")} mm; Right: {(displayedGeometry.Right is double r ? GeometryDisplay(r) : "—")} mm.";
        }
        catch (Exception error) { loading = false; displayedGeometry = null; geometryDescription.Text = error.Message; }
    }

    Task<GeometryValues> InspectGeometry(string? left, string? right) => Task.Run(() =>
    {
        var info = new ProcessStartInfo(BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe"))
        { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in new[] { "-m", "HRTFCalculation.Geometry" }) info.ArgumentList.Add(argument);
        if (left != null) { info.ArgumentList.Add("--left"); info.ArgumentList.Add(left); }
        if (right != null) { info.ArgumentList.Add("--right"); info.ArgumentList.Add(right); }
        ApplyProcessEnvironment(info);
        using var process = Process.Start(info) ?? throw new IOException("Could not start geometry inspection.");
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        var result = output.GetAwaiter().GetResult();
        var error = errors.GetAwaiter().GetResult();
        if (process.ExitCode != 0) throw new IOException(error.Trim());
        return JsonSerializer.Deserialize<GeometryValues>(result) ?? throw new IOException("No geometry measurements returned.");
    });

    async Task EditGeometryAsync(string field, string text)
    {
        var project = selectedProject;
        if (loading || geometryEditing || project == null) return;
        if (runningProcesses.ContainsKey(project.Id) || outputOperations.Contains(project.Id)) { LoadSelectedProject(); return; }
        var before = displayedGeometry;
        if (field != "reset" && before != null && text == GeometryDisplay(before.Distance)) return;
        GeometryValues? desired = null;
        try
        {
            if (field != "reset")
            {
                if (before == null) throw new InvalidDataException("Wait for geometry measurements before editing.");
                var number = HeadGeometry.Parse(text);
                if (number == (before.Distance)) return;
                desired = before.AtDistance(number);
            }
            geometryEditing = true;
            LoadSelectedProject();
            await ReconcileOutputsAsync(project, true);
            if (selectedProject != project) return;
            if (Directory.Exists(project.SaveLocation) && HasOutputsFrom(Stage.Preprocessing, project))
            {
                var dialog = new ContentDialog { Title = "Reset pipeline outputs?", Content = "Changing geometry resets Preprocessing and all following outputs. The ear distance will be applied to both ears, preserving their difference.", PrimaryButtonText = "Reset and apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary || selectedProject != project) return;
                if (!await ResetProjectOutputsAsync(project, Stage.Preprocessing) || selectedProject != project) return;
            }
            project.Settings.Preprocessing.EarDistance = desired != null ? HeadGeometry.Number(desired.Distance) : null;
            Persist();
            RefreshPipelineStatus();
        }
        catch (Exception error) { geometryDescription.Text = error.Message; AppendLog("Geometry: " + error.Message, project.Id); }
        finally { geometryEditing = false; LoadSelectedProject(); }
    }

    string GeometryYaml(PreprocessingSettings p)
    {
        if (p.EarDistance == null) return "";
        var value = HeadGeometry.Parse(p.EarDistance);
        if (value <= 0) throw new InvalidDataException("Ear distance must be positive.");
        return "  ear_distance: " + HeadGeometry.Number(value) + "\n";
    }

    ProcessStartInfo GeometryProcess(params string[] arguments)
    {
        var info = new ProcessStartInfo(BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe"))
        { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        ApplyProcessEnvironment(info);
        return info;
    }

    void ReadGeometrySettings(ProjectRecord project, string path)
    {
        // Version compatibility only; remove with v2.0.0.
        using var process = Process.Start(GeometryProcess("-m", "HRTFCalculation.Compatibility", path)) ?? throw new IOException("Could not load project settings.");
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        var json = output.GetAwaiter().GetResult();
        var error = errors.GetAwaiter().GetResult();
        if (process.ExitCode != 0) throw new IOException(error);
        using var document = JsonDocument.Parse(json);
        var value = document.RootElement.GetProperty("ear_distance");
        project.Settings.Preprocessing.EarDistance = value.ValueKind == JsonValueKind.Null ? null : HeadGeometry.Number(value.GetDouble());
        foreach (var notice in document.RootElement.GetProperty("warnings").EnumerateArray()) AppendLog(notice.GetString(), project.Id);
    }

    string EarDistanceInputStamp(ProjectRecord project)
    {
        var paths = new[] {
            PreprocessingMesh(project, "left") ?? project.LeftEar,
            PreprocessingMesh(project, "right") ?? project.RightEar
        };
        return string.Join("|", paths.Select(path => path + ":" + (File.Exists(path) ? MeshIdentity(path) : ""))) +
            "|" + project.Settings.Preprocessing.EarDistance + "|" + project.SaveLocation;
    }

    async Task<bool> ConfirmEarDistanceAsync(ProjectRecord project)
    {
        var stamp = EarDistanceInputStamp(project);
        var left = PreprocessingMesh(project, "left") ?? (File.Exists(project.LeftEar) ? project.LeftEar : null);
        var right = PreprocessingMesh(project, "right") ?? (File.Exists(project.RightEar) ? project.RightEar : null);
        var values = ApplyGeometrySettings(await InspectGeometry(left, right), project.Settings.Preprocessing);
        if (stamp != EarDistanceInputStamp(project))
            throw new InvalidOperationException("Project inputs changed while measuring ear distance. Start preprocessing again.");
        values.Validate();
        if (!HeadGeometry.NeedsWarning(values.Distance)) return true;
        var dialog = new ContentDialog {
            Title = "Ear meshes are close to the head center",
            Content = $"The ear distance from the head center is {GeometryDisplay(values.Distance)} mm. This will produce a very small head. You can proceed anyway or cancel to adjust the distance.",
            PrimaryButtonText = "Proceed anyway", CloseButtonText = "Cancel and adjust",
            DefaultButton = ContentDialogButton.Close, XamlRoot = Root.XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            if (stamp != EarDistanceInputStamp(project))
                throw new InvalidOperationException("Project inputs changed while the warning was open. Start preprocessing again.");
            return true;
        }
        queuedStages.Remove(project.Id);
        _ = FocusEarDistanceAsync(project);
        return false;
    }

    async Task FocusEarDistanceAsync(ProjectRecord project)
    {
        // Let the cancelled launch release its operation guard before focusing.
        await Task.Delay(120);
        selectedProject = project;
        RefreshProjectList();
        LoadSelectedProject();
        var section = settingSections.FirstOrDefault(x => Equals(x.Header, "Mesh2HRTF"));
        if (section != null) section.IsExpanded = true;
        await Task.Delay(120);
        earDistanceBox.StartBringIntoView();
        earDistanceBox.Focus(FocusState.Programmatic);
        earDistanceBox.SelectAll();
    }
}
