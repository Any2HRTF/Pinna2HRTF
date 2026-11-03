using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

// One title-bar contract for main and editor windows. All layout sizes are DIPs;
// Windows reports caption insets in physical pixels, including on mixed-DPI PCs.
internal sealed class WindowChrome : IDisposable
{
    readonly Window window;
    readonly FrameworkElement root;
    readonly Grid header;
    readonly Thickness padding;
    readonly int minimumWidth, minimumHeight;
    bool updating, disposed;
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out Rect value, int size);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }

    public WindowChrome(Window window, FrameworkElement root, Grid header, UIElement dragRegion, int minimumWidth = 0, int minimumHeight = 0)
    {
        this.window = window; this.root = root; this.header = header; padding = header.Padding;
        this.minimumWidth = minimumWidth; this.minimumHeight = minimumHeight;
        window.ExtendsContentIntoTitleBar = true;
        window.SetTitleBar(dragRegion);
        if (AppWindowTitleBar.IsCustomizationSupported()) window.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        root.UseLayoutRounding = true;
        root.Loaded += Loaded;
        root.ActualThemeChanged += ThemeChanged;
        header.SizeChanged += HeaderChanged;
        window.Activated += Activated;
        window.AppWindow.Changed += Changed;
        Update();
    }
    void Loaded(object sender, RoutedEventArgs e) => Update();
    void ThemeChanged(FrameworkElement sender, object e) => Update();
    void HeaderChanged(object sender, SizeChangedEventArgs e) => Update();
    void Activated(object sender, WindowActivatedEventArgs e) => Update();
    void Changed(AppWindow sender, AppWindowChangedEventArgs e) => root.DispatcherQueue.TryEnqueue(Update);
    void Update()
    {
        if (disposed || updating) return;
        updating = true;
        try
        {
            var dark = root.ActualTheme == ElementTheme.Dark;
            var background = dark ? ColorHelper.FromArgb(255, 45, 45, 45) : ColorHelper.FromArgb(255, 251, 251, 252);
            header.Background = new SolidColorBrush(background);
            var bar = window.AppWindow.TitleBar;
            var scale = root.XamlRoot?.RasterizationScale ?? GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96d;
            if (scale <= 0) scale = 1;
            if (window.AppWindow.Presenter is OverlappedPresenter presenter)
            {
                var width = (int)Math.Ceiling(minimumWidth * scale); var height = (int)Math.Ceiling(minimumHeight * scale);
                if (width > 0 && presenter.PreferredMinimumWidth != width) presenter.PreferredMinimumWidth = width;
                if (height > 0 && presenter.PreferredMinimumHeight != height) presenter.PreferredMinimumHeight = height;
            }
            header.Padding = new Thickness(padding.Left + bar.LeftInset / scale, padding.Top, padding.Right + bar.RightInset / scale, padding.Bottom);
            if (AppWindowTitleBar.IsCustomizationSupported())
            {
                bar.BackgroundColor = background; bar.InactiveBackgroundColor = background;
                bar.ForegroundColor = dark ? Colors.White : Colors.Black;
                bar.InactiveForegroundColor = dark ? Colors.LightGray : Colors.DimGray;
                bar.ButtonBackgroundColor = Colors.Transparent; bar.ButtonInactiveBackgroundColor = Colors.Transparent;
                bar.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
                bar.ButtonInactiveForegroundColor = dark ? Colors.LightGray : Colors.DimGray;
                bar.ButtonHoverBackgroundColor = dark ? ColorHelper.FromArgb(255, 65, 65, 65) : ColorHelper.FromArgb(255, 230, 230, 230);
                bar.ButtonPressedBackgroundColor = dark ? ColorHelper.FromArgb(255, 80, 80, 80) : ColorHelper.FromArgb(255, 215, 215, 215);
            }
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            var immersive = dark ? 1 : 0;
            _ = DwmSetWindowAttribute(hwnd, 20, ref immersive, sizeof(int));
            // Win11's non-client frame is outside the XAML background. Theme it
            // explicitly: the default light frame otherwise remains a thin strip.
            // Unsupported attributes return HRESULTs on Win10 without changing it.
            var border = background.R | background.G << 8 | background.B << 16;
            var borderResult = DwmSetWindowAttribute(hwnd, 34, ref border, sizeof(int));
            Diagnose(hwnd, scale, borderResult);
        }
        finally { updating = false; }
    }
    void Diagnose(IntPtr hwnd, double scale, int borderResult)
    {
        var path = Environment.GetEnvironmentVariable("PINNA2HRTF_CHROME_DIAGNOSTICS");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) return;
        try
        {
            GetWindowRect(hwnd, out var windowRect); GetClientRect(hwnd, out var client); var origin = new Point(); ClientToScreen(hwnd, ref origin);
            DwmGetWindowAttribute(hwnd, 9, out var frame, Marshal.SizeOf<Rect>());
            var areas = DisplayArea.FindAll(); var displays = new List<object>();
            for (var i = 0; i < areas.Count; i++)
            {
                var d = areas[i]; displays.Add(new { primary = d.IsPrimary, bounds = new[] { d.OuterBounds.X, d.OuterBounds.Y, d.OuterBounds.Width, d.OuterBounds.Height } });
            }
            File.AppendAllText(path, JsonSerializer.Serialize(new { title = window.Title, scale, dpi = GetDpiForWindow(hwnd),
                window = new[] { windowRect.Left, windowRect.Top, windowRect.Right, windowRect.Bottom },
                client = new[] { origin.X, origin.Y, client.Right, client.Bottom }, frame = new[] { frame.Left, frame.Top, frame.Right, frame.Bottom },
                header = new[] { header.ActualWidth, header.ActualHeight }, captionInset = window.AppWindow.TitleBar.RightInset, borderResult,
                displays }) + Environment.NewLine);
        }
        catch (Exception) { } // Optional diagnostics must never prevent a window from opening.
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        root.Loaded -= Loaded; root.ActualThemeChanged -= ThemeChanged; header.SizeChanged -= HeaderChanged;
        window.Activated -= Activated; window.AppWindow.Changed -= Changed;
    }
}
