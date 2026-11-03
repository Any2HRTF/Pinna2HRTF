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
