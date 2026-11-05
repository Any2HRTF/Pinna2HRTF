using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    async Task ObserveUiTaskAsync(Task task, string operation, ProjectRecord? project = null)
    {
        try { await task; }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (project != null) queuedStages.Remove(project.Id);
            try { AppendLog(operation + " failed: " + error, project?.Id); if (!shutdownCleanupDone) RefreshPipelineStatus(); } catch { }
        }
    }
    void ProtectEditorClose(Microsoft.UI.Xaml.Window window, Func<bool> busy, Func<bool> dirty)
    {
        var confirmed = false;
        var prompting = false;
        window.AppWindow.Closing += async (_, args) =>
        {
            if (confirmed || shutdownCleanupDone) return;
            if (busy()) { args.Cancel = true; return; }
            if (!dirty()) return;
            args.Cancel = true;
            if (prompting) return;
            prompting = true;
            try
            {
                var dialog = new Microsoft.UI.Xaml.Controls.ContentDialog {
                    Title = "Discard unsaved changes?", PrimaryButtonText = "Discard",
                    CloseButtonText = "Keep editing", DefaultButton = Microsoft.UI.Xaml.Controls.ContentDialogButton.Close,
                    XamlRoot = ((Microsoft.UI.Xaml.FrameworkElement)window.Content).XamlRoot
                };
                if (await dialog.ShowAsync() == Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary)
                {
                    confirmed = true;
                    window.Close();
                }
            }
            finally { prompting = false; }
        };
    }

    void WriteRuntimeInfo()
    {
        try
        {
            var info = new { culture = CultureInfo.CurrentCulture.Name, uiCulture = CultureInfo.CurrentUICulture.Name,
                os = Environment.OSVersion.VersionString, runtime = RuntimeInformation.FrameworkDescription,
                app = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
                packageRoot, profile = appData, layout = MacLayout ? "Mac-imitation" : "Windows" };
            File.WriteAllText(Path.Combine(appData, "runtime-info.json"), JsonSerializer.Serialize(info, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}
