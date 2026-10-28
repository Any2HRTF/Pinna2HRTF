using System.Text;
using System.Text.Json;

namespace Pinna2HRTF.Windows;

sealed class PipelineLogEvent
{
    public string Message { get; init; } = "";
    public string? Level { get; init; }
    public string? Key { get; init; }
}

/// <summary>Saves complete child-process output and forwards explicit progress events.</summary>
sealed class PipelineLogCapture : IDisposable
{
    public const string EventPrefix = "@@PINNA2HRTF_EVENT@@";

    readonly object sync = new();
    readonly Action<PipelineLogEvent> onEvent;
    readonly Action<string> onFailure;
    StreamWriter? writer;
    bool didReportFailure;

    public PipelineLogCapture(string filePath, string header, Action<PipelineLogEvent> onEvent, Action<string> onFailure)
    {
        this.onEvent = onEvent;
        this.onFailure = onFailure;
        Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
        writer = new StreamWriter(new FileStream(filePath, FileMode.CreateNew, FileAccess.Write, FileShare.Read), new UTF8Encoding(false)) { AutoFlush = true };
        writer.WriteLine(header);
    }

    public void Append(string stream, string? line)
    {
        if (line == null) return;
        PipelineLogEvent? progress = null;
        string? failure = null;
        lock (sync)
        {
            try { writer?.WriteLine($"[{stream}] {line}"); }
            catch (Exception error)
            {
                if (!didReportFailure)
                {
                    didReportFailure = true;
                    failure = error.Message;
                }
            }
            if (line.StartsWith(EventPrefix, StringComparison.Ordinal))
            {
                try { progress = JsonSerializer.Deserialize<PipelineLogEvent>(line[EventPrefix.Length..], new JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
                catch { }
                if (string.IsNullOrWhiteSpace(progress?.Message)) progress = null;
            }
        }
        if (failure != null) onFailure(failure);
        if (progress != null) onEvent(progress);
    }

    public void Dispose()
    {
        lock (sync)
        {
            try { writer?.Flush(); } catch { }
            try { writer?.Dispose(); } catch { }
            finally { writer = null; }
        }
    }
}
