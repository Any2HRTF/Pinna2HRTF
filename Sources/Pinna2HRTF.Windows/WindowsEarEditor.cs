using HelixToolkit;
using HelixToolkit.Maths;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text.Json;
using Windows.System;
using Vector3 = System.Numerics.Vector3;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    async Task EditPreparedEarAsync(string side)
    {
        var project = selectedProject;
        if (project == null || runningProcesses.ContainsKey(project.Id) || !project.Settings.ScanPreparation.Enabled) return;
        if (!ScanPreparationOutputsCurrent(project))
        {
            AppendLog("Run Scan Preparation successfully before reviewing a prepared ear.", project.Id);
            return;
        }
        var settings = project.Settings.ScanPreparation;
        var selected = side == "left" ? settings.PrepareLeft : settings.PrepareRight;
        if (!selected) return;
        var output = Path.Combine(project.SaveLocation, "Prepared", side == "left" ? "Left.stl" : "Right.stl");
        var report = Path.Combine(project.SaveLocation, "Prepared", "mesh_preparation.json");
        var destination = Path.Combine(project.SaveLocation, "MeshEdits", side == "left" ? "Left.stl" : "Right.stl");
        var reviewed = side == "left" ? settings.ReviewedLeft : settings.ReviewedRight;
        var source = EarReviewIsCurrent(project, side) && !string.IsNullOrWhiteSpace(reviewed) ? reviewed : output;
        string generation;
        try
        {
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(report));
            generation = document.RootElement.GetProperty("generation").GetString() ?? throw new InvalidDataException("Preparation generation is missing.");
        }
        catch (Exception error)
        {
            AppendLog("Cannot open prepared ear: " + error.Message, project.Id);
            return;
        }

        var resultPath = await ShowWindowsEarEditorAsync(source, output, destination, report, generation, side);
        if (resultPath == null) return;
        if (side == "left") settings.ReviewedLeft = resultPath; else settings.ReviewedRight = resultPath;
        project.Settings.Preprocessing.SourcePositionInputLeft = null;
        project.Settings.Preprocessing.SourcePositionInputRight = null;
        Persist();
        AppendLog($"Saved reviewed {side} ear: {Path.GetFileName(resultPath)}", project.Id);
        RememberSelectedArtifact(resultPath);
        RefreshPipelineStatus();
        RefreshArtifacts();
        var reviewedArtifact = artifacts.FirstOrDefault(artifact => SamePath(artifact.Path, resultPath));
        if (reviewedArtifact != null)
        {
            artifactPicker.SelectedItem = reviewedArtifact;
            OpenArtifact(reviewedArtifact);
        }
    }

    async Task<string?> ShowWindowsEarEditorAsync(string source, string preparedSource, string destination, string report, string generation, string side)
    {
        var workspace = Path.Combine(Path.GetTempPath(), "pinna-ear-edit-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workspace);
        var versions = new List<string>();
        var operations = new List<Dictionary<string, object>>();
        var selectedFaces = new HashSet<int>();
        var toolBeforeNavigate = "Select Faces";
        var currentIndex = 0;
        var faceCount = 0;
        var originalSha = "";
        string? savedPath = null;
        var isBusy = true;
        var navigate = false;
        var throughMesh = false;
        var addSelection = false;
        var flipPlane = false;
        var fitPlane = true;
        var offset = 0d;
        var normal = Vector3.UnitY;
        var planePreviewMarkers = new List<MeshGeometryModel3D>();
        var manualWidth = 40d;
        var manualHeight = 40d;
        var mesh = (MeshData?)null;
        var activePointer = uint.MaxValue;
        var pointerStart = default(Windows.Foundation.Point);
        var lasso = new List<Windows.Foundation.Point>();
        MeshGeometryModel3D? meshVisualLocal = null;
        MeshGeometryModel3D? selectionVisual = null;
        MeshGeometryModel3D? planeVisual = null;

        var dialog = new ContentDialog
        {
            Title = $"Edit {side} ear",
            PrimaryButtonText = "Save Reviewed Ear",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Root.XamlRoot,
            IsPrimaryButtonEnabled = false
        };
        var root = new Grid { Width = 1160, Height = 690, ColumnSpacing = 0 };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var viewerGrid = new Grid { Background = viewerBackgroundBrush };
        var viewport = new Viewport3DX
        {
            IsRotationEnabled = false, IsPanEnabled = false, IsMoveEnabled = false, IsZoomEnabled = true,
            UseDefaultGestures = true, InputController = new MeshInputController(), EnableMouseButtonHitTest = true,
            ShowCoordinateSystem = false, ShowViewCube = false, ModelUpDirection = Vector3.UnitZ,
            BackgroundColor = ColorHelper.FromArgb(255, 237, 243, 242), EffectsManager = new DefaultEffectsManager()
        };
        viewport.Items.Add(new AmbientLight3D { Color = Colors.White });
        viewport.Items.Add(new DirectionalLight3D { Color = Colors.White, Direction = new Vector3(-0.4f, -0.65f, -0.55f) });
        viewport.Items.Add(new DirectionalLight3D { Color = ColorHelper.FromArgb(205, 220, 235, 255), Direction = new Vector3(0.65f, 0.25f, -0.35f) });
        viewerGrid.Children.Add(viewport);
        var lassoCanvas = new Canvas { Background = new SolidColorBrush(Colors.Transparent), IsHitTestVisible = true };
        viewerGrid.Children.Add(lassoCanvas);
        var navButton = new Button
        {
            Content = "Navigate",
            FontSize = 12,
            Foreground = viewerHintTextBrush,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 4, 8, 4),
            MinWidth = 0,
            MinHeight = 0,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(16),
            Visibility = Visibility.Visible
        };
        var navHost = new Border { CornerRadius = new CornerRadius(5), Background = viewerHintBackgroundBrush, Child = navButton, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(16), IsHitTestVisible = true };
        navButton.Margin = new Thickness(0);
        ToolTipService.SetToolTip(navButton, "Temporarily switch to camera navigation (Space)");
        viewerGrid.Children.Add(navHost);
        var resetButton = new Button { Content = "Reset view", FontSize = 12, Foreground = viewerHintTextBrush, Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 4, 8, 4), MinWidth = 0, MinHeight = 0 };
        var resetHost = new Border { CornerRadius = new CornerRadius(5), Background = viewerHintBackgroundBrush, Child = resetButton, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(16) };
        viewerGrid.Children.Add(resetHost);
        Grid.SetColumn(viewerGrid, 0);
        Grid.SetRow(viewerGrid, 0);
        root.Children.Add(viewerGrid);
        var panel = new StackPanel { Spacing = 10, Margin = new Thickness(16), Width = 300 };
        var toolRow = new Grid { ColumnSpacing = 6 };
        toolRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var selectToolButton = new Button { Content = "Select Faces", IsEnabled = false };
        var planeToolButton = new Button { Content = "Cutting Plane" };
        Grid.SetColumn(planeToolButton, 1);
        toolRow.Children.Add(selectToolButton); toolRow.Children.Add(planeToolButton);
        panel.Children.Add(new TextBlock { Text = Path.GetFileName(source) + " · Original mesh is preserved", FontSize = 12, Foreground = mutedTextBrush, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(toolRow);
        var selectionPanel = new StackPanel { Spacing = 8 };
        selectionPanel.Children.Add(new TextBlock { Text = "Draw a closed lasso around faces to remove. Click toggles one face. Red faces are selected.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        selectionPanel.Children.Add(new TextBlock { Text = "Triangle edges stay visible to make face selection easier.", TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.8 });
        var throughToggle = new CheckBox { Content = "Select through mesh" };
        var addToggle = new CheckBox { Content = "Add to current selection" };
        selectionPanel.Children.Add(throughToggle); selectionPanel.Children.Add(addToggle);
        var selectionStatus = new TextBlock { Text = "0 faces selected", FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        selectionPanel.Children.Add(selectionStatus);
        var deleteButton = new Button { Content = "Delete Selected Faces", IsEnabled = false };
        var clearButton = new Button { Content = "Clear Selection", IsEnabled = false };
        selectionPanel.Children.Add(deleteButton); selectionPanel.Children.Add(clearButton);
        var planePanel = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
        planePanel.Children.Add(new TextBlock { Text = "The preview fits the mesh at the cut. The cut extends through the mesh; the red side is removed.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        var normalBoxes = new[] { new TextBox { Text = "0", PlaceholderText = "X", Header = "Normal X" }, new TextBox { Text = "1", PlaceholderText = "Y", Header = "Normal Y" }, new TextBox { Text = "0", PlaceholderText = "Z", Header = "Normal Z" } };
        var axisPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var axisButtons = new List<Button>();
        foreach (var axis in new[] { "X", "Y", "Z" })
        {
            var button = new Button { Content = axis, MinWidth = 38 };
            button.Click += (_, _) =>
            {
                normalBoxes[0].Text = axis == "X" ? "1" : "0";
                normalBoxes[1].Text = axis == "Y" ? "1" : "0";
                normalBoxes[2].Text = axis == "Z" ? "1" : "0";
                RefreshPlane();
            };
            axisButtons.Add(button); axisPanel.Children.Add(button);
        }
        planePanel.Children.Add(axisPanel);
        var normalPanel = new Grid { ColumnSpacing = 5 };
        for (var i = 0; i < 3; i++) normalPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < normalBoxes.Length; i++) { Grid.SetColumn(normalBoxes[i], i); normalPanel.Children.Add(normalBoxes[i]); normalBoxes[i].TextChanged += (_, _) => { if (TryReadNormal()) RefreshPlane(); }; }
        planePanel.Children.Add(normalPanel);
        var offsetSlider = new Slider { Minimum = -90, Maximum = 90, Value = 0, StepFrequency = 0.25 };
        var offsetLabel = new TextBlock { Text = "Offset: 0.00 mm" };
        planePanel.Children.Add(offsetLabel); planePanel.Children.Add(offsetSlider);
        var fitToggle = new CheckBox { Content = "Fit plane preview to mesh", IsChecked = true };
        var sizePanel = new Grid { ColumnSpacing = 6, Visibility = Visibility.Collapsed };
        sizePanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        sizePanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var widthBox = new TextBox { Header = "Width (mm)", Text = "40" };
        var heightBox = new TextBox { Header = "Height (mm)", Text = "40" };
        Grid.SetColumn(heightBox, 1); sizePanel.Children.Add(widthBox); sizePanel.Children.Add(heightBox);
        var flipToggle = new CheckBox { Content = "Flip kept side" };
        planePanel.Children.Add(fitToggle); planePanel.Children.Add(sizePanel); planePanel.Children.Add(flipToggle);
        var cutButton = new Button { Content = "Apply Open Cut" };
        planePanel.Children.Add(cutButton);
        panel.Children.Add(selectionPanel); panel.Children.Add(planePanel);
        var historyRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var undoButton = new Button { Content = "Undo", IsEnabled = false };
        var redoButton = new Button { Content = "Redo", IsEnabled = false };
        historyRow.Children.Add(undoButton); historyRow.Children.Add(redoButton); panel.Children.Add(historyRow);
        var largestButton = new Button { Content = "Keep Largest Component" };
        panel.Children.Add(largestButton);
        var message = new TextBlock { Text = "Loading mesh…", TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = mutedTextBrush };
        panel.Children.Add(message);
        var errorText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = new SolidColorBrush(Colors.Firebrick), Visibility = Visibility.Collapsed };
        panel.Children.Add(errorText);
        var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(scroll, 1); root.Children.Add(scroll);
        dialog.Content = root;

        void UpdateControls()
        {
            var planeMode = planePanel.Visibility == Visibility.Visible;
            selectToolButton.IsEnabled = !isBusy;
            planeToolButton.IsEnabled = !isBusy;
            selectionPanel.Visibility = planeMode || navigate ? Visibility.Collapsed : Visibility.Visible;
            planePanel.Visibility = planeMode ? Visibility.Visible : Visibility.Collapsed;
            sizePanel.Visibility = planeMode && !fitPlane ? Visibility.Visible : Visibility.Collapsed;
            toolRow.Visibility = navigate ? Visibility.Collapsed : Visibility.Visible;
            navHost.Visibility = planeMode ? Visibility.Collapsed : Visibility.Visible;
            lassoCanvas.IsHitTestVisible = !planeMode && !navigate && !isBusy;
            viewport.IsRotationEnabled = planeMode || navigate;
            viewport.IsPanEnabled = planeMode || navigate;
            viewport.IsZoomEnabled = true;
            navButton.Content = "Navigate";
            navButton.Background = navigate ? new SolidColorBrush(ColorHelper.FromArgb(35, 48, 112, 110)) : new SolidColorBrush(Colors.Transparent);
            selectToolButton.Background = planeMode ? new SolidColorBrush(Colors.Transparent) : new SolidColorBrush(ColorHelper.FromArgb(35, 48, 112, 110));
            planeToolButton.Background = planeMode ? new SolidColorBrush(ColorHelper.FromArgb(35, 48, 112, 110)) : new SolidColorBrush(Colors.Transparent);
            selectionStatus.Text = $"{selectedFaces.Count} faces selected";
            deleteButton.IsEnabled = !isBusy && selectedFaces.Count > 0;
            clearButton.IsEnabled = !isBusy && selectedFaces.Count > 0;
            undoButton.IsEnabled = !isBusy && currentIndex > 0;
            redoButton.IsEnabled = !isBusy && currentIndex + 1 < versions.Count;
            largestButton.IsEnabled = !isBusy;
            dialog.IsPrimaryButtonEnabled = !isBusy && selectedFaces.Count == 0 && !planeMode;
        }

        void RefreshSelectionOverlay()
        {
            if (selectionVisual != null) viewport.Items.Remove(selectionVisual);
            selectionVisual = null;
            if (mesh == null || selectedFaces.Count == 0) { UpdateControls(); return; }
            var sourceGeometry = mesh.Geometry;
            var positions = new Vector3Collection();
            foreach (var point in sourceGeometry.Positions!) positions.Add(point);
            var indices = new IntCollection();
            foreach (var face in selectedFaces.Order())
            {
                var start = face * 3;
                if (start + 2 >= sourceGeometry.Indices!.Count) continue;
                indices.Add(sourceGeometry.Indices[start]); indices.Add(sourceGeometry.Indices[start + 1]); indices.Add(sourceGeometry.Indices[start + 2]);
            }
            if (indices.Count == 0) return;
            var geometry = new MeshGeometry3D { Positions = positions, Indices = indices };
            CalculateEditorNormals(geometry);
            selectionVisual = new MeshGeometryModel3D { Geometry = geometry, Material = new PhongMaterial { DiffuseColor = new Color4(1f, 0.12f, 0.1f, 0.8f), EmissiveColor = new Color4(0.3f, 0f, 0f, 1f) }, CullMode = SharpDX.Direct3D11.CullMode.None, IsHitTestVisible = false };
            viewport.Items.Add(selectionVisual);
            UpdateControls();
        }

        bool TryReadNormal()
        {
            if (!float.TryParse(normalBoxes[0].Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var x) || !float.TryParse(normalBoxes[1].Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var y) || !float.TryParse(normalBoxes[2].Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var z)) return false;
            var value = new Vector3(x, y, z);
            if (!float.IsFinite(x) || !float.IsFinite(y) || !float.IsFinite(z) || value.LengthSquared() < 1e-12f) return false;
            normal = Vector3.Normalize(value);
            return true;
        }

        void RefreshPlane()
        {
            if (planeVisual != null) viewport.Items.Remove(planeVisual);
            planeVisual = null;
            ClearPlaneMarkers();
            if (mesh == null || planePanel.Visibility != Visibility.Visible || !TryReadNormal()) return;
            offset = offsetSlider.Value;
            offsetLabel.Text = $"Offset: {offset:0.00} mm";
            var center = MeshCenter(mesh.Geometry);
            var origin = center + normal * (float)(offset * mesh.Scale);
            var (u, v) = PlaneAxes(normal);
            var minU = double.PositiveInfinity; var maxU = double.NegativeInfinity;
            var minV = double.PositiveInfinity; var maxV = double.NegativeInfinity;
            var intersects = false;
            var positions = mesh.Geometry.Positions!; var indices = mesh.Geometry.Indices!;
            for (var i = 0; i + 2 < indices.Count; i += 3)
            {
                var a = positions[indices[i]]; var b = positions[indices[i + 1]]; var c = positions[indices[i + 2]];
                var da = Vector3.Dot(a - origin, normal); var db = Vector3.Dot(b - origin, normal); var dc = Vector3.Dot(c - origin, normal);
                AddCrossing(a, da, b, db); AddCrossing(b, db, c, dc); AddCrossing(c, dc, a, da);
            }
            if (!intersects)
            {
                foreach (var p in positions) { var rel = p - origin; var pu = Vector3.Dot(rel, u); var pv = Vector3.Dot(rel, v); minU = Math.Min(minU, pu); maxU = Math.Max(maxU, pu); minV = Math.Min(minV, pv); maxV = Math.Max(maxV, pv); }
            }
            var cx = (minU + maxU) / 2; var cy = (minV + maxV) / 2;
            var halfU = Math.Max((maxU - minU) * 0.54, 0.5); var halfV = Math.Max((maxV - minV) * 0.54, 0.5);
            if (!fitPlane && double.IsFinite(manualWidth) && double.IsFinite(manualHeight) && manualWidth > 0 && manualHeight > 0)
            { halfU = manualWidth * mesh.Scale / 2; halfV = manualHeight * mesh.Scale / 2; }
            var centerPlane = origin + u * (float)cx + v * (float)cy;
            var quad = new Vector3Collection { centerPlane - u * (float)halfU - v * (float)halfV, centerPlane + u * (float)halfU - v * (float)halfV, centerPlane + u * (float)halfU + v * (float)halfV, centerPlane - u * (float)halfU + v * (float)halfV };
            var geometry = new MeshGeometry3D { Positions = quad, Indices = new IntCollection { 0, 1, 2, 0, 2, 3 } };
            CalculateEditorNormals(geometry);
            planeVisual = new MeshGeometryModel3D { Geometry = geometry, Material = new PhongMaterial { DiffuseColor = new Color4(0.1f, 0.8f, 0.9f, 0.35f), EmissiveColor = new Color4(0.02f, 0.2f, 0.22f, 0.5f) }, CullMode = SharpDX.Direct3D11.CullMode.None, IsHitTestVisible = false, RenderWireframe = true, WireframeColor = ColorHelper.FromArgb(230, 15, 170, 185) };
            viewport.Items.Add(planeVisual);
            AddRemovedHalfspacePreview(origin, flipPlane ? normal : -normal, u, v, halfU, halfV);

            void AddCrossing(Vector3 a, float da, Vector3 b, float db)
            {
                if (Math.Abs(da) < 1e-5f) Include(a);
                if ((da < 0 && db > 0) || (da > 0 && db < 0)) Include(a + (b - a) * (da / (da - db)));
            }
            void Include(Vector3 point)
            {
                var rel = point - origin; var pu = Vector3.Dot(rel, u); var pv = Vector3.Dot(rel, v);
                minU = Math.Min(minU, pu); maxU = Math.Max(maxU, pu); minV = Math.Min(minV, pv); maxV = Math.Max(maxV, pv); intersects = true;
            }
        }

        void AddRemovedHalfspacePreview(Vector3 origin, Vector3 planeNormal, Vector3 u, Vector3 v, double halfU, double halfV)
        {
            // A narrow red strip on the discarded side gives a clear directional cue without obscuring the ear.
            var center = origin + planeNormal * (float)Math.Max(mesh!.MaximumDimension * 0.2, 1);
            var half = (float)Math.Max(Math.Min(halfU, halfV) * 0.22, 1);
            var positions = new Vector3Collection { center - u * half - v * half, center + u * half - v * half, center + u * half + v * half, center - u * half + v * half };
            var geometry = new MeshGeometry3D { Positions = positions, Indices = new IntCollection { 0, 1, 2, 0, 2, 3 } };
            CalculateEditorNormals(geometry);
            var marker = new MeshGeometryModel3D { Geometry = geometry, Material = new PhongMaterial { DiffuseColor = new Color4(1f, 0.1f, 0.1f, 0.45f), EmissiveColor = new Color4(0.25f, 0f, 0f, 0.45f) }, CullMode = SharpDX.Direct3D11.CullMode.None, IsHitTestVisible = false };
            viewport.Items.Add(marker); planePreviewMarkers.Add(marker);
        }

        void ClearPlaneMarkers() { foreach (var marker in planePreviewMarkers) viewport.Items.Remove(marker); planePreviewMarkers.Clear(); }
        void SetTool(bool planeMode)
        {
            planePanel.Visibility = planeMode ? Visibility.Visible : Visibility.Collapsed;
            navigate = false;
            UpdateControls();
            if (planeMode) RefreshPlane(); else { if (planeVisual != null) viewport.Items.Remove(planeVisual); planeVisual = null; ClearPlaneMarkers(); }
        }

        void UpdateMesh(string path)
        {
            if (meshVisualLocal != null) viewport.Items.Remove(meshVisualLocal);
            if (selectionVisual != null) viewport.Items.Remove(selectionVisual);
            if (planeVisual != null) viewport.Items.Remove(planeVisual);
            ClearPlaneMarkers();
            mesh = MeshLoader.Load(path);
            faceCount = mesh.Geometry.Indices!.Count / 3;
            offsetSlider.Minimum = -mesh.MaximumDimension / mesh.Scale / 2;
            offsetSlider.Maximum = mesh.MaximumDimension / mesh.Scale / 2;
            selectedFaces.Clear();
            meshVisualLocal = new MeshGeometryModel3D { Geometry = mesh.Geometry, Material = new PhongMaterial { AmbientColor = new Color4(0.22f, 0.25f, 0.25f, 1), DiffuseColor = new Color4(0.58f, 0.72f, 0.70f, 1), EmissiveColor = new Color4(0.035f, 0.045f, 0.045f, 1), SpecularColor = new Color4(0.16f, 0.18f, 0.18f, 1), SpecularShininess = 14 }, CullMode = SharpDX.Direct3D11.CullMode.None, RenderWireframe = true, WireframeColor = ColorHelper.FromArgb(240, 15, 30, 36) };
            viewport.Items.Add(meshVisualLocal);
            if (versions.Count == 1)
            {
                var max = Math.Max(mesh.MaximumDimension * 1.7, 120);
                var camera = new PerspectiveCamera { FieldOfView = 38, Position = new Vector3(0, -max, max * 0.12f), LookDirection = new Vector3(0, max, -max * 0.12f), UpDirection = Vector3.UnitZ };
                viewport.Camera = camera;
                viewport.Camera?.ZoomExtents(viewport, 40);
            }
            RefreshSelectionOverlay();
            RefreshPlane();
        }

        async Task<bool> RunBackendAsync(Dictionary<string, object> request, string? outputPath = null)
        {
            isBusy = true; message.Text = "Applying mesh edit…"; errorText.Visibility = Visibility.Collapsed; UpdateControls();
            try
            {
                var response = await RunMeshEditorPythonAsync(request);
                if (response.TryGetProperty("source_sha256", out var hash)) originalSha = hash.GetString() ?? originalSha;
                if (outputPath != null)
                {
                    versions.RemoveRange(currentIndex + 1, versions.Count - currentIndex - 1);
                    versions.Add(outputPath); currentIndex = versions.Count - 1; UpdateMesh(outputPath);
                }
                message.Text = $"{faceCount:N0} faces · Edit applied. Undo is available.";
                return true;
            }
            catch (Exception error)
            {
                errorText.Text = error.Message; errorText.Visibility = Visibility.Visible; message.Text = "The mesh was not changed."; return false;
            }
            finally { isBusy = false; UpdateControls(); }
        }

        async Task<bool> ApplyEditAsync(string action, Dictionary<string, object>? arguments = null)
        {
            var next = Path.Combine(workspace, $"mesh-{Guid.NewGuid():N}.ply");
            var request = arguments == null ? new Dictionary<string, object>() : new Dictionary<string, object>(arguments);
            request["action"] = action; request["source"] = versions[currentIndex]; request["output"] = next; request["frame"] = Path.Combine(workspace, "frame");
            if (!await RunBackendAsync(request, next)) return false;
            var operation = arguments == null ? new Dictionary<string, object>() : new Dictionary<string, object>(arguments);
            operation["action"] = action; operations.RemoveRange(currentIndex - 1, operations.Count - (currentIndex - 1)); operations.Add(operation);
            selectedFaces.Clear(); RefreshSelectionOverlay();
            return true;
        }

        async Task LoadHistoryAsync(int target)
        {
            if (target < 0 || target >= versions.Count || target == currentIndex || isBusy) return;
            isBusy = true; UpdateControls();
            try
            {
                var request = new Dictionary<string, object> { ["action"] = "inspect", ["source"] = versions[target], ["frame"] = Path.Combine(workspace, "frame") };
                await RunMeshEditorPythonAsync(request); currentIndex = target; UpdateMesh(versions[target]); message.Text = $"{faceCount:N0} faces · Mesh restored.";
            }
            catch (Exception error) { errorText.Text = error.Message; errorText.Visibility = Visibility.Visible; }
            finally { isBusy = false; UpdateControls(); }
        }

        navButton.Click += (_, _) =>
        {
            if (planePanel.Visibility == Visibility.Visible) return;
            if (!navigate) { toolBeforeNavigate = "Select Faces"; navigate = true; }
            else { navigate = false; SetTool(toolBeforeNavigate == "Cutting Plane"); }
            UpdateControls(); viewport.Focus(FocusState.Programmatic);
        };
        selectToolButton.Click += (_, _) => SetTool(false);
        planeToolButton.Click += (_, _) => SetTool(true);
        resetButton.Click += (_, _) => { if (mesh != null) { var max = Math.Max(mesh.MaximumDimension * 1.7, 120); var camera = new PerspectiveCamera { FieldOfView = 38, Position = new Vector3(0, -max, max * 0.12f), LookDirection = new Vector3(0, max, -max * 0.12f), UpDirection = Vector3.UnitZ }; viewport.Camera = camera; viewport.Camera?.ZoomExtents(viewport, 40); } };
        throughToggle.Checked += (_, _) => throughMesh = true; throughToggle.Unchecked += (_, _) => throughMesh = false;
        addToggle.Checked += (_, _) => addSelection = true; addToggle.Unchecked += (_, _) => addSelection = false;
        fitToggle.Checked += (_, _) => { fitPlane = true; UpdateControls(); RefreshPlane(); }; fitToggle.Unchecked += (_, _) => { fitPlane = false; UpdateControls(); RefreshPlane(); };
        widthBox.TextChanged += (_, _) => { if (double.TryParse(widthBox.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) manualWidth = value; RefreshPlane(); };
        heightBox.TextChanged += (_, _) => { if (double.TryParse(heightBox.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) manualHeight = value; RefreshPlane(); };
        flipToggle.Checked += (_, _) => { flipPlane = true; RefreshPlane(); }; flipToggle.Unchecked += (_, _) => { flipPlane = false; RefreshPlane(); };
        offsetSlider.ValueChanged += (_, args) => { offset = args.NewValue; RefreshPlane(); };
        deleteButton.Click += async (_, _) => await ApplyEditAsync("delete", new Dictionary<string, object> { ["faces"] = selectedFaces.Order().ToArray() });
        clearButton.Click += (_, _) => { selectedFaces.Clear(); RefreshSelectionOverlay(); };
        largestButton.Click += async (_, _) => await ApplyEditAsync("largest");
        cutButton.Click += async (_, _) =>
        {
            if (!TryReadNormal() || mesh == null) return;
            var unit = flipPlane ? -normal : normal;
            var originDisplay = MeshCenter(mesh.Geometry) + normal * (float)(offsetSlider.Value * mesh.Scale);
            var origin = mesh.ToRaw(originDisplay);
            if (await ApplyEditAsync("cut", new Dictionary<string, object> { ["normal"] = new[] { (double)unit.X, unit.Y, unit.Z }, ["origin"] = new[] { (double)origin.X, origin.Y, origin.Z } }))
            {
                toolBeforeNavigate = "Cutting Plane"; navigate = true; planePanel.Visibility = Visibility.Collapsed;
                if (planeVisual != null) viewport.Items.Remove(planeVisual); planeVisual = null; ClearPlaneMarkers(); UpdateControls();
            }
        };
        undoButton.Click += async (_, _) => await LoadHistoryAsync(currentIndex - 1);
        redoButton.Click += async (_, _) => await LoadHistoryAsync(currentIndex + 1);
        lassoCanvas.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) =>
        {
            if (navigate || planePanel.Visibility == Visibility.Visible || isBusy) return;
            var point = e.GetCurrentPoint(viewport);
            if (!point.Properties.IsLeftButtonPressed) return;
            activePointer = point.PointerId; pointerStart = point.Position; lasso.Clear(); lasso.Add(pointerStart); lassoCanvas.Children.Clear();
            lassoCanvas.CapturePointer(e.Pointer); viewport.Focus(FocusState.Programmatic); e.Handled = true;
        }), true);
        lassoCanvas.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler((_, e) =>
        {
            if (navigate || activePointer == uint.MaxValue || e.GetCurrentPoint(viewport).PointerId != activePointer) return;
            var point = e.GetCurrentPoint(viewport).Position;
            if (lasso.Count == 0 || Math.Abs(point.X - lasso[^1].X) + Math.Abs(point.Y - lasso[^1].Y) >= 3) lasso.Add(point);
            if (lasso.Count > 1)
            {
                lassoCanvas.Children.Clear(); var points = new PointCollection(); foreach (var item in lasso) points.Add(item); var line = new Polyline { Stroke = new SolidColorBrush(ColorHelper.FromArgb(235, 25, 115, 125)), StrokeThickness = 2, Points = points };
                lassoCanvas.Children.Add(line);
            }
            e.Handled = true;
        }), true);
        lassoCanvas.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, e) =>
        {
            if (navigate || activePointer == uint.MaxValue || e.GetCurrentPoint(viewport).PointerId != activePointer) return;
            var end = e.GetCurrentPoint(viewport).Position; var wasClick = Math.Abs(end.X - pointerStart.X) + Math.Abs(end.Y - pointerStart.Y) < 7;
            activePointer = uint.MaxValue; lassoCanvas.ReleasePointerCapture(e.Pointer); lassoCanvas.Children.Clear();
            if (wasClick) SelectNearestFace(end); else SelectLasso(lasso);
            e.Handled = true;
        }), true);
        var space = new KeyboardAccelerator { Key = VirtualKey.Space };
        space.Invoked += (_, args) =>
        {
            if (planePanel.Visibility == Visibility.Visible) return;
            if (navigate) { navigate = false; SetTool(toolBeforeNavigate == "Cutting Plane"); }
            else { toolBeforeNavigate = "Select Faces"; navigate = true; }
            UpdateControls(); args.Handled = true;
        };
        root.KeyboardAccelerators.Add(space);
        resetButton.Visibility = Visibility.Visible;
        undoButton.IsEnabled = false; redoButton.IsEnabled = false;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (isBusy || selectedFaces.Count != 0 || planePanel.Visibility == Visibility.Visible || versions.Count == 0) return;
            var request = new Dictionary<string, object>
            {
                ["action"] = "save", ["kind"] = "ear", ["source"] = versions[currentIndex],
                ["original_source"] = preparedSource, ["original_sha256"] = originalSha,
                ["destination"] = destination, ["side"] = side, ["prepared_report"] = report,
                ["prepared_generation"] = generation, ["operations"] = operations
            };
            if (await RunBackendAsync(request)) { savedPath = destination; dialog.Hide(); }
        };

        try
        {
            var first = Path.Combine(workspace, "mesh-0.ply");
            var opened = await RunMeshEditorPythonAsync(new Dictionary<string, object> { ["action"] = "open", ["source"] = source, ["original_source"] = preparedSource, ["output"] = first, ["frame"] = Path.Combine(workspace, "frame") });
            originalSha = opened.GetProperty("source_sha256").GetString() ?? "";
            versions.Add(first); currentIndex = 0; isBusy = false; UpdateMesh(first); message.Text = $"{faceCount:N0} faces · Original mesh is preserved."; UpdateControls();
            await dialog.ShowAsync();
            return savedPath;
        }
        catch (Exception error)
        {
            AppendLog("Could not open ear editor: " + error.Message, selectedProject?.Id);
            return null;
        }
        finally
        {
            try { if (Directory.Exists(workspace)) Directory.Delete(workspace, true); } catch { }
        }

        void SelectNearestFace(Windows.Foundation.Point screenPoint)
        {
            if (mesh == null || meshVisualLocal == null || !TryUnprojectHit(screenPoint, out var hit)) return;
            var positions = mesh.Geometry.Positions!; var indices = mesh.Geometry.Indices!;
            var nearest = -1; var distance = float.PositiveInfinity;
            for (var i = 0; i + 2 < indices.Count; i += 3)
            {
                var a = positions[indices[i]]; var b = positions[indices[i + 1]]; var c = positions[indices[i + 2]];
                var candidate = ClosestPointOnTriangle(hit, a, b, c);
                var d = Vector3.DistanceSquared(candidate, hit);
                if (d < distance) { distance = d; nearest = i / 3; }
            }
            if (nearest < 0) return;
            if (!addSelection && !selectedFaces.Contains(nearest)) selectedFaces.Clear();
            if (!selectedFaces.Add(nearest)) selectedFaces.Remove(nearest);
            RefreshSelectionOverlay();
        }

        bool TryUnprojectHit(Windows.Foundation.Point point, out Vector3 hit)
        {
            var result = viewport.FindHits(point).FirstOrDefault(x => ReferenceEquals(x.ModelHit, meshVisualLocal));
            if (result == null) { hit = default; return false; }
            hit = result.PointHit; return true;
        }

        void SelectLasso(IReadOnlyList<Windows.Foundation.Point> polygon)
        {
            if (mesh == null || polygon.Count < 3) return;
            if (!addSelection) selectedFaces.Clear();
            var camera = viewport.Camera as PerspectiveCamera; if (camera == null) return;
            var forward = Vector3.Normalize(camera.LookDirection); var right = Vector3.Normalize(Vector3.Cross(forward, camera.UpDirection)); var up = Vector3.Normalize(Vector3.Cross(right, forward));
            var focal = (float)(viewport.ActualHeight / (2 * Math.Tan(camera.FieldOfView * Math.PI / 360)));
            var cameraPos = camera.Position;
            var positions = mesh.Geometry.Positions!; var indices = mesh.Geometry.Indices!;
            for (var i = 0; i + 2 < indices.Count; i += 3)
            {
                var a = positions[indices[i]]; var b = positions[indices[i + 1]]; var c = positions[indices[i + 2]];
                var centroid = (a + b + c) / 3;
                if (!Project(centroid, out var pixel) || !InsidePolygon(pixel, polygon)) continue;
                if (!throughMesh)
                {
                    var faceNormal = Vector3.Cross(b - a, c - a);
                    if (Vector3.Dot(faceNormal, cameraPos - centroid) <= 0) continue;
                }
                selectedFaces.Add(i / 3);
            }
            RefreshSelectionOverlay();

            bool Project(Vector3 p, out Windows.Foundation.Point pixel)
            {
                var relative = p - cameraPos; var depth = Vector3.Dot(relative, forward);
                if (depth <= 1e-3f || viewport.ActualWidth <= 0 || viewport.ActualHeight <= 0) { pixel = default; return false; }
                pixel = new Windows.Foundation.Point(viewport.ActualWidth / 2 + focal * Vector3.Dot(relative, right) / depth, viewport.ActualHeight / 2 - focal * Vector3.Dot(relative, up) / depth);
                return true;
            }
        }
    }

    async Task<JsonElement> RunMeshEditorPythonAsync(Dictionary<string, object> request)
    {
        var executable = BundledPythonExecutable() ?? Path.Combine(packageRoot, ".venv", "Scripts", "python.exe");
        if (!File.Exists(executable)) throw new FileNotFoundException("The app's Python runtime is missing.", executable);
        var script = "import sys,json; from HRTFCalculation.MeshEditing import execute; print(json.dumps(execute(json.load(sys.stdin)),allow_nan=False))";
        var start = new ProcessStartInfo(executable) { WorkingDirectory = packageRoot, UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        start.ArgumentList.Add("-c"); start.ArgumentList.Add(script); ApplyProcessEnvironment(start);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start the mesh editor.");
        var stdoutTask = process.StandardOutput.ReadToEndAsync(); var stderrTask = process.StandardError.ReadToEndAsync();
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request, jsonOptions)); process.StandardInput.Close(); await process.WaitForExitAsync();
        var stdout = await stdoutTask; var stderr = await stderrTask;
        if (process.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(stderr) ? "The mesh edit failed." : stderr.Trim());
        using var document = JsonDocument.Parse(stdout); return document.RootElement.Clone();
    }

    bool EarReviewIsCurrent(ProjectRecord project, string side, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        try
        {
            var settings = project.Settings.ScanPreparation;
            var reviewed = side == "left" ? settings.ReviewedLeft : settings.ReviewedRight;
            if (string.IsNullOrWhiteSpace(reviewed) || !File.Exists(reviewed)) return false;
            var folder = Path.Combine(project.SaveLocation, "Prepared");
            var reportRoot = inspection.Document(Path.Combine(folder, "mesh_preparation.json"));
            var receiptRoot = inspection.Document(Path.ChangeExtension(reviewed, ".json"));
            var generation = reportRoot.GetProperty("generation").GetString();
            var baseEar = Path.Combine(folder, side == "left" ? "Left.stl" : "Right.stl");
            var baseDigest = inspection.Digest(baseEar); var editedDigest = inspection.Digest(reviewed);
            return receiptRoot.GetProperty("kind").GetString() == "ear" &&
                receiptRoot.GetProperty("side").GetString() == side &&
                receiptRoot.GetProperty("generation").GetString() == generation &&
                receiptRoot.GetProperty("source_sha256").GetString() == baseDigest &&
                receiptRoot.GetProperty("output_sha256").GetString() == editedDigest;
        }
        catch { return false; }
    }

    bool ScanReviewStageReceiptCurrent(ProjectRecord project, string stage, ArtifactInspection? inspection = null)
    {
        inspection ??= new ArtifactInspection();
        try
        {
            var folder = Path.Combine(project.SaveLocation, "Prepared");
            var reportRoot = inspection.Document(Path.Combine(folder, "mesh_preparation.json"));
            var receiptRoot = inspection.Document(Path.Combine(folder, stage + ".json"));
            var generation = reportRoot.GetProperty("generation").GetString();
            if (receiptRoot.GetProperty("generation").GetString() != generation || !receiptRoot.TryGetProperty("input_ears", out var inputEars)) return false;
            foreach (var (side, enabled, reviewPath) in new[]
            {
                ("left", project.Settings.ScanPreparation.PrepareLeft, project.Settings.ScanPreparation.ReviewedLeft),
                ("right", project.Settings.ScanPreparation.PrepareRight, project.Settings.ScanPreparation.ReviewedRight)
            })
            {
                if (!enabled) continue;
                var useReviewed = !string.IsNullOrWhiteSpace(reviewPath) && EarReviewIsCurrent(project, side, inspection);
                var path = useReviewed ? reviewPath! : Path.Combine(folder, side == "left" ? "Left.stl" : "Right.stl");
                if (!File.Exists(path) || !inputEars.TryGetProperty(side, out var recorded) || recorded.GetString() != inspection.Digest(path)) return false;
            }
            return true;
        }
        catch { return false; }
    }

    static string FileDigest(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    static Vector3 MeshCenter(MeshGeometry3D geometry)
    {
        var positions = geometry.Positions!;
        var min = new Vector3(positions.Min(p => p.X), positions.Min(p => p.Y), positions.Min(p => p.Z));
        var max = new Vector3(positions.Max(p => p.X), positions.Max(p => p.Y), positions.Max(p => p.Z));
        return (min + max) / 2;
    }

    static (Vector3 U, Vector3 V) PlaneAxes(Vector3 normal)
    {
        var seed = Math.Abs(Vector3.Dot(normal, Vector3.UnitZ)) < 0.95f ? Vector3.UnitZ : Vector3.UnitY;
        var u = Vector3.Normalize(Vector3.Cross(seed, normal));
        return (u, Vector3.Normalize(Vector3.Cross(normal, u)));
    }

    static void CalculateEditorNormals(MeshGeometry3D geometry)
    {
        var normals = new Vector3Collection();
        for (var i = 0; i < geometry.Positions!.Count; i++) normals.Add(Vector3.Zero);
        for (var i = 0; i + 2 < geometry.Indices!.Count; i += 3)
        {
            var a = geometry.Indices[i]; var b = geometry.Indices[i + 1]; var c = geometry.Indices[i + 2];
            var n = Vector3.Cross(geometry.Positions[b] - geometry.Positions[a], geometry.Positions[c] - geometry.Positions[a]);
            if (n.LengthSquared() < 1e-12f) continue;
            normals[a] += n; normals[b] += n; normals[c] += n;
        }
        for (var i = 0; i < normals.Count; i++) normals[i] = normals[i].LengthSquared() > 1e-12f ? Vector3.Normalize(normals[i]) : Vector3.UnitZ;
        geometry.Normals = normals; geometry.UpdateBounds();
    }

    static Vector3 ClosestPointOnTriangle(Vector3 p, Vector3 a, Vector3 b, Vector3 c)
    {
        var ab = b - a; var ac = c - a; var ap = p - a; var d1 = Vector3.Dot(ab, ap); var d2 = Vector3.Dot(ac, ap);
        if (d1 <= 0 && d2 <= 0) return a;
        var bp = p - b; var d3 = Vector3.Dot(ab, bp); var d4 = Vector3.Dot(ac, bp);
        if (d3 >= 0 && d4 <= d3) return b;
        var vc = d1 * d4 - d3 * d2;
        if (vc <= 0 && d1 >= 0 && d3 <= 0) return a + ab * (d1 / (d1 - d3));
        var cp = p - c; var d5 = Vector3.Dot(ab, cp); var d6 = Vector3.Dot(ac, cp);
        if (d6 >= 0 && d5 <= d6) return c;
        var vb = d5 * d2 - d1 * d6;
        if (vb <= 0 && d2 >= 0 && d6 <= 0) return a + ac * (d2 / (d2 - d6));
        var va = d3 * d6 - d5 * d4;
        if (va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0) return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
        var denom = 1 / (va + vb + vc); return a + ab * (vb * denom) + ac * (vc * denom);
    }

    static bool InsidePolygon(Windows.Foundation.Point point, IReadOnlyList<Windows.Foundation.Point> polygon)
    {
        var inside = false;
        for (var i = 0, j = polygon.Count - 1; i < polygon.Count; j = i++)
        {
            var a = polygon[i]; var b = polygon[j];
            if ((a.Y > point.Y) != (b.Y > point.Y) && point.X < (b.X - a.X) * (point.Y - a.Y) / (b.Y - a.Y) + a.X) inside = !inside;
        }
        return inside;
    }
}
