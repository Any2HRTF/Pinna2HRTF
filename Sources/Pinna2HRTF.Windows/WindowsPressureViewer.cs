using HelixToolkit;
using HelixToolkit.Maths;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Numerics;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    async Task OpenPressureViewerAsync(Artifact artifact)
    {
        var editor = new NativeEditor(artifact.Title, Root);
        editorWindows.Add(editor.Window);
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(editorLifetime.Token);
        editor.Window.Closed += (_, _) => { lifetime.Cancel(); editorWindows.Remove(editor.Window); };
        var steps = new ComboBox { Header = "Frequency", HorizontalAlignment = HorizontalAlignment.Stretch };
        var surfaces = new ComboBox { Header = "Surface", HorizontalAlignment = HorizontalAlignment.Stretch };
        var quantities = new ComboBox { Header = "Quantity", ItemsSource = new[] { "Level", "Magnitude", "Phase", "Real", "Imaginary" }, SelectedIndex = 0 };
        var locked = new CheckBox { Content = "Lock color scale" };
        var legend = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = new Button { Content = "Refresh" }; var reset = NavigationHelp.Command("Reset view");
        editor.Toolbar.Children.Add(refresh); editor.Toolbar.Children.Add(reset);
        foreach (var element in new FrameworkElement[] { steps, surfaces, quantities, locked, legend }) editor.Controls.Children.Add(element);
        editor.Controls.Children.Add(new TextBlock { Text = "Raw solver pressure before SOFA normalization.", TextWrapping = TextWrapping.Wrap });
        var catalog = new List<JsonElement>(); var changing = false; var revision = 0;
        MeshGeometryModel3D? visual = null; JsonElement? frame = null; string? loadedSurface = null;
        (double Low, double High)? colorRange = null;
        void Recolor()
        {
            if (frame is not { } f) return;
            var quantity = quantities.SelectedItem as string ?? "Level";
            var real = f.GetProperty("real").EnumerateArray().Select(x => x.GetDouble()).ToArray();
            var imaginary = f.GetProperty("imaginary").EnumerateArray().Select(x => x.GetDouble()).ToArray();
            if (real.Length != imaginary.Length || real.Any(x => !double.IsFinite(x)) || imaginary.Any(x => !double.IsFinite(x))) throw new InvalidDataException("Invalid pressure values.");
            var values = real.Zip(imaginary, (r,i) => FieldColors.Value(quantity,r,i)).ToArray();
            if (locked.IsChecked != true || colorRange == null) colorRange = FieldColors.Range(quantity, values);
            var range = colorRange.Value;
            var points = f.GetProperty("vertices").EnumerateArray().Select(x => x.EnumerateArray().Select(v => v.GetSingle()).ToArray()).ToArray();
            if (points.Any(p => p.Length != 3 || p.Any(v => !float.IsFinite(v)))) throw new InvalidDataException("Invalid pressure coordinates.");
            var geometry = new MeshGeometry3D { Positions = new Vector3Collection(), Indices = new IntCollection(), Colors = new Color4Collection() };
            var cell = f.GetProperty("association").GetString() == "cell"; var face = 0;
            var triangles = f.GetProperty("triangles").EnumerateArray().ToArray();
            if (values.Length != (cell ? triangles.Length : points.Length) || !points.Any() || !triangles.Any()) throw new InvalidDataException("Pressure data does not match the geometry.");
            foreach (var triangle in triangles)
            {
                var indices = triangle.EnumerateArray().Select(x => x.GetInt32()).ToArray();
                if (indices.Length != 3 || indices.Any(i => i < 0 || i >= points.Length)) throw new InvalidDataException("Invalid pressure face indices.");
                foreach (var index in indices)
                {
                    var point = points[index]; geometry.Positions.Add(new(point[0],point[1],point[2]));
                    geometry.Indices.Add(geometry.Indices.Count);
                    var c = FieldColors.Color(quantity,values[cell ? face : index],range.Low,range.High);
                    geometry.Colors.Add(new(c.X,c.Y,c.Z,c.W));
                }
                face++;
            }
            NativeEditor.Normals(geometry);
            if (visual != null) editor.Viewport.Items.Remove(visual);
            visual = NativeEditor.Model(geometry, true); editor.Viewport.Items.Add(visual);
            var surface = surfaces.SelectedItem as string ?? "Boundary";
            if (loadedSurface != surface) { editor.ResetCamera(artifact.Side == "right"); loadedSurface = surface; }
            var unit = quantity == "Level" ? "dB re 20 µPa" : quantity == "Phase" ? "rad" : "Pa";
            legend.Text = $"{range.Low:G5} — {range.High:G5} {unit}\nGray: undefined phase. Zero pressure: −160 dB display floor.";
        }
        async Task Load()
        {
            if (changing || steps.SelectedIndex < 0 || surfaces.SelectedItem is not string surface) return;
            var requested = ++revision; editor.Status.Text = "Loading pressure…";
            try
            {
                var step = catalog[steps.SelectedIndex].GetProperty("id").GetInt32();
                var result = await RequestPythonAsync("HRTFCalculation.PressureField", new { action = "frame", source = artifact.Path, step, surface }, lifetime.Token);
                if (lifetime.IsCancellationRequested || revision != requested) return;
                frame = result; Recolor(); editor.Status.Text = "Pressure loaded.";
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (revision != requested || lifetime.IsCancellationRequested) return;
                frame = null; if (visual != null) editor.Viewport.Items.Remove(visual); visual = null; editor.Status.Text = error.Message;
            }
        }
        void UpdateSurfaces()
        {
            if (steps.SelectedIndex < 0) return;
            changing = true; var previous = surfaces.SelectedItem as string;
            var available = catalog[steps.SelectedIndex].GetProperty("surfaces").EnumerateArray().Select(x => x.GetString()!).ToArray();
            surfaces.ItemsSource = available; surfaces.SelectedItem = available.Contains(previous) ? previous : available.FirstOrDefault(); changing = false;
        }
        async Task Inspect()
        {
            var requested = ++revision; editor.Status.Text = "Finding calculated frequencies…";
            try
            {
                var result = await RequestPythonAsync("HRTFCalculation.PressureField", new { action = "inspect", source = artifact.Path }, lifetime.Token);
                if (lifetime.IsCancellationRequested || requested != revision) return;
                var old = steps.SelectedIndex >= 0 && steps.SelectedIndex < catalog.Count ? catalog[steps.SelectedIndex].GetProperty("id").GetInt32() : -1;
                catalog = result.GetProperty("steps").EnumerateArray().Select(x => x.Clone()).ToList();
                changing = true;
                steps.ItemsSource = catalog.Select(s => s.TryGetProperty("frequency",out var hz) && hz.ValueKind == JsonValueKind.Number ? $"{hz.GetDouble():G8} Hz" : $"Step {s.GetProperty("id")}").ToArray();
                steps.SelectedIndex = Math.Max(0,catalog.FindIndex(s => s.GetProperty("id").GetInt32() == old)); changing = false;
                UpdateSurfaces(); await Load();
                if (catalog.Count == 0) editor.Status.Text = "No calculated pressure steps are available.";
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!lifetime.IsCancellationRequested && revision == requested) editor.Status.Text = error.Message; }
        }
        steps.SelectionChanged += async (_,_) => { if (!changing) { UpdateSurfaces(); await Load(); } };
        surfaces.SelectionChanged += async (_,_) => await Load();
        quantities.SelectionChanged += (_,_) => { colorRange = null; if (frame != null) Recolor(); };
        locked.Click += (_,_) => { colorRange = null; if (frame != null) Recolor(); };
        reset.Click += (_,_) => editor.ResetCamera(artifact.Side == "right"); refresh.Click += async (_,_) => await Inspect();
        editor.Window.Activate(); await Inspect();
        // Keep cancellation alive for the whole window, not merely initialization.
        var closed = new TaskCompletionSource(); editor.Window.Closed += (_,_) => closed.TrySetResult();
        if (!lifetime.IsCancellationRequested) await closed.Task;
    }
}
