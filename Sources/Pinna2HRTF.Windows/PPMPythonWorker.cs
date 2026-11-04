using System.Diagnostics;
using System.Text;
using System.Text.Json;
namespace Pinna2HRTF.Windows;

internal sealed class PPMPythonWorker : IDisposable
{
    readonly OwnedProcess owned;
    readonly SemaphoreSlim gate = new(1);
    readonly Task diagnostics;
    readonly StringBuilder pending = new();
    string diagnosticTail = "";
    volatile bool disposed;
    public PPMPythonWorker(ProcessStartInfo info, Guid project)
    {
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
            if (count == 0) throw new IOException("The fitting worker closed its output. " + diagnosticTail);
            if (pending.Length + count > 8 * 1024 * 1024) throw new IOException("The fitting worker response exceeded its size limit.");
            pending.Append(buffer, 0, count);
        }
    }
    public async Task<JsonElement> ExecuteAsync(object request, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(600));
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (owned.Process.HasExited) throw new IOException("The fitting worker stopped. " + diagnosticTail);
            await owned.Input.WriteLineAsync(JsonSerializer.Serialize(request).AsMemory(), deadline.Token).ConfigureAwait(false);
            await owned.Input.FlushAsync(deadline.Token).ConfigureAwait(false);
            for (var skipped = 0; skipped < 256; skipped++)
            {
                var response = await ReplyAsync(deadline.Token).ConfigureAwait(false);
                if (!response.TrimStart().StartsWith('{')) continue;
                using var document = JsonDocument.Parse(response);
                if (document.RootElement.ValueKind != JsonValueKind.Object) throw new IOException("Invalid fitting worker response.");
                if (document.RootElement.TryGetProperty("error", out var error)) throw new IOException(error.GetString());
                if (!document.RootElement.TryGetProperty("parameters", out var parameters) || parameters.ValueKind != JsonValueKind.Object ||
                    !parameters.EnumerateObject().Any() || parameters.EnumerateObject().Any(p => p.Value.ValueKind != JsonValueKind.Number || !p.Value.TryGetDouble(out var value) || !double.IsFinite(value)) ||
                    !document.RootElement.TryGetProperty("controls", out var controls) || controls.ValueKind != JsonValueKind.Array)
                    throw new IOException("Incomplete or invalid fitting worker response. Reopen fitting to start a new session.");
                return document.RootElement.Clone();
            }
            throw new IOException("The fitting worker returned diagnostics without a JSON response.");
        }
        catch { Dispose(); throw; } // Never reuse a timed out/desynchronized session.
        finally { gate.Release(); }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; owned.Dispose();
        _ = diagnostics.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
    }
}
