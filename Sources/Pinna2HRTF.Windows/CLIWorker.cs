using System.Diagnostics;
using System.Text;
using System.Text.Json;
namespace Pinna2HRTF.Windows;

internal sealed class CLIWorker : IDisposable
{
    readonly OwnedProcess owned;
    readonly SemaphoreSlim gate = new(1);
    readonly Task diagnostics;
    readonly StringBuilder pending = new();
    string diagnosticTail = "";
    readonly TimeSpan requestTimeout;
    volatile bool disposed;
    public CLIWorker(ProcessStartInfo info, Guid project, TimeSpan? requestTimeout = null)
    {
        this.requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(600);
        owned = OwnedProcess.Start(info, project);
        diagnostics = DrainDiagnosticsAsync();
    }
    async Task DrainDiagnosticsAsync()
    {
        var buffer = new char[4096];
        try
        {
            while (true)
            {
                var count = await owned.Error.ReadAsync(buffer).ConfigureAwait(false); if (count == 0) break;
                var text = diagnosticTail + new string(buffer, 0, count);
                diagnosticTail = text.Length > 65536 ? text[^65536..] : text;
            }
        }
        catch (Exception) when (disposed) { }
    }
    async Task<string> ReplyAsync(CancellationToken token)
    {
        var buffer = new char[4096];
        while (true)
        {
            for (var i = 0; i < pending.Length; i++)
                if (pending[i] == '\n') { var line = pending.ToString(0, i).TrimEnd('\r'); pending.Remove(0, i + 1); return line; }
            var count = await owned.Output.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false);
            if (count == 0) throw new IOException("The CLI worker closed its output. " + diagnosticTail);
            if (pending.Length + count > 8 * 1024 * 1024) throw new IOException("The CLI worker response exceeded its size limit.");
            pending.Append(buffer, 0, count);
        }
    }
    public async Task<JsonElement> RequestAsync(object request, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(requestTimeout);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (owned.Process.HasExited) throw new IOException("The CLI worker stopped. " + diagnosticTail);
            await owned.Input.WriteLineAsync(JsonSerializer.Serialize(request).AsMemory(), deadline.Token).ConfigureAwait(false);
            await owned.Input.FlushAsync(deadline.Token).ConfigureAwait(false);
            for (var skipped = 0; skipped < 256; skipped++)
            {
                var response = await ReplyAsync(deadline.Token).ConfigureAwait(false);
                if (!response.TrimStart().StartsWith('{')) continue;
                using var document = JsonDocument.Parse(response);
                if (document.RootElement.ValueKind != JsonValueKind.Object) throw new IOException("Invalid CLI worker response.");
                if (document.RootElement.TryGetProperty("error", out var error)) throw new IOException(error.GetString());
                return document.RootElement.Clone();
            }
            throw new IOException("The CLI worker returned diagnostics without a JSON response.");
        }
        catch { Dispose(); throw; }
        finally { gate.Release(); }
    }
    public async Task<JsonElement> ExecuteAsync(object request, CancellationToken token)
    {
        var result = await RequestAsync(request, token).ConfigureAwait(false);
        if (!result.TryGetProperty("parameters", out var parameters) || parameters.ValueKind != JsonValueKind.Object ||
            !parameters.EnumerateObject().Any() || parameters.EnumerateObject().Any(p => p.Value.ValueKind != JsonValueKind.Number || !p.Value.TryGetDouble(out var value) || !double.IsFinite(value)) ||
            !result.TryGetProperty("controls", out var controls) || controls.ValueKind != JsonValueKind.Array)
            throw new IOException("Incomplete fitting response.");
        return result;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true; owned.Dispose();
        _ = diagnostics.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
    }
}
