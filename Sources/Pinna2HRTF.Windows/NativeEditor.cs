using HelixToolkit;
using HelixToolkit.Maths;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Numerics;

namespace Pinna2HRTF.Windows;

internal sealed class NativeEditor
{
    public Window Window { get; } = new();
    public Viewport3DX Viewport { get; }
    public Grid ViewportHost { get; } = new();
    public Button NavigationButton { get; } = NavigationHelp.Create();
    public TextBlock Subtitle { get; } = new() { FontSize = 11, Visibility = Visibility.Collapsed, TextTrimming = TextTrimming.CharacterEllipsis };
    public StackPanel Controls { get; } = new() { Spacing = 10, Margin = new Thickness(12) };
    public StackPanel PinnedControls { get; } = new() { Spacing = 8, Margin = new Thickness(12) };
    public StackPanel Toolbar { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(12) };
    public TextBlock Status { get; } = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12) };
    public StackPanel FooterLeading { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    public StackPanel FooterActions { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
    public Border FooterHost { get; } = new() { Visibility = Visibility.Collapsed, Padding = new Thickness(12) };
    readonly DefaultEffectsManager effects = new();
    public NativeEditor(string title, FrameworkElement? owner = null)
    {
        Window.Title = title;
        Viewport = new Viewport3DX { EffectsManager = effects, UseDefaultGestures = true, InputController = new MeshInputController(),
            ModelUpDirection = Vector3.UnitZ, ShowCoordinateSystem = true, CoordinateSystemVerticalPosition = .8, ShowViewCube = false, BackgroundColor = ColorHelper.FromArgb(255, 237, 243, 242) };
        EvenMeshLighting.Install(Viewport);
        var root = new Grid { RequestedTheme = owner?.ActualTheme ?? ElementTheme.Default };
        root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new()); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var header = new Grid { Padding = new Thickness(12, 4, 0, 4), MinHeight = 54, ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new()); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var drag = new Grid(); var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        titles.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        titles.Children.Add(Subtitle); drag.Children.Add(titles);
        header.Children.Add(drag); Toolbar.Margin = new Thickness(0); Toolbar.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(Toolbar, 1); header.Children.Add(Toolbar);
        root.Children.Add(header); Grid.SetRow(Status, 2); root.Children.Add(Status);
        var body = new Grid(); body.ColumnDefinitions.Add(new()); body.ColumnDefinitions.Add(new() { Width = new GridLength(MainWindow.MacLayout ? 320 : 370) });
        ViewportHost.Children.Add(Viewport);
        NavigationButton.HorizontalAlignment = HorizontalAlignment.Left; NavigationButton.VerticalAlignment = VerticalAlignment.Bottom; NavigationButton.Margin = new Thickness(12); ViewportHost.Children.Add(NavigationButton);
        body.Children.Add(ViewportHost);
        var scroll = new ScrollViewer { Content = Controls, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var inspector = new Grid(); inspector.RowDefinitions.Add(new() { Height = GridLength.Auto }); inspector.RowDefinitions.Add(new());
        inspector.Children.Add(PinnedControls); Grid.SetRow(scroll, 1); inspector.Children.Add(scroll);
        Grid.SetColumn(inspector, 1); body.Children.Add(inspector); Grid.SetRow(body, 1); root.Children.Add(body);
        if (MainWindow.MacLayout)
        {
            var actions = new Grid(); actions.ColumnDefinitions.Add(new()); actions.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            actions.Children.Add(FooterLeading); Grid.SetColumn(FooterActions, 1); actions.Children.Add(FooterActions);
            FooterHost.Child = actions; root.RowDefinitions.Add(new() { Height = GridLength.Auto }); Grid.SetRow(FooterHost, 3); root.Children.Add(FooterHost);
        }
        Window.Content = root;
        var chrome = new WindowChrome(Window, root, header, drag, minimumWidth: 900, minimumHeight: 640);
        var navigation = new SharedNavigation(Viewport);
        // Each native editor is a separate XAML root. Give it its own themed
        // surfaces and keep it in step with the main window, including popups.
        void Appearance()
        {
            var dark = root.ActualTheme == ElementTheme.Dark;
            root.Background = new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 32, 32, 32) : Colors.White);
            inspector.Background = new SolidColorBrush(dark ? ColorHelper.FromArgb(255, 45, 45, 45) : ColorHelper.FromArgb(255, 251, 251, 252));
            Viewport.BackgroundColor = dark ? ColorHelper.FromArgb(255, 31, 36, 38) : ColorHelper.FromArgb(255, 237, 243, 242);
            Viewport.CoordinateSystemLabelForeground = dark ? Colors.White : Colors.DarkSlateGray;
        }
        void OwnerThemeChanged(FrameworkElement sender, object args) => root.RequestedTheme = sender.ActualTheme;
        root.ActualThemeChanged += (_, _) => Appearance();
        root.Loaded += (_, _) => Appearance();
        if (owner != null) owner.ActualThemeChanged += OwnerThemeChanged;
        Appearance();
        var displayId = owner?.XamlRoot?.ContentIslandEnvironment.AppWindowId ?? Window.AppWindow.Id;
        var area=Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(displayId,Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(1500, area.Width); var height = Math.Min(1000, area.Height);
        Window.AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
        Window.Closed += (_, _) => { navigation.Dispose(); chrome.Dispose(); if (owner != null) owner.ActualThemeChanged -= OwnerThemeChanged; try { Viewport.Detach(); effects.Dispose(); } catch { } };
    }
    public void CombineStatusAndActions()
    {
        if (Window.Content is not Grid root || FooterHost.Child is not Grid footer) return;
        root.Children.Remove(Status); footer.Children.Remove(FooterLeading);
        Status.Margin = new Thickness(0); Status.VerticalAlignment = VerticalAlignment.Center; Status.FontSize = 12;
        Status.TextWrapping = TextWrapping.NoWrap; Status.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTipService.SetToolTip(Status, Status.Text);
        Status.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => ToolTipService.SetToolTip(Status, Status.Text));
        footer.ColumnSpacing = 16; Grid.SetColumn(Status, 0); Grid.SetRow(Status, 0); footer.Children.Add(Status);
    }

    public void ResetCamera(bool right = false)
    {
        var side = right ? -1f : 1f;
        var points=Viewport.Items.OfType<MeshGeometryModel3D>().Where(m=>m.Geometry?.Positions!=null).SelectMany(m=>m.Geometry!.Positions!).ToArray();
        var low=points.Length==0?new Vector3(-1):points.Aggregate(Vector3.Min);
        var high=points.Length==0?new Vector3(1):points.Aggregate(Vector3.Max);
        var target=(low+high)/2;var distance=Math.Max(Vector3.Distance(low,high)*1.8f,.001f);
        var offset=new Vector3(0,side*distance,distance*.08f);
        Viewport.Camera = new PerspectiveCamera { Position = target+offset, LookDirection = -offset, UpDirection = Vector3.UnitZ, FieldOfView = 38,
            NearPlaneDistance=distance/10000,FarPlaneDistance=distance*100 };
    }
    public static MeshGeometry3D RawMesh(string path)
    {
        var loaded = MeshLoader.Load(path);
        var positions=loaded.Geometry.Positions??throw new InvalidDataException("The target mesh has no vertices.");
        for (var i=0; i<positions.Count; i++) positions[i] = loaded.ToRaw(positions[i]);
        loaded.Geometry.UpdateBounds();
        return loaded.Geometry;
    }
    public static MeshGeometryModel3D Model(MeshGeometry3D geometry, bool colors = false) => new()
    {
        Geometry = geometry, CullMode = SharpDX.Direct3D11.CullMode.None,
        Material = colors ? new DiffuseMaterial { DiffuseColor=new Color4(1,1,1,1),VertexColorBlendingFactor=1,EnableUnLit=true }
            : new PhongMaterial { DiffuseColor = new Color4(.6f,.72f,.7f,1), AmbientColor = new Color4(.5f,.5f,.5f,1) }
    };
    public static void Normals(MeshGeometry3D geometry)
    {
        var positions=geometry.Positions??throw new InvalidDataException("Missing vertices.");
        var indices=geometry.Indices??throw new InvalidDataException("Missing triangles.");
        var normals = new Vector3[positions.Count];
        for (var i=0; i<indices.Count; i+=3)
        {
            var a=indices[i]; var b=indices[i+1]; var c=indices[i+2];
            var normal=Vector3.Cross(positions[b]-positions[a], positions[c]-positions[a]);
            normals[a]+=normal; normals[b]+=normal; normals[c]+=normal;
        }
        geometry.Normals = new Vector3Collection(normals.Select(n => n.LengthSquared() > 1e-20f ? Vector3.Normalize(n) : Vector3.UnitZ));
        geometry.UpdateBounds();
    }
}
