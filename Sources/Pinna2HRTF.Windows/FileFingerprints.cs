using System.Collections.Concurrent;
using System.Security.Cryptography;
namespace Pinna2HRTF.Windows;

internal static class FileFingerprints
{
    static readonly ConcurrentDictionary<string, string> cache = new(StringComparer.OrdinalIgnoreCase);
    static readonly ConcurrentDictionary<string, Task> warming = new(StringComparer.OrdinalIgnoreCase);
    static readonly AsyncLocal<bool> fresh = new();
    public static int UiThread { get; set; }
    public static Action? Ready { get; set; }
    public static void Invalidate(IEnumerable<string> paths)
    {
        var prefixes = paths.Select(p => Path.GetFullPath(p) + "|").ToArray();
        foreach (var key in cache.Keys) if (prefixes.Any(p => key.StartsWith(p, StringComparison.OrdinalIgnoreCase))) cache.TryRemove(key, out _);
    }
    public static IDisposable Fresh()
    { var previous = fresh.Value; fresh.Value = true; return new Scope(() => fresh.Value = previous); }
    sealed class Scope(Action release) : IDisposable { public void Dispose() => release(); }
    public static string Hash(string path)
    {
        path = Path.GetFullPath(path); var before = new FileInfo(path);
        var key = path + "|" + before.Length + "|" + before.LastWriteTimeUtc.Ticks;
        if (!fresh.Value && cache.TryGetValue(key, out var saved)) return saved;
        if (Environment.CurrentManagedThreadId == UiThread)
        {
            warming.GetOrAdd(key, ignored => Task.Run(() => { try { Hash(path); } catch { } finally { warming.TryRemove(key, out _); Ready?.Invoke(); } }));
            throw new IOException("Checking file integrity in the background.");
        }
        var identity = PathIdentity.Read(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var value = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        var after = new FileInfo(path);
        if (before.Length != after.Length || before.LastWriteTimeUtc != after.LastWriteTimeUtc || identity.Id != PathIdentity.Read(path).Id)
            throw new IOException("The file changed while its integrity was being checked: " + path);
        if (cache.Count > 1024) cache.Clear();
        cache[key] = value; return value;
    }
}
