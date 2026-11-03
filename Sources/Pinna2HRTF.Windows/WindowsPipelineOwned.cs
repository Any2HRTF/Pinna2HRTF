using System.Diagnostics;
using System.Text;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    async Task ObservePipelineAsync(OwnedProcess owned, PipelineLogCapture? capture, ProjectRecord project, Stage stage)
    {
        async Task Pump(StreamReader reader, string channel)
        {
            try
            {
            var chunk = new char[8192]; var line = new StringBuilder();
            while (true)
            {
                var count = await reader.ReadAsync(chunk).ConfigureAwait(false); if (count == 0) break;
                for (var i = 0; i < count; i++)
                {
                    if (chunk[i] == '\n') { capture?.Append(channel, line.ToString().TrimEnd('\r')); line.Clear(); }
                    else { line.Append(chunk[i]); if (line.Length > 2 * 1024 * 1024) throw new IOException("A tool log line exceeded the supported size."); }
                }
            }
            if (line.Length > 0) capture?.Append(channel, line.ToString());
            }
            catch { try { owned.Terminate(); } catch { } throw; }
        }
        var output = Pump(owned.Output, "stdout"); var error = Pump(owned.Error, "stderr");
        var code = -1;
        try
        {
            code = await owned.WaitAsync().ConfigureAwait(false);
            await Task.WhenAll(output, error).WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            if (owned.Cancelled) code = -1;
        }
        catch (Exception failure)
        {
            try { owned.Terminate(); await owned.WaitForEmptyAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } catch { }
            capture?.Append("capture", "Incomplete capture or process failure: " + failure.Message); code = -1;
        }
        finally
        {
            capture?.Dispose();
            _ = output.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
            _ = error.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
        }
        var result = code;
        if (!DispatcherQueue.TryEnqueue(async () =>
        {
            try { await ProcessFinishedAsync(owned.Process, project, stage, result); }
            catch (Exception failure)
            {
                FailedStages(project.Id).Add(stage); queuedStages.Remove(project.Id);
                if (runs.Remove(project.Id, out var run)) { run.Outputs?.ReleaseForRecovery(); run.Reservation?.Dispose(); }
                outputOperations.Remove(project.Id);
                AppendLog("Could not finalize the stage; output tracking remains recoverable: " + failure, project.Id);
            }
            finally { owned.Dispose(); }
        })) owned.Dispose();
    }
}
