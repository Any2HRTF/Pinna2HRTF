using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using System;
using System.Runtime.InteropServices;

namespace Pinna2HRTF.Windows;

public partial class App : Application
{
    Window? window;

    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    static readonly IntPtr PerMonitorV2 = new(-4);

    public App()
    {
        // Render at the monitor's native DPI instead of allowing Windows to
        // bitmap-scale the complete unpackaged process at 125%/150%/200%.
        _ = SetProcessDpiAwarenessContext(PerMonitorV2);
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
            presenter.Maximize();
        window.Activate();
    }
}
