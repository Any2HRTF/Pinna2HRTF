using Microsoft.UI.Xaml;
using Microsoft.UI.Windowing;
using System;
using System.Runtime.InteropServices;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;

namespace Pinna2HRTF.Windows;

public partial class App : Application
{
    Window? window;
    private AppInstance? keyInstance;
    private string instanceKey = "";
    #if PINNA_MAC_LAYOUT
    private const string InstanceKeyBase = "Pinna2HRTF.MacImitation.Instance";
#else
    private const string InstanceKeyBase = "Pinna2HRTF.Instance";
#endif
    private bool closedCleanupCompleted;

    [DllImport("user32.dll")]
    static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    static readonly IntPtr PerMonitorV2 = new(-4);

    public App()
    {
        _ = TimeZoneInfo.Local;
        var requestedCulture = Environment.GetEnvironmentVariable("PINNA2HRTF_CULTURE");
        if (!string.IsNullOrWhiteSpace(requestedCulture))
        {
            var culture = System.Globalization.CultureInfo.GetCultureInfo(requestedCulture);
            System.Globalization.CultureInfo.DefaultThreadCurrentCulture = culture;
            System.Globalization.CultureInfo.DefaultThreadCurrentUICulture = culture;
        }
        var instanceName = InstanceKeyBase;
        var reviewProfile = Environment.GetEnvironmentVariable("PINNA2HRTF_APP_DATA");
        if (!string.IsNullOrWhiteSpace(reviewProfile)) instanceName += ".Review." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(reviewProfile).ToLowerInvariant())))[..16];
        instanceKey = instanceName;
        _ = SetProcessDpiAwarenessContext(PerMonitorV2);
        UnhandledException += (_, error) =>
        {
            try
            {
                var profile = Environment.GetEnvironmentVariable("PINNA2HRTF_APP_DATA") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinna2HRTF-v2-review-macimitation");
                Directory.CreateDirectory(profile);
                File.WriteAllText(Path.Combine(profile,"startup-error.log"), error.Exception.ToString() + "\n" + error.Message);
            }
            catch { }
        };
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        keyInstance = AppInstance.FindOrRegisterForKey(instanceKey);
        if (!keyInstance.IsCurrent)
        {
            try
            {
                await Task.Run(async () => {
                    AppNotificationManager.Default.Register();
                    try { await keyInstance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()); }
                    finally { AppNotificationManager.Default.Unregister(); }
                });
            }
            catch { }
            Exit();
            return;
        }
        keyInstance.Activated += (_, activation) => {
            if (window is MainWindow main)
            {
                if (activation.Data is AppNotificationActivatedEventArgs notification) main.ActivateFromNotification(notification);
                else main.DispatcherQueue.TryEnqueue(() => main.Activate());
            }
        };
        try { window = new MainWindow(); }
        catch (Exception error)
        {
            var profile = Environment.GetEnvironmentVariable("PINNA2HRTF_APP_DATA") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinna2HRTF");
            Directory.CreateDirectory(profile);
            File.WriteAllText(Path.Combine(profile, "startup-error.log"), error.ToString());
            Exit();
            return;
        }
        window.Closed += (_, _) =>
        {
            if (closedCleanupCompleted) return;
            closedCleanupCompleted = true;
            try
            {
                if (window is MainWindow mainWindow)
                    mainWindow.ShutdownForAppClose();
            }
            catch
            {
            }
            finally
            {
                window = null;
                try { keyInstance?.UnregisterKey(); } catch { }
                keyInstance = null;

                try { Exit(); } finally { Environment.Exit(0); }
            }
        };
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
            presenter.Maximize();
        window.Activate();
    }
}
