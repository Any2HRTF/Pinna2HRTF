using Microsoft.Win32;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using Forms = System.Windows.Forms;

namespace Pinna2HRTF.Windows;

public partial class MainWindow : Window
{
    readonly ObservableCollection<ProjectRecord> projects = [];
    readonly ObservableCollection<Artifact> artifacts = [];
    readonly Dictionary<Guid, Process> runningProcesses = [];
    readonly Dictionary<Guid, Stage> runningStages = [];
    readonly Dictionary<Guid, HashSet<Stage>> failedStages = [];
    readonly JsonSerializerOptions jsonOptions = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    ProjectRegistry registry = new();
    EnvironmentConfig environment = new();
    bool loading;
    bool rotatingMesh;
    System.Windows.Point lastMeshPointer;
    double meshYaw;
    double meshPitch = 23;
    double meshDistance = 305;
    string packageRoot = "";
    string appData = "";
    string registryPath = "";

    public MainWindow()
    {
        InitializeComponent();
        ProjectList.ItemsSource = projects;
        ArtifactPicker.ItemsSource = artifacts;
    }

    void WindowLoaded(object sender, RoutedEventArgs e)
    {
        packageRoot = FindPackageRoot();
        appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinna2HRTF");
        registryPath = Path.Combine(appData, "projects.json");
        Directory.CreateDirectory(appData);
        LoadRegistry();
        RefreshModelOptions();
        RefreshProjectList();
        LoadSelectedProject();
        RefreshArtifacts();
        RefreshEnvironmentStatus();
    }

    void WindowClosing(object? sender, CancelEventArgs e)
    {
        foreach (var process in runningProcesses.Values.ToList())
            TryTerminate(process);
        Persist();
    }

    void LoadRegistry()
    {
        if (File.Exists(registryPath))
        {
            try
            {
                registry = JsonSerializer.Deserialize<ProjectRegistry>(File.ReadAllText(registryPath), jsonOptions) ?? new ProjectRegistry();
            }
            catch
            {
                registry = new ProjectRegistry();
            }
        }
        environment = registry.Environment.IsEmpty ? DefaultEnvironment() : registry.Environment;
        projects.Clear();
        foreach (var project in registry.Projects)
            projects.Add(project);
        if (projects.Count == 0)
            CreateProject();
        var selected = projects.FirstOrDefault(p => p.Id == registry.SelectedProjectID) ?? projects.FirstOrDefault();
        ProjectList.SelectedItem = selected;
    }

    void Persist()
    {
        registry = new ProjectRegistry { Projects = projects.ToList(), SelectedProjectID = SelectedProject?.Id, Environment = environment };
        Directory.CreateDirectory(appData);
        File.WriteAllText(registryPath, JsonSerializer.Serialize(registry, jsonOptions));
    }

    string FindPackageRoot()
    {
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            if (File.Exists(Path.Combine(current.FullName, "pyproject.toml")) && Directory.Exists(Path.Combine(current.FullName, "HRTFCalculation")))
                return current.FullName;
            current = current.Parent;
        }
        current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current != null)
        {
            var candidate = Path.Combine(current.FullName, "Pinna2HRTF");
            if (File.Exists(Path.Combine(candidate, "pyproject.toml")) && Directory.Exists(Path.Combine(candidate, "HRTFCalculation")))
                return candidate;
            current = current.Parent;
        }
        return AppContext.BaseDirectory;
    }

    EnvironmentConfig DefaultEnvironment()
    {
        var external = Directory.Exists(Path.Combine(packageRoot, "External")) ? Path.Combine(packageRoot, "External") : Path.Combine(appData, "External");
        var bin = Path.Combine(external, "bin");
        return new EnvironmentConfig
        {
            UvExecutable = FirstExecutable(Path.Combine(bin, "uv.exe"), "uv.exe"),
            NumCalcExecutable = FirstExecutable(Path.Combine(bin, "NumCalc.exe"), "NumCalc.exe"),
            MeshGradingExecutable = FirstExecutable(Path.Combine(bin, "hrtf_mesh_grading.exe"), "hrtf_mesh_grading.exe"),
            ExternalDir = external
        };
    }

    string FirstExecutable(string bundled, string name)
    {
        if (File.Exists(bundled))
            return bundled;
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var entry in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(entry.Trim(), name);
            if (File.Exists(candidate))
                return candidate;
        }
        return bundled;
    }

    ProjectRecord? SelectedProject => ProjectList.SelectedItem as ProjectRecord;

    void RefreshProjectList()
    {
        foreach (var project in projects)
            project.DisplayTitle = $"{project.Name}  {ArtifactSummary(project)}";
        ProjectList.Items.Refresh();
    }

    void LoadSelectedProject()
    {
        loading = true;
        var project = SelectedProject;
        ProjectNameBox.Text = project?.Name ?? "";
        LeftEarBox.Text = project?.LeftEar ?? "";
        RightEarBox.Text = project?.RightEar ?? "";
        SaveLocationBox.Text = project?.SaveLocation ?? "";
        CopyInputsBox.IsChecked = project?.InputHandling != InputHandling.Reference;
        UsePredictionsBox.IsChecked = project?.Settings.Inference.UsePredictionsForPreprocessing ?? true;
        EvaluationGridBox.Text = project?.Settings.Preprocessing.EvaluationGrid ?? "";
        UseHeadRadiusBox.IsChecked = project?.Settings.Preprocessing.UseCustomHeadRadius ?? project?.Settings.Preprocessing.HeadRadius != null;
        HeadRadiusBox.Text = project?.Settings.Preprocessing.HeadRadius ?? "0";
        MinFrequencyBox.Text = project?.Settings.Preprocessing.MinFrequency ?? "0";
        MaxFrequencyBox.Text = project?.Settings.Preprocessing.MaxFrequency ?? "24000";
        FrequencyStepsBox.Text = project?.Settings.Preprocessing.FrequencyStepCount ?? "129";
        MeshMinEdgeBox.Text = project?.Settings.Preprocessing.MeshMinEdgeLength ?? "0.5";
        MeshMaxEdgeBox.Text = project?.Settings.Preprocessing.MeshMaxEdgeLength ?? "10.0";
        MeshMaxErrorBox.Text = project?.Settings.Preprocessing.MeshMaxError ?? "0.5";
        MeshGammaLeftBox.Text = project?.Settings.Preprocessing.MeshGammaLeft ?? "0.15";
        MeshGammaRightBox.Text = project?.Settings.Preprocessing.MeshGammaRight ?? "0.2";
        MaxInstancesBox.Text = project?.Settings.NumCalc.MaxInstances ?? "1";
        MaxCpuLoadBox.Text = project?.Settings.NumCalc.MaxCpuLoad ?? "90";
        UvBox.Text = environment.UvExecutable;
        NumCalcBox.Text = environment.NumCalcExecutable;
        MeshGradingBox.Text = environment.MeshGradingExecutable;
        ExternalBox.Text = environment.ExternalDir;
        SelectModel(project);
        loading = false;
        RefreshEnvironmentStatus();
    }

    void RefreshModelOptions()
    {
        ModelPicker.Items.Clear();
        var resourceDir = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        if (Directory.Exists(resourceDir))
        {
            foreach (var file in Directory.GetFiles(resourceDir, "*.y*ml").OrderBy(Path.GetFileName))
                ModelPicker.Items.Add(ModelName(file));
        }
    }

    void SelectModel(ProjectRecord? project)
    {
        if (project == null)
            return;
        var name = ModelName(project.Settings.Inference.ModelConfig);
        ModelPicker.SelectedItem = ModelPicker.Items.Cast<string>().FirstOrDefault(x => x == name) ?? ModelPicker.Items.Cast<string>().FirstOrDefault();
    }

    string ModelName(string path)
    {
        var stem = Path.GetFileNameWithoutExtension(path);
        return stem.StartsWith("Local ", StringComparison.OrdinalIgnoreCase) ? stem[6..] : stem;
    }

    void ProjectSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        Persist();
        LoadSelectedProject();
        ResetViewer();
        RefreshArtifacts();
    }

    void ProjectEdited(object sender, RoutedEventArgs e)
    {
        if (loading || SelectedProject == null)
            return;
        var project = SelectedProject;
        project.Name = ProjectNameBox.Text;
        project.LeftEar = LeftEarBox.Text;
        project.RightEar = RightEarBox.Text;
        project.SaveLocation = SaveLocationBox.Text;
        project.InputHandling = CopyInputsBox.IsChecked == true ? InputHandling.Copy : InputHandling.Reference;
        project.Settings.Inference.UsePredictionsForPreprocessing = UsePredictionsBox.IsChecked == true;
        project.Settings.Preprocessing.EvaluationGrid = string.IsNullOrWhiteSpace(EvaluationGridBox.Text) ? null : EvaluationGridBox.Text;
        project.Settings.Preprocessing.UseCustomHeadRadius = UseHeadRadiusBox.IsChecked == true;
        project.Settings.Preprocessing.HeadRadius = string.IsNullOrWhiteSpace(HeadRadiusBox.Text) ? null : HeadRadiusBox.Text;
        project.Settings.Preprocessing.MinFrequency = MinFrequencyBox.Text;
        project.Settings.Preprocessing.MaxFrequency = MaxFrequencyBox.Text;
        project.Settings.Preprocessing.FrequencyStepCount = FrequencyStepsBox.Text;
        project.Settings.Preprocessing.MeshMinEdgeLength = MeshMinEdgeBox.Text;
        project.Settings.Preprocessing.MeshMaxEdgeLength = MeshMaxEdgeBox.Text;
        project.Settings.Preprocessing.MeshMaxError = MeshMaxErrorBox.Text;
        project.Settings.Preprocessing.MeshGammaLeft = MeshGammaLeftBox.Text;
        project.Settings.Preprocessing.MeshGammaRight = MeshGammaRightBox.Text;
        project.Settings.NumCalc.MaxInstances = MaxInstancesBox.Text;
        project.Settings.NumCalc.MaxCpuLoad = MaxCpuLoadBox.Text;
        Persist();
        RefreshProjectList();
        RefreshArtifacts();
    }

    void EnvironmentEdited(object sender, RoutedEventArgs e)
    {
        if (loading)
            return;
        environment.UvExecutable = UvBox.Text;
        environment.NumCalcExecutable = NumCalcBox.Text;
        environment.MeshGradingExecutable = MeshGradingBox.Text;
        environment.ExternalDir = ExternalBox.Text;
        Persist();
        RefreshEnvironmentStatus();
    }

    void ModelSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || SelectedProject == null || ModelPicker.SelectedItem is not string model)
            return;
        var resourceDir = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        SelectedProject.Settings.Inference.ModelConfig = Path.Combine(resourceDir, $"Local {model}.yaml");
        SelectedProject.Settings.Inference.ModelCheckpoint = Path.Combine(resourceDir, $"Local {model}.pth");
        Persist();
    }

    void CreateProjectClicked(object sender, RoutedEventArgs e) => CreateProject();

    void CreateProject()
    {
        var project = NewProject(projects.Count + 1);
        projects.Add(project);
        failedStages[project.Id] = [];
        ProjectList.SelectedItem = project;
        Persist();
        RefreshProjectList();
    }

    ProjectRecord NewProject(int index)
    {
        var resourceDir = Path.Combine(packageRoot, "HRTFCalculation", "Inference", "resources");
        return new ProjectRecord
        {
            Name = $"Project {index}",
            Settings = new ProjectSettings
            {
                Inference = new InferenceSettings
                {
                    ModelConfig = Path.Combine(resourceDir, "Local 9 Views.yaml"),
                    ModelCheckpoint = Path.Combine(resourceDir, "Local 9 Views.pth")
                }
            }
        };
    }

    void RemoveProjectClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedProject == null)
            return;
        StopProject(SelectedProject);
        projects.Remove(SelectedProject);
        if (projects.Count == 0)
            CreateProject();
        else
            ProjectList.SelectedIndex = 0;
        Persist();
        RefreshProjectList();
    }

    void BrowseLeftEarClicked(object sender, RoutedEventArgs e) => BrowseFile(LeftEarBox, "Mesh files|*.stl;*.ply|All files|*.*");
    void BrowseRightEarClicked(object sender, RoutedEventArgs e) => BrowseFile(RightEarBox, "Mesh files|*.stl;*.ply|All files|*.*");
    void BrowseUvClicked(object sender, RoutedEventArgs e) => BrowseFile(UvBox, "uv|uv.exe|Executables|*.exe|All files|*.*");
    void BrowseNumCalcClicked(object sender, RoutedEventArgs e) => BrowseFile(NumCalcBox, "NumCalc|NumCalc.exe|Executables|*.exe|All files|*.*");
    void BrowseMeshGradingClicked(object sender, RoutedEventArgs e) => BrowseFile(MeshGradingBox, "Mesh grading|hrtf_mesh_grading.exe|Executables|*.exe|All files|*.*");
    void BrowseSaveLocationClicked(object sender, RoutedEventArgs e) => BrowseFolder(SaveLocationBox);
    void BrowseEvaluationGridClicked(object sender, RoutedEventArgs e) => BrowseFolder(EvaluationGridBox);
    void BrowseExternalClicked(object sender, RoutedEventArgs e) => BrowseFolder(ExternalBox);

    void BrowseFile(System.Windows.Controls.TextBox box, string filter)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = filter, CheckFileExists = false };
        if (dialog.ShowDialog(this) == true)
            box.Text = dialog.FileName;
    }

    void BrowseFolder(System.Windows.Controls.TextBox box)
    {
        using var dialog = new Forms.FolderBrowserDialog { SelectedPath = Directory.Exists(box.Text) ? box.Text : "" };
        if (dialog.ShowDialog() == Forms.DialogResult.OK)
            box.Text = dialog.SelectedPath;
    }

    void RefreshArtifacts()
    {
        artifacts.Clear();
        if (SelectedProject != null)
        {
            foreach (var artifact in ArtifactsFor(SelectedProject).Where(a => a.Exists))
                artifacts.Add(artifact);
        }
        RefreshProjectList();
    }

    List<Artifact> ArtifactsFor(ProjectRecord project)
    {
        var output = project.SaveLocation;
        var settings = project.Settings.Inference;
        var list = new List<Artifact>
        {
            new("Input left ear", project.LeftEar),
            new("Input right ear", project.RightEar),
            new("Left simulation mesh", Path.Combine(output, "intermediates", "left", "graded_head.ply")),
            new("Right simulation mesh", Path.Combine(output, "intermediates", "right", "graded_head.ply")),
            new("Horizontal HRTF plot", Path.Combine(output, "HRTF", "HRIR_EvalGrid_merged_3D_horizontal_plane.jpeg")),
            new("Median HRTF plot", Path.Combine(output, "HRTF", "HRIR_EvalGrid_merged_3D_median_plane.jpeg"))
        };
        AddMeshFolder(list, "Generated left ear", Path.Combine(output, settings.PredictionLeftFolder));
        AddMeshFolder(list, "Generated right ear", Path.Combine(output, settings.PredictionRightFolder));
        return list;
    }

    void AddMeshFolder(List<Artifact> list, string title, string folder)
    {
        if (!Directory.Exists(folder))
            return;
        var files = Directory.GetFiles(folder).Where(IsMesh).OrderBy(x => x).ToList();
        if (files.Count == 1)
        {
            list.Add(new Artifact(title, files[0]));
            return;
        }
        foreach (var file in files)
            list.Add(new Artifact($"{title} - {Path.GetFileNameWithoutExtension(file)}", file));
    }

    void ArtifactSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ArtifactPicker.SelectedItem is not Artifact artifact)
            return;
        OpenArtifact(artifact);
    }

    void OpenArtifact(Artifact artifact)
    {
        SelectedArtifactText.Text = artifact.Path;
        ResetViewer();
        if (artifact.IsImage)
        {
            ImagePreview.Source = new BitmapImage(new Uri(artifact.Path));
            ImagePreview.Visibility = Visibility.Visible;
            ViewerPlaceholder.Visibility = Visibility.Collapsed;
        }
        else if (artifact.IsMesh)
        {
            try
            {
                var model = MeshLoader.Load(artifact.Path);
                MeshViewport.Children.Add(new ModelVisual3D { Content = model });
                ResetMeshCamera();
                MeshControlsHint.Visibility = Visibility.Visible;
                ViewerPlaceholder.Visibility = Visibility.Collapsed;
            }
            catch (Exception error)
            {
                AppendLog($"Cannot open mesh: {error.Message}");
            }
        }
        else
        {
            if (artifact.IsText)
            {
                try
                {
                    LogText.Text = File.ReadAllText(artifact.Path);
                    ViewerPlaceholder.Text = Path.GetFileName(artifact.Path);
                }
                catch (Exception error)
                {
                    AppendLog($"Cannot open artifact: {error.Message}");
                }
            }
            else
            {
                ViewerPlaceholder.Text = $"{Path.GetFileName(artifact.Path)} selected";
            }
        }
    }

    void ResetViewer()
    {
        while (MeshViewport.Children.Count > 2)
            MeshViewport.Children.RemoveAt(2);
        ImagePreview.Source = null;
        ImagePreview.Visibility = Visibility.Collapsed;
        MeshControlsHint.Visibility = Visibility.Collapsed;
        ViewerPlaceholder.Text = "No artifact selected";
        ViewerPlaceholder.Visibility = Visibility.Visible;
        SelectedArtifactText.Text = "Select an artifact";
    }

    void MeshViewportMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (MeshViewport.Children.Count <= 2)
            return;
        rotatingMesh = true;
        lastMeshPointer = e.GetPosition(MeshViewport);
        MeshViewport.CaptureMouse();
        e.Handled = true;
    }

    void MeshViewportMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        StopMeshRotation();
        e.Handled = true;
    }

    void MeshViewportMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
            StopMeshRotation();
    }

    void MeshViewportMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!rotatingMesh || e.LeftButton != MouseButtonState.Pressed)
            return;

        var pointer = e.GetPosition(MeshViewport);
        meshYaw += (pointer.X - lastMeshPointer.X) * 0.45;
        meshPitch = Math.Clamp(meshPitch - (pointer.Y - lastMeshPointer.Y) * 0.45, -89, 89);
        lastMeshPointer = pointer;
        UpdateMeshCamera();
    }

    void MeshViewportMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (MeshViewport.Children.Count <= 2)
            return;
        meshDistance = Math.Clamp(meshDistance * Math.Pow(0.88, e.Delta / 120.0), 80, 1200);
        UpdateMeshCamera();
        e.Handled = true;
    }

    void StopMeshRotation()
    {
        rotatingMesh = false;
        if (MeshViewport.IsMouseCaptured)
            MeshViewport.ReleaseMouseCapture();
    }

    void ResetMeshCamera()
    {
        meshYaw = 0;
        meshPitch = 23;
        meshDistance = 305;
        UpdateMeshCamera();
    }

    void UpdateMeshCamera()
    {
        var yaw = meshYaw * Math.PI / 180;
        var pitch = meshPitch * Math.PI / 180;
        var horizontalDistance = meshDistance * Math.Cos(pitch);
        var position = new Point3D(
            horizontalDistance * Math.Sin(yaw),
            -horizontalDistance * Math.Cos(yaw),
            meshDistance * Math.Sin(pitch));
        MeshCamera.Position = position;
        MeshCamera.LookDirection = new Vector3D(-position.X, -position.Y, -position.Z);
        MeshCamera.UpDirection = new Vector3D(0, 0, 1);
    }

    void RunInferenceClicked(object sender, RoutedEventArgs e) => RunStage(Stage.Inference);
    void RunPreprocessingClicked(object sender, RoutedEventArgs e) => RunStage(Stage.Preprocessing);
    void RunNumCalcClicked(object sender, RoutedEventArgs e) => RunStage(Stage.Numcalc);
    void RunPostprocessingClicked(object sender, RoutedEventArgs e) => RunStage(Stage.Postprocessing);

    void RunNextClicked(object sender, RoutedEventArgs e)
    {
        var project = SelectedProject;
        if (project == null)
            return;
        var stage = Stage.GetValues().FirstOrDefault(stage => !StageIsComplete(stage, project), Stage.Postprocessing);
        RunStage(stage);
    }

    void RunStage(Stage stage)
    {
        var project = SelectedProject;
        if (project == null)
        {
            AppendLog("Create or select a project before running.");
            return;
        }
        if (runningProcesses.ContainsKey(project.Id))
        {
            AppendLog($"{project.Name} already has a running task.");
            return;
        }
        if (string.IsNullOrWhiteSpace(project.LeftEar) || string.IsNullOrWhiteSpace(project.RightEar) || string.IsNullOrWhiteSpace(project.SaveLocation))
        {
            AppendLog("Select a left ear mesh, right ear mesh, and save location before running.");
            return;
        }
        try
        {
            Directory.CreateDirectory(project.SaveLocation);
            var config = PrepareConfig(project);
            var bundledPython = BundledPythonExecutable();
            var executable = bundledPython ?? (File.Exists(environment.UvExecutable) ? environment.UvExecutable : "uv");
            var arguments = bundledPython != null
                ? $"-m HRTFCalculation.RunConfig --config {QuoteArgument(config)} --stage {stage.Value}"
                : $"run --no-sync python -m HRTFCalculation.RunConfig --config {QuoteArgument(config)} --stage {stage.Value}";
            var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments,
                WorkingDirectory = packageRoot,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            ApplyProcessEnvironment(process.StartInfo);
            process.OutputDataReceived += (_, args) => AppendLog(args.Data);
            process.ErrorDataReceived += (_, args) => AppendLog(args.Data);
            process.EnableRaisingEvents = true;
            runningProcesses[project.Id] = process;
            runningStages[project.Id] = stage;
            FailedStages(project.Id).Remove(stage);
            AppendLog($"Started {stage.Title} for {project.Name}");
            process.Exited += (_, _) => Dispatcher.BeginInvoke(() =>
            {
                var code = process.ExitCode;
                if (code != 0)
                    FailedStages(project.Id).Add(stage);
                runningProcesses.Remove(project.Id);
                runningStages.Remove(project.Id);
                AppendLog(code == 0 ? $"{stage.Title} finished for {project.Name}" : $"{stage.Title} for {project.Name} exited with status {code}");
                process.Dispose();
                RefreshArtifacts();
            });
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception error)
        {
            FailedStages(project.Id).Add(stage);
            runningProcesses.Remove(project.Id);
            runningStages.Remove(project.Id);
            AppendLog($"Could not start {stage.Title}: {error.Message}");
            RefreshArtifacts();
        }
    }

    void SetupEnvironmentClicked(object sender, RoutedEventArgs e)
    {
        if (runningProcesses.Values.Any())
        {
            AppendLog("Stop running tasks before setting up the environment.");
            return;
        }
        var executable = File.Exists(environment.UvExecutable) ? environment.UvExecutable : "uv";
        var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = executable,
            Arguments = "sync",
            WorkingDirectory = packageRoot,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        ApplyProcessEnvironment(process.StartInfo);
        process.OutputDataReceived += (_, args) => AppendLog(args.Data);
        process.ErrorDataReceived += (_, args) => AppendLog(args.Data);
        process.EnableRaisingEvents = true;
        AppendLog("Setting up Python environment");
        process.Exited += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            AppendLog(process.ExitCode == 0 ? "Environment setup finished" : $"Environment setup exited with status {process.ExitCode}");
            process.Dispose();
            RefreshEnvironmentStatus();
        });
        try
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception error)
        {
            AppendLog($"Could not start environment setup: {error.Message}");
        }
    }

    void ApplyProcessEnvironment(ProcessStartInfo startInfo)
    {
        startInfo.Environment["PINNA2HRTF_ROOT"] = Directory.GetParent(packageRoot)?.FullName ?? packageRoot;
        startInfo.Environment["UV_CACHE_DIR"] = Path.Combine(appData, "Cache", "uv");
        startInfo.Environment["MPLCONFIGDIR"] = Path.Combine(appData, "Cache", "matplotlib");
        startInfo.Environment["PYTHONPATH"] = packageRoot;
        startInfo.Environment["PATH"] = Path.Combine(environment.ExternalDir, "bin") + Path.PathSeparator + (startInfo.Environment.TryGetValue("PATH", out var path) ? path : "");
    }

    string? BundledPythonExecutable()
    {
        var candidate = Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        return File.Exists(candidate) ? candidate : null;
    }

    string PrepareConfig(ProjectRecord project)
    {
        var prepared = Clone(project);
        if (prepared.InputHandling == InputHandling.Copy)
        {
            prepared.LeftEar = CopyInput(project.LeftEar, Path.Combine(project.SaveLocation, "Input", "Left"));
            prepared.RightEar = CopyInput(project.RightEar, Path.Combine(project.SaveLocation, "Input", "Right"));
        }
        var config = Path.Combine(project.SaveLocation, ".pinna2hrtf_native_run.yaml");
        File.WriteAllText(config, Yaml(prepared), Encoding.UTF8);
        return config;
    }

    ProjectRecord Clone(ProjectRecord project) => JsonSerializer.Deserialize<ProjectRecord>(JsonSerializer.Serialize(project, jsonOptions), jsonOptions) ?? project;

    string CopyInput(string path, string folder)
    {
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, Path.GetFileName(path));
        if (Path.GetFullPath(path) == Path.GetFullPath(target))
            return path;
        File.Copy(path, target, true);
        return target;
    }

    string Yaml(ProjectRecord project)
    {
        var output = project.SaveLocation;
        var inference = project.Settings.Inference;
        var preprocessing = project.Settings.Preprocessing;
        var numcalc = project.Settings.NumCalc;
        var evaluationGrid = string.IsNullOrWhiteSpace(preprocessing.EvaluationGrid) ? "Default" : preprocessing.EvaluationGrid;
        var headRadius = preprocessing.UseCustomHeadRadius == true ? $"  head_radius: {YamlNumber(preprocessing.HeadRadius) ?? "0"}\n" : "";
        return $"""
paths:
  left_ear: {YamlScalar(project.LeftEar)}
  right_ear: {YamlScalar(project.RightEar)}
  output_dir: {YamlScalar(project.SaveLocation)}
  external_deps_dir: {YamlScalar(environment.ExternalDir)}
  numcalc_executable: {YamlScalar(environment.NumCalcExecutable)}
  mesh_grading_executable: {YamlScalar(environment.MeshGradingExecutable)}
  evaluation_grid: {YamlScalar(evaluationGrid)}
inference:
  enabled: true
  model_config_file: {YamlScalar(inference.ModelConfig)}
  model_checkpoint: {YamlScalar(inference.ModelCheckpoint)}
  target_left_folder: {YamlScalar(inference.TargetLeftFolder)}
  target_right_folder: {YamlScalar(inference.TargetRightFolder)}
  prediction_left_folder: {YamlScalar(inference.PredictionLeftFolder)}
  prediction_right_folder: {YamlScalar(inference.PredictionRightFolder)}
  prediction_parameters_left_folder: Prediction Parameters Left
  prediction_parameters_right_folder: Prediction Parameters Right
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
{headRadius}  seam_smoothing_iterations: 5
  seam_smoothing_factor: 0.35
  mesh_min_edge_length: {preprocessing.MeshMinEdgeLength}
  mesh_max_edge_length: {preprocessing.MeshMaxEdgeLength}
  mesh_max_error: {preprocessing.MeshMaxError}
  mesh_gamma_left: {preprocessing.MeshGammaLeft}
  mesh_gamma_right: {preprocessing.MeshGammaRight}
  mesh_hole_size: 0.2
  source_type_left: Left ear
  source_type_right: Right ear
  title: {YamlScalar(project.Name)}
  method: ML-FMM BEM
  min_frequency: {preprocessing.MinFrequency}
  max_frequency: {preprocessing.MaxFrequency}
  frequency_vector_type: Num steps
  frequency_step_count: {preprocessing.FrequencyStepCount}
  compute_hrirs: true
  pictures: false
  reference: true
  unit: mm
  speed_of_sound: "346.18"
  air_density: "1.1839"
  material_search_paths: None
  source_assignment_tolerance: 2.0
numcalc:
  enabled: false
  mode: local
  max_instances: {numcalc.MaxInstances}
  max_cpu_load: {numcalc.MaxCpuLoad}
postprocessing:
  enabled: false
  output_sofa_dir: {YamlScalar(Path.Combine(output, "HRTF"))}
  overwrite: true
ui:
  mesh_background: white
  show_axes: true
""";
    }

    string YamlScalar(string value) => $"'{value.Replace("'", "''")}'";
    string Bool(bool value) => value ? "true" : "false";
    string? YamlNumber(string? value) => double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _) ? value : null;
    string QuoteArgument(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    void StopClicked(object sender, RoutedEventArgs e)
    {
        if (SelectedProject != null)
            StopProject(SelectedProject);
    }

    void StopProject(ProjectRecord project)
    {
        if (runningProcesses.TryGetValue(project.Id, out var process))
        {
            TryTerminate(process);
            AppendLog("Termination requested.");
        }
    }

    void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(true);
        }
        catch
        {
        }
    }

    void RefreshClicked(object sender, RoutedEventArgs e) => RefreshArtifacts();

    void ResetOutputsClicked(object sender, RoutedEventArgs e)
    {
        var project = SelectedProject;
        if (project == null || runningProcesses.ContainsKey(project.Id))
            return;
        var names = new[]
        {
            project.Settings.Inference.TargetLeftFolder,
            project.Settings.Inference.TargetRightFolder,
            project.Settings.Inference.PredictionLeftFolder,
            project.Settings.Inference.PredictionRightFolder,
            "Prediction Parameters Left",
            "Prediction Parameters Right",
            "intermediates",
            "Projects",
            "HRTF",
            "Results Inference.csv",
            ".pinna2hrtf_native_run.yaml"
        };
        foreach (var name in names)
        {
            var path = Path.Combine(project.SaveLocation, name);
            if (ContainsPath(path, project.LeftEar) || ContainsPath(path, project.RightEar))
            {
                AppendLog($"Skipped reset of {path} because it contains a configured input mesh.");
                continue;
            }
            try
            {
                if (Directory.Exists(path))
                    Directory.Delete(path, true);
                else if (File.Exists(path))
                    File.Delete(path);
            }
            catch (Exception error)
            {
                AppendLog($"Could not reset {path}: {error.Message}");
            }
        }
        failedStages[project.Id] = [];
        ResetViewer();
        RefreshArtifacts();
        AppendLog($"Reset generated outputs in {project.SaveLocation}");
    }

    bool ContainsPath(string parent, string child)
    {
        if (string.IsNullOrWhiteSpace(parent) || string.IsNullOrWhiteSpace(child))
            return false;
        var parentPath = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var childPath = Path.GetFullPath(child);
        return childPath.Equals(parentPath, StringComparison.OrdinalIgnoreCase) || childPath.StartsWith(parentPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    void ClearLogClicked(object sender, RoutedEventArgs e)
    {
        LogText.Text = "";
        LogSummaryText.Text = "Live Log";
    }

    void AppendLog(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return;
        void Append()
        {
            LogText.AppendText((LogText.Text.Length == 0 ? "" : Environment.NewLine) + text);
            LogText.ScrollToEnd();
            LogSummaryText.Text = text;
        }
        if (Dispatcher.CheckAccess())
            Append();
        else
            Dispatcher.BeginInvoke(Append);
    }

    void RefreshEnvironmentStatus()
    {
        var uv = File.Exists(environment.UvExecutable) ? "uv found" : "uv missing";
        var numcalc = File.Exists(environment.NumCalcExecutable) ? "NumCalc found" : "NumCalc missing";
        var grading = File.Exists(environment.MeshGradingExecutable) ? "mesh grading found" : "mesh grading missing";
        EnvironmentStatusText.Text = $"{uv}; {numcalc}; {grading}";
    }

    string ArtifactSummary(ProjectRecord project)
    {
        if (StageIsComplete(Stage.Postprocessing, project))
            return "Postprocessed";
        if (StageIsComplete(Stage.Numcalc, project))
            return "Solved";
        if (StageIsComplete(Stage.Preprocessing, project))
            return "Projects ready";
        if (StageIsComplete(Stage.Inference, project))
            return "Inference ready";
        return string.IsNullOrWhiteSpace(project.SaveLocation) ? "" : Path.GetFileName(project.SaveLocation);
    }

    bool StageIsComplete(Stage stage, ProjectRecord project)
    {
        var output = project.SaveLocation;
        if (stage == Stage.Inference)
            return ContainsMesh(Path.Combine(output, project.Settings.Inference.PredictionLeftFolder)) && ContainsMesh(Path.Combine(output, project.Settings.Inference.PredictionRightFolder));
        if (stage == Stage.Preprocessing)
            return File.Exists(Path.Combine(output, "Projects", "Left", "parameters.json")) && File.Exists(Path.Combine(output, "Projects", "Right", "parameters.json")) && File.Exists(Path.Combine(output, "intermediates", "left", "graded_head.ply")) && File.Exists(Path.Combine(output, "intermediates", "right", "graded_head.ply"));
        if (stage == Stage.Numcalc)
            return ContainsNumCalcOutput(Path.Combine(output, "Projects", "Left", "NumCalc", "source_1", "be.out")) && ContainsNumCalcOutput(Path.Combine(output, "Projects", "Right", "NumCalc", "source_1", "be.out"));
        if (stage == Stage.Postprocessing)
            return Directory.Exists(Path.Combine(output, "HRTF")) && Directory.GetFiles(Path.Combine(output, "HRTF"), "*.sofa").Any();
        return false;
    }

    bool ContainsMesh(string folder) => Directory.Exists(folder) && Directory.GetFiles(folder).Any(IsMesh);
    bool ContainsNumCalcOutput(string folder) => Directory.Exists(folder) && Directory.GetFiles(folder).Any(x => Path.GetFileName(x).StartsWith("be.", StringComparison.OrdinalIgnoreCase));
    bool IsMesh(string path) => string.Equals(Path.GetExtension(path), ".stl", StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetExtension(path), ".ply", StringComparison.OrdinalIgnoreCase);

    HashSet<Stage> FailedStages(Guid id)
    {
        if (!failedStages.TryGetValue(id, out var set))
        {
            set = [];
            failedStages[id] = set;
        }
        return set;
    }
}

record Artifact(string Title, string Path)
{
    public bool Exists => File.Exists(Path);
    public bool IsMesh => string.Equals(System.IO.Path.GetExtension(Path), ".stl", StringComparison.OrdinalIgnoreCase) || string.Equals(System.IO.Path.GetExtension(Path), ".ply", StringComparison.OrdinalIgnoreCase);
    public bool IsImage => new[] { ".jpg", ".jpeg", ".png", ".bmp", ".gif" }.Contains(System.IO.Path.GetExtension(Path).ToLowerInvariant());
    public bool IsText => new[] { ".txt", ".csv", ".json", ".yaml", ".yml", ".log", ".out" }.Contains(System.IO.Path.GetExtension(Path).ToLowerInvariant());
}

record Stage(string Value, string Title)
{
    public static readonly Stage Inference = new("inference", "Inference");
    public static readonly Stage Preprocessing = new("preprocessing", "Preprocessing");
    public static readonly Stage Numcalc = new("numcalc", "NumCalc");
    public static readonly Stage Postprocessing = new("postprocessing", "Postprocess");
    public static Stage[] GetValues() => [Inference, Preprocessing, Numcalc, Postprocessing];
}

enum InputHandling { Copy, Reference }

class ProjectRegistry
{
    public List<ProjectRecord> Projects { get; set; } = [];
    public Guid? SelectedProjectID { get; set; }
    public EnvironmentConfig Environment { get; set; } = new();
}

class EnvironmentConfig
{
    public string UvExecutable { get; set; } = "";
    public string NumCalcExecutable { get; set; } = "";
    public string MeshGradingExecutable { get; set; } = "";
    public string ExternalDir { get; set; } = "";
    [JsonIgnore] public bool IsEmpty => string.IsNullOrWhiteSpace(UvExecutable) && string.IsNullOrWhiteSpace(NumCalcExecutable) && string.IsNullOrWhiteSpace(MeshGradingExecutable) && string.IsNullOrWhiteSpace(ExternalDir);
}

class ProjectRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string LeftEar { get; set; } = "";
    public string RightEar { get; set; } = "";
    public string SaveLocation { get; set; } = "";
    public InputHandling InputHandling { get; set; } = InputHandling.Copy;
    public ProjectSettings Settings { get; set; } = new();
    [JsonIgnore] public string DisplayTitle { get; set; } = "";
}

class ProjectSettings
{
    public InferenceSettings Inference { get; set; } = new();
    public PreprocessingSettings Preprocessing { get; set; } = new();
    public NumCalcSettings NumCalc { get; set; } = new();
}

class InferenceSettings
{
    public string ModelConfig { get; set; } = "";
    public string ModelCheckpoint { get; set; } = "";
    public string TargetLeftFolder { get; set; } = "Target STL Left";
    public string TargetRightFolder { get; set; } = "Target STL Right";
    public string PredictionLeftFolder { get; set; } = "Prediction STL Left";
    public string PredictionRightFolder { get; set; } = "Prediction STL Right";
    public bool UsePredictionsForPreprocessing { get; set; } = true;
}

class PreprocessingSettings
{
    public string MinFrequency { get; set; } = "0";
    public string MaxFrequency { get; set; } = "24000";
    public string FrequencyStepCount { get; set; } = "129";
    public string? EvaluationGrid { get; set; }
    public string? HeadRadius { get; set; }
    public bool? UseCustomHeadRadius { get; set; }
    public string MeshMinEdgeLength { get; set; } = "0.5";
    public string MeshMaxEdgeLength { get; set; } = "10.0";
    public string MeshMaxError { get; set; } = "0.5";
    public string MeshGammaLeft { get; set; } = "0.15";
    public string MeshGammaRight { get; set; } = "0.2";
}

class NumCalcSettings
{
    public string MaxInstances { get; set; } = "1";
    public string MaxCpuLoad { get; set; } = "90";
}

static class MeshLoader
{
    public static Model3D Load(string path)
    {
        var mesh = string.Equals(Path.GetExtension(path), ".ply", StringComparison.OrdinalIgnoreCase) ? LoadPly(path) : LoadStl(path);
        Center(mesh);
        var material = new DiffuseMaterial(new SolidColorBrush(System.Windows.Media.Color.FromRgb(96, 145, 144)));
        return new GeometryModel3D(mesh, material) { BackMaterial = material };
    }

    static MeshGeometry3D LoadStl(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (LooksBinaryStl(bytes))
            return LoadBinaryStl(bytes);
        return LoadAsciiStl(File.ReadLines(path));
    }

    static bool LooksBinaryStl(byte[] bytes)
    {
        if (bytes.Length < 84)
            return false;
        var triangles = BitConverter.ToUInt32(bytes, 80);
        return 84L + triangles * 50L == bytes.Length;
    }

    static MeshGeometry3D LoadBinaryStl(byte[] bytes)
    {
        var mesh = new MeshGeometry3D();
        var count = checked((int)BitConverter.ToUInt32(bytes, 80));
        var offset = 84;
        for (var i = 0; i < count; i++)
        {
            offset += 12;
            var start = mesh.Positions.Count;
            for (var v = 0; v < 3; v++)
            {
                var x = BitConverter.ToSingle(bytes, offset);
                var y = BitConverter.ToSingle(bytes, offset + 4);
                var z = BitConverter.ToSingle(bytes, offset + 8);
                offset += 12;
                mesh.Positions.Add(new Point3D(x, y, z));
            }
            mesh.TriangleIndices.Add(start);
            mesh.TriangleIndices.Add(start + 1);
            mesh.TriangleIndices.Add(start + 2);
            offset += 2;
        }
        return mesh;
    }

    static MeshGeometry3D LoadAsciiStl(IEnumerable<string> lines)
    {
        var mesh = new MeshGeometry3D();
        var vertices = new List<Point3D>();
        foreach (var line in lines)
        {
            var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 4 && parts[0].Equals("vertex", StringComparison.OrdinalIgnoreCase))
            {
                vertices.Add(new Point3D(Parse(parts[1]), Parse(parts[2]), Parse(parts[3])));
                if (vertices.Count == 3)
                {
                    var start = mesh.Positions.Count;
                    foreach (var vertex in vertices)
                        mesh.Positions.Add(vertex);
                    mesh.TriangleIndices.Add(start);
                    mesh.TriangleIndices.Add(start + 1);
                    mesh.TriangleIndices.Add(start + 2);
                    vertices.Clear();
                }
            }
        }
        return mesh;
    }

    static MeshGeometry3D LoadPly(string path)
    {
        using var reader = new StreamReader(path);
        var vertexCount = 0;
        var faceCount = 0;
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 3 && parts[0] == "element" && parts[1] == "vertex")
                vertexCount = int.Parse(parts[2], CultureInfo.InvariantCulture);
            if (parts.Length == 3 && parts[0] == "element" && parts[1] == "face")
                faceCount = int.Parse(parts[2], CultureInfo.InvariantCulture);
            if (line == "end_header")
                break;
        }
        var vertices = new List<Point3D>();
        for (var i = 0; i < vertexCount; i++)
        {
            line = reader.ReadLine() ?? "";
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            vertices.Add(new Point3D(Parse(parts[0]), Parse(parts[1]), Parse(parts[2])));
        }
        var mesh = new MeshGeometry3D();
        foreach (var vertex in vertices)
            mesh.Positions.Add(vertex);
        for (var i = 0; i < faceCount; i++)
        {
            line = reader.ReadLine() ?? "";
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(x => int.Parse(x, CultureInfo.InvariantCulture)).ToArray();
            if (parts.Length < 4)
                continue;
            for (var j = 2; j < parts[0]; j++)
            {
                mesh.TriangleIndices.Add(parts[1]);
                mesh.TriangleIndices.Add(parts[j]);
                mesh.TriangleIndices.Add(parts[j + 1]);
            }
        }
        return mesh;
    }

    static void Center(MeshGeometry3D mesh)
    {
        if (mesh.Positions.Count == 0)
            return;
        var minX = mesh.Positions.Min(p => p.X);
        var maxX = mesh.Positions.Max(p => p.X);
        var minY = mesh.Positions.Min(p => p.Y);
        var maxY = mesh.Positions.Max(p => p.Y);
        var minZ = mesh.Positions.Min(p => p.Z);
        var maxZ = mesh.Positions.Max(p => p.Z);
        var center = new Vector3D((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2);
        var scale = 180 / Math.Max(Math.Max(maxX - minX, maxY - minY), Math.Max(maxZ - minZ, 1));
        for (var i = 0; i < mesh.Positions.Count; i++)
        {
            var p = mesh.Positions[i] - center;
            mesh.Positions[i] = new Point3D(p.X * scale, p.Y * scale, p.Z * scale);
        }
    }

    static double Parse(string value) => double.Parse(value, CultureInfo.InvariantCulture);
}
