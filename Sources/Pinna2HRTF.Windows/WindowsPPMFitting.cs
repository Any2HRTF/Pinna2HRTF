using HelixToolkit;
using HelixToolkit.Maths;
using MeshBuilder = HelixToolkit.Geometry.MeshBuilder;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using System.Globalization;
using System.Numerics;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    readonly Dictionary<(Guid Project, string Side), Window> fittingWindows = [];
    async Task TryOpenPPMFittingAsync(string side)
    {
        try { await OpenPPMFittingAsync(side); }
        catch(Exception error) { AppendLog("Could not open PPM fitting: " + error.Message, selectedProject?.Id); }
    }

    async Task OpenPPMFittingAsync(string side)
    {
        var project = selectedProject;
        if (project == null) return;
        var fittingKey = (project.Id, side);
        if (fittingWindows.TryGetValue(fittingKey, out var existing))
        {
            if (existing.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter && presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized) presenter.Restore();
            existing.Activate();
            return;
        }
        if (ProjectBusy(project.Id)) return;
        using var reservation = projectOperations.TryReserve(project.Id);
        if (reservation == null) return;
        var source = SourceEar(project, side);
        if (string.IsNullOrWhiteSpace(project.SaveLocation)) { AppendLog("Choose a save location before fitting.", project.Id); return; }
        if (source == null) { AppendLog($"Choose or prepare a valid {side} ear mesh before fitting.", project.Id); return; }
        var identity = await Task.Run(() => { using var fresh = FileFingerprints.Fresh(); return MeshIdentity(source); });
        var workspace = Path.Combine(Path.GetTempPath(), "pinna-ppm-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(workspace);
        var preview = Path.Combine(workspace, "preview.meshbin");
        var editor = new NativeEditor($"Manual PPM Fit — {side} ear", Root); editorWindows.Add(editor.Window);
        fittingWindows[fittingKey] = editor.Window;
        void ForgetWindow() { if (fittingWindows.TryGetValue(fittingKey, out var current) && ReferenceEquals(current, editor.Window)) fittingWindows.Remove(fittingKey); }
        editor.Window.Closed += (_, _) => ForgetWindow();
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(editorLifetime.Token);
        try
        {
        var info = GeometryProcess("-B", "-u", "-c", "import contextlib,sys\nwith contextlib.redirect_stdout(sys.stderr):\n from HRTFCalculation.ManualPPMFitting import serve\nserve()");
        using var worker = new PPMPythonWorker(info, project.Id);
        var closed = new TaskCompletionSource();
        editor.Window.Closed += (_,_) => { lifetime.Cancel(); worker.Dispose(); editorWindows.Remove(editor.Window); closed.TrySetResult(); };
        editor.Controls.Margin = new Thickness(16); editor.Controls.Spacing = 12;
        editor.PinnedControls.Margin = new Thickness(16, 16, 16, 8);
        var save = new Button { Content = "Save fit", FontSize = 12, MinWidth = 88, MinHeight = 32, IsEnabled = false }; var reset = new Button { Content = "Reset adjustments", FontSize = 12, Padding = new Thickness(10, 5, 10, 5), MinHeight = 32 };
        var undo = NavigationHelp.Command("Undo"); undo.IsEnabled = false; var redo = NavigationHelp.Command("Redo"); redo.IsEnabled = false;
        var camera = NavigationHelp.Command("Reset view"); var metrics = new TextBlock { TextWrapping = TextWrapping.Wrap };
        editor.NavigationButton.HorizontalAlignment = HorizontalAlignment.Left; editor.NavigationButton.Margin = new Thickness(16);
        camera.HorizontalAlignment = HorizontalAlignment.Right; camera.VerticalAlignment = VerticalAlignment.Bottom; camera.Margin = new Thickness(16);
        editor.ViewportHost.Children.Add(camera);
        if (MacLayout)
        {
            editor.Toolbar.Children.Add(undo); editor.Toolbar.Children.Add(redo);
            var cancel = new Button { Content = "Cancel", FontSize = 12, MinWidth = 88, MinHeight = 32 }; cancel.Click += (_, _) => editor.Window.Close();
            editor.FooterActions.Children.Add(cancel); editor.FooterActions.Children.Add(save); editor.FooterHost.Visibility = Visibility.Visible;
            editor.CombineStatusAndActions();
        }
        else foreach (var button in new[] { undo, redo, save }) editor.Toolbar.Children.Add(button);

        editor.Subtitle.Text = Path.GetFileName(source); editor.Subtitle.Visibility = Visibility.Visible;
        var metricSummary = new TextBlock { Text = "Calculating mesh distances…", FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        editor.PinnedControls.Children.Add(metricSummary);
        metrics.FontSize = 12;
        editor.PinnedControls.Children.Add(new Expander { Header = "Distance Details", Content = metrics, FontSize = 12, IsExpanded = false, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        var display = new ComboBox { ItemsSource = new[] { "Overlay", "Target", "Error Map", "Hidden" }, SelectedIndex = 0, FontSize = 12, MinHeight = 32, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(display, "Display");
        var displayRow = new Grid { ColumnSpacing = 8 }; displayRow.ColumnDefinitions.Add(new() { Width = new GridLength(72) }); displayRow.ColumnDefinitions.Add(new());
        displayRow.Children.Add(new TextBlock { Text = "Display", FontSize = 12, VerticalAlignment = VerticalAlignment.Center }); Grid.SetColumn(display, 1); displayRow.Children.Add(display); editor.Controls.Children.Add(displayRow);
        var skeletonToggle = new CheckBox { Content = "Show skeleton", IsChecked = true, Height = 32,
            FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(skeletonToggle, "Show Blender skeleton");
        ToolTipService.SetToolTip(skeletonToggle, "Show the Blender skeleton");
        var fittingActions = new Grid { ColumnSpacing = 8 }; fittingActions.ColumnDefinitions.Add(new()); fittingActions.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        reset.Height = 32;
        fittingActions.Children.Add(skeletonToggle); Grid.SetColumn(reset, 1); fittingActions.Children.Add(reset); editor.Controls.Children.Add(fittingActions);
        var sections = new SelectorBar();
        foreach (var title in new[] { "Global", "Local", "Shape Keys" }) sections.Items.Add(new SelectorBarItem { Text = title });
        sections.SelectedItem = sections.Items[0]; AutomationProperties.SetName(sections, "Fitting section"); editor.Controls.Children.Add(sections);
        var opacity = new Slider { Minimum = 0, Maximum = 100, Value = 35, MinWidth = 70 }; AutomationProperties.SetName(opacity, "Target opacity");
        var opacityValue = new TextBlock { Text = "35%", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var opacityRow = new Grid { ColumnSpacing = 6 };
        opacityRow.ColumnDefinitions.Add(new() { Width = new GridLength(100) }); opacityRow.ColumnDefinitions.Add(new()); opacityRow.ColumnDefinitions.Add(new() { Width = new GridLength(32) });
        opacityRow.Children.Add(new TextBlock { Text = "Target opacity", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(opacity, 1); opacityRow.Children.Add(opacity); Grid.SetColumn(opacityValue, 2); opacityRow.Children.Add(opacityValue); editor.Controls.Children.Insert(1, opacityRow);
        var sectionHost = new Grid(); editor.Controls.Children.Add(sectionHost);
        void SelectSection()
        {
            for (var i = 0; i < sectionHost.Children.Count; i++) sectionHost.Children[i].Visibility = ReferenceEquals(sections.SelectedItem, sections.Items[i]) ? Visibility.Visible : Visibility.Collapsed;
        }
        sections.SelectionChanged += (_, _) => SelectSection();
        var legendRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        legendRow.Children.Add(new TextBlock { Text = "0", FontSize = 11 });
        var gradient = new LinearGradientBrush { StartPoint = new(0, .5), EndPoint = new(1, .5) };
        foreach (var stop in new[] { 0f, .5f, 1f, 1.75f, 3f })
        {
            var c = FieldColors.Distance(stop);
            gradient.GradientStops.Add(new GradientStop { Offset = stop / 3, Color = ColorHelper.FromArgb(255, (byte)(c.X * 255), (byte)(c.Y * 255), (byte)(c.Z * 255)) });
        }
        legendRow.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle { Fill = gradient, Width = 105, Height = 9, RadiusX = 4, RadiusY = 4, VerticalAlignment = VerticalAlignment.Center });
        legendRow.Children.Add(new TextBlock { Text = "3+ mm", FontSize = 11 });
        var legendContent = new StackPanel { Spacing = 5 }; legendContent.Children.Add(new TextBlock { Text = "PPM · distance error", FontSize = 11 }); legendContent.Children.Add(legendRow);
        var legend = new Border { Child = legendContent, CornerRadius = new CornerRadius(6), Padding = new Thickness(9), Margin = new Thickness(16), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
        void LegendTheme() => legend.Background = new SolidColorBrush(editor.ViewportHost.ActualTheme == ElementTheme.Dark ? ColorHelper.FromArgb(225, 43, 46, 48) : ColorHelper.FromArgb(225, 255, 255, 255));
        editor.ViewportHost.ActualThemeChanged += (_, _) => LegendTheme(); LegendTheme(); editor.ViewportHost.Children.Add(legend);
        var target = NativeEditor.Model(NativeEditor.RawMesh(source)); target.IsTransparent = true; editor.Viewport.Items.Add(target);
        MeshGeometryModel3D? ppm = null; TopMostGroup3D? skeleton = null;
        var catalog = new PPMControlCatalog(); var values = catalog.Values; JsonElement parameters = default;
        var expandedLocal = new Dictionary<string, bool>();
        var history = new Stack<Dictionary<string,double>>(); var future = new Stack<Dictionary<string,double>>();
        var sliders = new Dictionary<string,Slider>(); var syncing = false; var busy = false; var revision = 0; var previewRunning = false;
        var numbers = new List<NumberBox>();
        string? draggingControl=null;
        void PushHistory(Stack<Dictionary<string,double>> stack,Dictionary<string,double> snapshot)
        {
            stack.Push(snapshot);
            if(stack.Count<=100)return;
            var keep=stack.Take(100).Reverse().ToArray();stack.Clear();foreach(var item in keep)stack.Push(item);
        }
        var oldFit = project.Settings.ManualPPM.For(side);
        var desktopTemplate = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "PPM.blend");
        var template = File.Exists(project.Settings.ManualPPM.TemplateBlend) ? project.Settings.ManualPPM.TemplateBlend! : File.Exists(desktopTemplate) ? desktopTemplate : "";
        // Stale fits may be opened for explicit review/re-save, never selected
        // silently for preprocessing. The current target is validated on save.
        var savedParameters = oldFit != null && SamePath(oldFit.Source, source) && File.Exists(oldFit.Parameters) ? oldFit.Parameters : null;
        void HistoryState()
        {
            undo.IsEnabled = !busy && history.Count > 0; redo.IsEnabled = !busy && future.Count > 0;
            reset.IsEnabled = !busy && !previewRunning;
            foreach (var slider in sliders.Values) slider.IsEnabled = !busy;
            foreach (var number in numbers) number.IsEnabled = !busy;
            display.IsEnabled = skeletonToggle.IsEnabled = sections.IsEnabled = !busy;
            opacity.IsEnabled = !busy && display.SelectedIndex is 0 or 1;
        }
        void Appearance()
        {
            var showTarget = display.SelectedIndex is 0 or 1; var showPPM = display.SelectedIndex is 0 or 2;
            target.Visibility = showTarget && opacity.Value > 0 ? Visibility.Visible : Visibility.Collapsed;
            target.Material = new PhongMaterial { DiffuseColor = new Color4(.75f,.78f,.8f,(float)opacity.Value/100), AmbientColor = new Color4(.3f,.3f,.3f,1) };
            if (ppm != null) ppm.Visibility = showPPM ? Visibility.Visible : Visibility.Collapsed;
            if (skeleton != null) skeleton.Visibility = skeletonToggle.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            opacity.IsEnabled = !busy && showTarget; opacityValue.Text = $"{opacity.Value:F0}%";
        }
        void Install(JsonElement result, bool controls = false)
        {
            parameters = result.GetProperty("parameters").Clone();
            if (result.TryGetProperty("template_blend", out var selectedTemplate)) template = selectedTemplate.GetString() ?? "";
            if (result.TryGetProperty("mesh_data",out _))
            {
                var geometry = ReadPPMPreview(preview, side == "right");
                if (ppm != null) editor.Viewport.Items.Remove(ppm);
                ppm = NativeEditor.Model(geometry,true); editor.Viewport.Items.Add(ppm);
            }
            if (result.TryGetProperty("metrics",out var report))
            {
                metricSummary.Text = $"Symmetric RMSE   {report.GetProperty("symmetric_rmse").GetProperty("value").GetDouble():F3} mm";
                metrics.Text = $"PPM → target RMSE: {report.GetProperty("ppm_to_target_rmse").GetProperty("value").GetDouble():F3} mm\n"+
                    $"Target → PPM RMSE: {report.GetProperty("target_to_ppm_rmse").GetProperty("value").GetDouble():F3} mm\n"+
                    $"Symmetric RMSE: {report.GetProperty("symmetric_rmse").GetProperty("value").GetDouble():F3} mm\n"+
                    $"Mean/median: {report.GetProperty("mean").GetProperty("value").GetDouble():F3} / {report.GetProperty("median").GetProperty("value").GetDouble():F3} mm\n"+
                    $"Min/max: {report.GetProperty("min").GetProperty("value").GetDouble():F3} / {report.GetProperty("max").GetProperty("value").GetDouble():F3} mm";
            }
            if (skeleton != null) editor.Viewport.Items.Remove(skeleton);
            if (result.TryGetProperty("skeleton",out var bones))
            {
                // Match the Mac rig: curved cyan B-Bones, yellow controls and
                // joint markers, visible through the mesh like Blender In Front.
                var bendy = new MeshBuilder(); var controlsMesh = new MeshBuilder();
                foreach (var bone in bones.EnumerateArray())
                {
                    var points = bone.GetProperty("points").EnumerateArray().Select(p => p.EnumerateArray().Select(x => x.GetSingle()).ToArray())
                        .Where(p => p.Length == 3 && p.All(float.IsFinite))
                        .Select(p => new Vector3(p[0], side == "right" ? -p[1] : p[1], p[2])).ToArray();
                    if (points.Length < 2) continue;
                    var builder = bone.GetProperty("name").GetString()?.EndsWith("-Bendy", StringComparison.Ordinal) == true ? bendy : controlsMesh;
                    for (var i=1; i<points.Length; i++)
                    {
                        if (Vector3.DistanceSquared(points[i-1], points[i]) > 1e-10f)
                            builder.AddCylinder(points[i-1], points[i], .24f, 8);
                    }
                    builder.AddSphere(points[0], .22f, 8, 6);
                    builder.AddSphere(points[^1], .22f, 8, 6);
                }
                skeleton = new TopMostGroup3D { EnableTopMost = true, IsHitTestVisible = false };
                foreach (var (builder, color) in new[] { (bendy, new Color4(0, 1, 1, 1)), (controlsMesh, new Color4(1, .82f, 0, 1)) })
                    if (builder.Positions.Count > 0) skeleton.Children.Add(new MeshGeometryModel3D {
                        Geometry = builder.ToMeshGeometry3D(), IsHitTestVisible = false, CullMode = SharpDX.Direct3D11.CullMode.None,
                        Material = new DiffuseMaterial { DiffuseColor = color, EnableUnLit = true } });
                editor.Viewport.Items.Add(skeleton);
            }
            if (controls)
            {
                syncing = true; sliders.Clear(); numbers.Clear(); sectionHost.Children.Clear(); catalog.Load(result.GetProperty("controls"));
                FrameworkElement Row(PPMControl control)
                {
                    var id = control.Id;
                    var slider = new Slider { Minimum = control.Minimum, Maximum = control.Maximum, Value = values[id], StepFrequency = control.Step, Height = 28, MinHeight = 28 };
                    var number = new NumberBox { Value = values[id], Width = 82, Height = 32, SmallChange = control.Step, Minimum = control.Minimum, Maximum = control.Maximum,
                        SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, FontSize = 12,
                        Padding = new Thickness(10, 8, 6, 3) };
                    var formatter = new global::Windows.Globalization.NumberFormatting.DecimalFormatter(new[] { CultureInfo.CurrentCulture.Name }, new RegionInfo(CultureInfo.CurrentCulture.Name).TwoLetterISORegionName) { IntegerDigits = 1, FractionDigits = 2,
                        NumberRounder = new global::Windows.Globalization.NumberFormatting.IncrementNumberRounder { Increment = .01 } };
                    number.NumberFormatter = formatter;
                    numbers.Add(number);
                    var accessible = control.Group + " · " + control.ShortLabel + (control.Unit.Length > 0 ? " (" + control.Unit + ")" : "");
                    AutomationProperties.SetName(slider, accessible); AutomationProperties.SetName(number, accessible);
                    AutomationProperties.SetAutomationId(slider, "ppm.parameter." + id + ".slider"); AutomationProperties.SetAutomationId(number, "ppm.parameter." + id + ".value");
                    sliders[id] = slider;
                    var labelRow = new Grid { ColumnSpacing = 5 };
                    labelRow.ColumnDefinitions.Add(new()); labelRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); labelRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                    var label = new TextBlock { Text = control.ShortLabel, FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
                    labelRow.Children.Add(label); Grid.SetColumn(number, 1); labelRow.Children.Add(number);
                    var unit = new TextBlock { Text = control.Unit, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, MinWidth = control.Unit.Length > 0 ? 16 : 0 };
                    Grid.SetColumn(unit, 2); labelRow.Children.Add(unit);
                    var row = new StackPanel { Spacing = 0 }; row.Children.Add(labelRow); row.Children.Add(slider);
                    slider.ValueChanged += (_, args) =>
                    {
                        number.Value = args.NewValue;
                        if (syncing || busy || values[id] == args.NewValue) return;
                        if (draggingControl != id) PushHistory(history, new(values));
                        future.Clear(); values[id] = args.NewValue; revision++; HistoryState(); _ = Preview();
                    };
                    slider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) =>
                    { if (syncing || busy) return; draggingControl = id; PushHistory(history, new(values)); future.Clear(); }), true);
                    slider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => draggingControl = null), true);
                    slider.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => draggingControl = null), true);
                    number.ValueChanged += (_, args) =>
                    {
                        // Merely focusing a value formatted to two decimals must
                        // not replace a saved parameter with its rounded display.
                        var displayed = formatter.ParseDouble(formatter.FormatDouble(values[id])) ?? values[id];
                        if (!syncing && !busy && catalog.ShouldCommitNumber(id, args.NewValue, displayed)) slider.Value = args.NewValue;
                    };
                    number.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, e) =>
                    {
                        if (e.Key != global::Windows.System.VirtualKey.Escape) return;
                        syncing = true; number.Text = formatter.FormatDouble(values[id]); number.Value = values[id]; syncing = false; e.Handled = true;
                    }), true);
                    return row;
                }
                var globalPanel = new StackPanel { Spacing = 12 };
                foreach (var kind in new[] { "Location", "Rotation", "Scale" })
                {
                    var group = new StackPanel { Spacing = 4 };
                    group.Children.Add(new TextBlock { Text = kind == "Location" ? "Position (mm)" : kind == "Rotation" ? "Rotation (°)" : "Scale",
                        FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                    foreach (var control in catalog.Section("global").Where(c => c.Kind == kind)) group.Children.Add(Row(control));
                    globalPanel.Children.Add(group);
                }
                sectionHost.Children.Add(globalPanel);
                var localPanel = new StackPanel { Spacing = 6 };
                foreach (var group in catalog.Section("convex").GroupBy(c => c.Group).OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase))
                {
                    var content = new StackPanel { Spacing = 6 };
                    foreach (var control in group) content.Children.Add(Row(control));
                    var expander = new Expander { Header = group.Key, Content = content, IsExpanded = expandedLocal.GetValueOrDefault(group.Key),
                        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                    expander.RegisterPropertyChangedCallback(Expander.IsExpandedProperty, (_, _) => expandedLocal[group.Key] = expander.IsExpanded);
                    localPanel.Children.Add(expander);
                }
                sectionHost.Children.Add(localPanel);
                var shapePanel = new StackPanel { Spacing = 6 };
                foreach (var control in catalog.Section("concave")) shapePanel.Children.Add(Row(control));
                sectionHost.Children.Add(shapePanel);
                SelectSection(); syncing = false;
            }
            Appearance(); save.IsEnabled = !busy; HistoryState();
        }
        async Task Preview()
        {
            if (previewRunning || busy || lifetime.IsCancellationRequested) return;
            previewRunning = true; save.IsEnabled = false; HistoryState();
            try
            {
                await Task.Delay(70,lifetime.Token);
                while (!lifetime.IsCancellationRequested)
                {
                    var requested = revision; var snapshot = new Dictionary<string,double>(values);
                    var result = await worker.ExecuteAsync(new { action = "preview_mesh", parameters, controls = snapshot, mesh_data = preview, mirror_y = side == "right" },lifetime.Token);
                    if (lifetime.IsCancellationRequested) return;
                    if (requested == revision) { Install(result); editor.Status.Text = "Preview is up to date."; break; }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!lifetime.IsCancellationRequested) editor.Status.Text = error.Message; }
            finally { previewRunning = false; if (!lifetime.IsCancellationRequested) { save.IsEnabled = !busy; HistoryState(); } }
        }
        void Restore(Dictionary<string,double> snapshot)
        {
            syncing = true; catalog.Restore(snapshot); foreach(var pair in sliders) pair.Value.Value = values[pair.Key]; syncing = false;
            revision++; HistoryState(); _ = Preview();
        }
        void Undo(){if(busy||history.Count==0)return;PushHistory(future,new(values));Restore(history.Pop());}
        void Redo(){if(busy||future.Count==0)return;PushHistory(history,new(values));Restore(future.Pop());}
        undo.Click += (_,_) => Undo();redo.Click += (_,_) => Redo();
        foreach(var (key,modifiers,action) in new[]{(global::Windows.System.VirtualKey.Z,global::Windows.System.VirtualKeyModifiers.Control,(Action)Undo),
            (global::Windows.System.VirtualKey.Y,global::Windows.System.VirtualKeyModifiers.Control,(Action)Redo),
            (global::Windows.System.VirtualKey.Z,global::Windows.System.VirtualKeyModifiers.Control|global::Windows.System.VirtualKeyModifiers.Shift,(Action)Redo)})
        {
            var accelerator=new KeyboardAccelerator{Key=key,Modifiers=modifiers};accelerator.Invoked+=(_,e)=>{action();e.Handled=true;};((UIElement)editor.Window.Content).KeyboardAccelerators.Add(accelerator);
        }
        opacity.ValueChanged += (_,_) => Appearance(); skeletonToggle.Click += (_,_) => Appearance(); display.SelectionChanged += (_,_) => Appearance();
        camera.Click += (_,_) => editor.ResetCamera(side == "right");
        reset.Click += async (_,_) =>
        {
            if (busy || previewRunning) return; busy = true; save.IsEnabled = false; HistoryState();
            try { var result = await worker.ExecuteAsync(new { action="initialize",template_blend=template,target_mesh=source,mesh_data=preview,mirror_y=side=="right" },lifetime.Token); Install(result,true); history.Clear(); future.Clear(); }
            catch (Exception error) { if(!lifetime.IsCancellationRequested) editor.Status.Text=error.Message; }
            finally { busy=false; if (!lifetime.IsCancellationRequested) { HistoryState(); save.IsEnabled=true; } }
        };
        Task? saveOperation = null;
        save.Click += async (_,_) =>
        {
            if (saveOperation is { IsCompleted: false }) return;
            saveOperation = SaveFitAsync(); await saveOperation;
        };
        async Task SaveFitAsync()
        {
            if (busy || previewRunning || lifetime.IsCancellationRequested) return;
            busy=true; save.IsEnabled=false; HistoryState();
            try
            {
                var freshTarget = await Task.Run(() => { using var fresh = FileFingerprints.Fresh(); return MeshIdentity(source); });
                if (freshTarget != identity) throw new IOException("The target changed; review the fit against the current target before saving.");
                if (!projects.Contains(project) || SourceEar(project, side) != source || MeshIdentity(source)!=identity || runs.ContainsKey(project.Id) || outputOperations.Contains(project.Id)) throw new IOException("The target or project changed; reopen fitting before saving.");
                if (HasOutputsFrom(Stage.Preprocessing,project) && !await ConfirmOutputChangeAsync(project, reservation)) return;
                var generated=Path.Combine(workspace,"fit.stl"); var blend=Path.Combine(workspace,"fit.blend");
                var result=await worker.ExecuteAsync(new { action="save",parameters,controls=values,output=generated,blend_output=blend,mirror_y=side=="right" },lifetime.Token);
                freshTarget = await Task.Run(() => { using var fresh = FileFingerprints.Fresh(); return MeshIdentity(source); });
                if (lifetime.IsCancellationRequested || freshTarget!=identity) throw new IOException("The target changed while saving; the previous fit is preserved.");
                var folder=Path.Combine(project.SaveLocation,"Manual PPM");
                var files = new Dictionary<string, byte[]>();
                var templateCopy=template;
                if (File.Exists(template) && !ContainsPath(folder,template))
                {
                    var templates=Path.Combine(folder,"Templates");
                    templateCopy=Path.Combine(templates,Guid.NewGuid()+"-PPM.blend"); files[templateCopy] = await File.ReadAllBytesAsync(template, lifetime.Token);
                }
                var prefix=side=="left"?"Left":"Right";
                var fit=new ManualFit {Mesh=Path.Combine(folder,prefix+".stl"),Parameters=Path.Combine(folder,prefix+".json"),Blend=Path.Combine(folder,prefix+".blend"),Source=source,SourceIdentity=identity};
                var json=JsonSerializer.Serialize(new { parameters=result.GetProperty("parameters"),template_blend=templateCopy,source,source_identity=identity,side },new JsonSerializerOptions { WriteIndented=true });
                files[fit.Mesh] = await File.ReadAllBytesAsync(generated, lifetime.Token); files[fit.Blend] = await File.ReadAllBytesAsync(blend, lifetime.Token); files[fit.Parameters] = System.Text.Encoding.UTF8.GetBytes(json);
                await PublishEditorFilesAsync(project, files, lifetime.Token, expectedInputs: new() { [source] = identity[(identity.LastIndexOf(':') + 1)..] });
                if(side=="left")project.Settings.ManualPPM.Left=fit;else project.Settings.ManualPPM.Right=fit;
                project.Settings.ManualPPM.TemplateBlend=templateCopy;project.Settings.SelectEarModel("manual");
                project.Settings.Preprocessing.SourcePositionInputLeft=null;project.Settings.Preprocessing.SourcePositionInputRight=null;
                Persist();if(selectedProject==project){LoadSelectedProject();RefreshArtifacts();}RefreshPipelineStatus();if(!lifetime.IsCancellationRequested)editor.Status.Text="Manual fit saved and selected for preprocessing.";
            }
            catch(Exception error){if(!lifetime.IsCancellationRequested)editor.Status.Text=error.Message;}
            finally{busy=false;if(!lifetime.IsCancellationRequested){save.IsEnabled=true;HistoryState();}}
        }
        editor.Window.Activate(); editor.ResetCamera(side=="right"); editor.Status.Text="Loading BezierPPM and target mesh…";
        try
        {
            var result=await worker.ExecuteAsync(new {action="initialize",template_blend=template,saved_parameters=savedParameters??"",target_mesh=source,mesh_data=preview,mirror_y=side=="right"},lifetime.Token);
            if(!lifetime.IsCancellationRequested){Install(result,true);editor.ResetCamera(side=="right");editor.Status.Text="Adjust global alignment, convex features and concave details, then save.";}
        }
        catch(Exception error){if(!lifetime.IsCancellationRequested)editor.Status.Text=error.Message;}
        await closed.Task;
        if (saveOperation != null) await saveOperation;
        }
        finally
        {
            ForgetWindow();
            editorWindows.Remove(editor.Window);
            try { editor.Window.Close(); } catch { }
            try { Directory.Delete(workspace,true); } catch(IOException) { }
        }
    }

    static MeshGeometry3D ReadPPMPreview(string path,bool mirror)
    {
        using var reader=new BinaryReader(File.OpenRead(path));var vertices=reader.ReadUInt32();var faces=reader.ReadUInt32();
        if(vertices==0||faces==0||8L+vertices*16L+faces*12L!=reader.BaseStream.Length)throw new InvalidDataException("Malformed PPM preview.");
        var mesh=new MeshGeometry3D {Positions=new Vector3Collection(),Indices=new IntCollection(),Colors=new Color4Collection()};
        for(var i=0;i<vertices;i++){var p=new Vector3(reader.ReadSingle(),reader.ReadSingle(),reader.ReadSingle());if(!float.IsFinite(p.X)||!float.IsFinite(p.Y)||!float.IsFinite(p.Z))throw new InvalidDataException("Nonfinite PPM coordinates.");if(mirror)p.Y=-p.Y;mesh.Positions.Add(p);}
        for(long i=0;i<faces*3L;i++){var index=reader.ReadUInt32();if(index>=vertices)throw new InvalidDataException("Invalid PPM triangle.");mesh.Indices.Add((int)index);}
        if(mirror)for(var i=0;i<mesh.Indices.Count;i+=3)(mesh.Indices[i+1],mesh.Indices[i+2])=(mesh.Indices[i+2],mesh.Indices[i+1]);
        for(var i=0;i<vertices;i++){var d=reader.ReadSingle();var c=FieldColors.Distance(d);mesh.Colors.Add(new(c.X,c.Y,c.Z,c.W));}NativeEditor.Normals(mesh);return mesh;
    }

    static void CommitFitFiles(Dictionary<string,byte[]> files)
    {
        var originals=files.Keys.ToDictionary(path=>path,path=>File.Exists(path)?File.ReadAllBytes(path):null);
        try{foreach(var pair in files){var temporary=pair.Key+"."+Guid.NewGuid()+".tmp";try{File.WriteAllBytes(temporary,pair.Value);File.Move(temporary,pair.Key,true);}finally{if(File.Exists(temporary))File.Delete(temporary);}}}
        catch{foreach(var pair in originals){if(pair.Value==null){if(File.Exists(pair.Key))File.Delete(pair.Key);}else File.WriteAllBytes(pair.Key,pair.Value);}throw;}
    }
}
