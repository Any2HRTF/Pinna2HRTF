using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Pinna2HRTF.Windows;

public partial class App : Application
{
    Window? window;
    private Mutex? instanceMutex;
    private const string InstanceMutexName = @"Local\Pinna2HRTF.Instance";

    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    static readonly IntPtr PerMonitorV2 = new(-4);

    public App()
    {
        // Keep a named marker alive for the whole process lifetime. Inno Setup
        // uses the same mutex to detect a running app before install/uninstall.
        bool createdNew;
        instanceMutex = new Mutex(initiallyOwned: true, name: InstanceMutexName, createdNew: out createdNew);
        // Render at the monitor's native DPI instead of allowing Windows to
        // bitmap-scale the complete unpackaged process at 125%/150%/200%.
        _ = SetProcessDpiAwarenessContext(PerMonitorV2);
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Closed += (_, _) =>
        {
            if (window is MainWindow mainWindow)
                mainWindow.ShutdownForAppClose();
            window = null;
            try { instanceMutex?.ReleaseMutex(); } catch (ApplicationException) { }
            instanceMutex?.Dispose();
            instanceMutex = null;
            Exit();
        };
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
            presenter.Maximize();
        window.Activate();
    }
}
