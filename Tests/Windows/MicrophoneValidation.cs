using Microsoft.UI.Xaml;
using System.Numerics;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    readonly List<object> checks = [];
    string TestRoot => Path.Combine(FindPackageRoot(), "build", "windows-regression");

    void Check(string name, bool passed)
    {
        checks.Add(new { name, passed, log = passed ? null : string.Join("\n", projectLogs.Values), placement = passed ? null : new { placementSide, placementMeshPath, currentMesh = currentMesh?.Path, calculatingAutomaticPosition, pendingMicrophonePosition } });
        File.WriteAllText(Path.Combine(TestRoot, "results.json"), JsonSerializer.Serialize(checks, jsonOptions));
        if (!passed) throw new InvalidOperationException(name);
    }

    ProjectRecord Fixture()
    {
        var folder = Path.Combine(TestRoot, "fixtures", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var project = NewProject(1);
        project.SaveLocation = folder;
        foreach (var (side, name) in new[] { ("Left", "auricleA"), ("Right", "auricleB") })
        {
            var raw = Path.Combine(folder, "Raw", name + ".stl");
            Directory.CreateDirectory(Path.GetDirectoryName(raw)!);
            File.Copy(Path.Combine(packageRoot, "Test Data", "Input", side, side + ".stl"), raw);
            if (side == "Left") project.LeftEar = raw; else project.RightEar = raw;
            var intermediate = Path.Combine(folder, "Intermediates", side);
            Directory.CreateDirectory(intermediate);
            foreach (var prefix in new[] { "ICP_", "Prediction_" }) File.Copy(raw, Path.Combine(intermediate, prefix + name + ".stl"));
            File.Copy(raw, Path.Combine(intermediate, "closed_ear.stl"));
            File.WriteAllText(Path.Combine(intermediate, "graded_head.ply"), "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n");
            var parameters = Path.Combine(folder, "Projects", side);
            Directory.CreateDirectory(parameters);
            File.WriteAllText(Path.Combine(parameters, "parameters.json"), "{\"sourceCenter\":[0.011,0.072,0.003]}");
        }
        return project;
    }

    void SelectFixture(ProjectRecord project)
    {
        if (placementSide != null) EndPlacement();
        selectedProject = project;
        if (!projects.Contains(project)) projects.Add(project);
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
        RefreshPipelineStatus();
    }

    public async void RunMicrophoneValidation()
    {
        try
        {
            await Task.Delay(1200);
            statusTimer.Stop();
            Check("Validation profile is isolated", appData.StartsWith(TestRoot, StringComparison.OrdinalIgnoreCase));
            var project = Fixture();
            SelectFixture(project);
            Check("Native preprocessing libraries load", ValidateExternalRuntime(project));
            Check("Preprocessing can run with the bundled tools", StageCanRun(Stage.Preprocessing, project));
            var nativeTool = environment.MeshGradingExecutable;
            environment.MeshGradingExecutable = Path.Combine(TestRoot, "missing-grading.exe");
            RefreshPipelineStatus();
            Check("Missing preprocessing tool has a visible explanation", !stageButtons[1].IsEnabled && pipelineHintText.Text.Contains("mesh-grading tool is missing"));
            environment.MeshGradingExecutable = nativeTool;

            foreach (var side in new[] { "left", "right" })
            {
                var prediction = PredictionMesh(project, side)!;
                Check(side + " prediction selected instead of ICP or head", Path.GetFileName(prediction).StartsWith("Prediction_"));
                Check(side + " preview label contains only the ear name", ArtifactsFor(project).Single(a => SamePath(a.Path, prediction)).Title == $"Predicted {side} ear");
                await BeginPlacementAsync(side);
                Check(side + " placement opens the prediction", SamePath(currentMesh?.Path, prediction) && SamePath((artifactPicker.SelectedItem as Artifact)?.Path, prediction));
                Check("Placement blocks Run and the menu execution path", !StageCanRun(Stage.Preprocessing, project) && !stageButtons[1].IsEnabled);
                RefreshArtifacts();
                Check("Artifact refresh preserves placement", PlacementIsCurrent());
                await UseAutomaticPositionAsync();
                Check(side + " automatic calculation enables Done", donePositionButton.IsEnabled && pendingMicrophonePosition != null);
                DonePositionClicked(this, new RoutedEventArgs());
                Check(side + " Done saves on predicted mesh", placementSide == null && ValidManualPosition(project, side) && SamePath(ManualPosition(project, side)?.MeshPath, prediction));
                var input = side == "left" ? project.LeftEar : project.RightEar;
                Check(side + " unused input has no marker", MicrophonePosition(input) == null);
                Check(side + " prediction retains marker", MicrophonePosition(prediction) != null);
                var simulation = Path.Combine(project.SaveLocation, "Intermediates", side == "left" ? "Left" : "Right", "graded_head.ply");
                Check(side + " simulation uses exported coordinates", MicrophonePosition(simulation) is Vector3 p && Vector3.Distance(p, new Vector3(11, 72, 3)) < 0.001f);
            }
            var config = File.ReadAllText(PrepareConfig(project));
            Check("Copying inputs preserves both predicted mic positions in YAML", config.Contains("source_position_input_left:") && config.Contains("source_position_input_right:"));
            Check("Done restores Preprocessing", StageCanRun(Stage.Preprocessing, project));

            project.Settings.Inference.UsePredictionsForPreprocessing = false;
            InvalidateManualPositions(project);
            SelectFixture(project);
            foreach (var side in new[] { "left", "right" })
            {
                var input = side == "left" ? project.LeftEar : project.RightEar;
                await BeginPlacementAsync(side);
                Check(side + " inference off opens input", SamePath(currentMesh?.Path, input));
                await UseAutomaticPositionAsync();
                Check(side + " input automatic calculation enables Done", donePositionButton.IsEnabled);
                DonePositionClicked(this, new RoutedEventArgs());
                Check(side + " input Done saves and shows marker", ValidManualPosition(project, side) && MicrophonePosition(input) != null);
                Check(side + " unused prediction has no marker", MicrophonePosition(PredictionMesh(project, side)!) == null);
            }
            Check("Copying inputs preserves input mic coordinates in YAML", File.ReadAllText(PrepareConfig(project)).Contains("source_position_input_left:"));

            await BeginPlacementAsync("left");
            var calculation = UseAutomaticPositionAsync();
            EndPlacement();
            await BeginPlacementAsync("right");
            await calculation;
            Check("Cancelled calculation cannot modify the next placement", placementSide == "right" && SamePath(pendingMicrophonePosition?.MeshPath, project.RightEar));
            EndPlacement();
            await BeginPlacementAsync("left");
            File.SetLastWriteTimeUtc(project.LeftEar, DateTime.UtcNow.AddMinutes(1));
            DonePositionClicked(this, new RoutedEventArgs());
            Check("Changed mesh cannot save a stale position", placementSide == "left" && !ValidManualPosition(project, "left"));
            EndPlacement();

            await BeginPlacementAsync("right");
            calculation = UseAutomaticPositionAsync();
            var nextProject = Fixture();
            SelectFixture(nextProject);
            await calculation;
            Check("Project switch cancels placement without saving into the new project", placementSide == null && pendingMicrophonePosition == null && ManualPosition(nextProject, "right") == null);

            var missing = Fixture();
            File.Delete(PredictionMesh(missing, "left")!);
            SelectFixture(missing);
            Check("ICP and simulation meshes do not count as completed inference", !StageIsComplete(Stage.Inference, missing));
            Check("Missing prediction blocks placement without an input fallback", PreprocessingMesh(missing, "left") == null && !placeLeftButton.IsEnabled);
            Check("Missing prediction explains disabled preprocessing", StageUnavailableReason(Stage.Preprocessing, missing)!.Contains("predicted ears"));
            File.Copy(missing.LeftEar, Path.Combine(missing.SaveLocation, "Intermediates", "Left", "Prediction_other.stl"));
            Check("Unrelated predictions cannot override the backend's input selection", PredictionMesh(missing, "left") == null);
            Check("Windows uses the macOS icon asset", File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "app_icon.png")).SequenceEqual(File.ReadAllBytes(Path.Combine(packageRoot, "Sources", "Pinna2HRTF", "Resources", "app_icon.png"))));
            Environment.Exit(0);
        }
        catch (Exception error)
        {
            checks.Add(new { error = error.ToString() });
            File.WriteAllText(Path.Combine(TestRoot, "results.json"), JsonSerializer.Serialize(checks, jsonOptions));
            Environment.Exit(1);
        }
    }
}
