namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    async Task PublishEditorFilesAsync(ProjectRecord project, Dictionary<string, byte[]> files, CancellationToken token,
        Dictionary<string, DateTime>? timestamps = null, Dictionary<string, string>? expectedInputs = null)
    {
        EnsureProjectRoot(project);
        var store = OutputsFor(project);
        using var lease = await Task.Run(store.AcquireEditorLease, token);
        token.ThrowIfCancellationRequested();
        store.ValidateEditorPaths(files.Keys);
        await Task.Run(() =>
        {
            void ValidateInputs()
            {
                using var fresh = FileFingerprints.Fresh();
                foreach (var input in expectedInputs ?? [])
                    if (!FileFingerprints.Hash(input.Key).Equals(input.Value, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("An editor input changed while saving. Reopen the editor; previous files are preserved.");
            }
            ValidateInputs();
            var previous = files.Keys.ToDictionary(path => path, path => File.Exists(path) ? File.ReadAllBytes(path) : null);
            var previousTimes = files.Keys.Where(File.Exists).ToDictionary(path => path, File.GetLastWriteTimeUtc);
            var recovery = Path.Combine(project.SaveLocation, ".pinna2hrtf", "backups", "editor-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(recovery);
            var backups = new Dictionary<string, string>();
            foreach (var pair in previous.Where(p => p.Value != null))
            { var path = Path.Combine(recovery, backups.Count + ".bin"); File.WriteAllBytes(path, pair.Value!); backups[pair.Key] = path; }
            var map = Path.Combine(recovery, "recovery.json");
            File.WriteAllText(map, System.Text.Json.JsonSerializer.Serialize(new { backups, previousTimes, created = previous.Where(p => p.Value == null).Select(p => p.Key) }));
            void CleanupRecovery()
            {
                foreach (var path in backups.Values.Append(map)) { try { File.Delete(path); } catch(IOException) { } catch(UnauthorizedAccessException) { } }
                try { Directory.Delete(recovery, false); } catch(IOException) { } catch(UnauthorizedAccessException) { }
            }
            try
            {
                token.ThrowIfCancellationRequested();
                foreach (var path in files.Keys) Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                CommitFitFiles(files);
                if (timestamps != null) foreach (var pair in timestamps) File.SetLastWriteTimeUtc(pair.Key, pair.Value);
                token.ThrowIfCancellationRequested();
                ValidateInputs();
                store.RecordGeneratedFiles(files.Keys, lease);
                CleanupRecovery();
            }
            catch (Exception failure)
            {
                var incomplete = false;
                foreach (var pair in previous)
                {
                    try
                    {
                        if (pair.Value == null) { if (File.Exists(pair.Key)) File.Delete(pair.Key); }
                        else { HeadGeometry.AtomicWriteBytes(pair.Key, pair.Value); File.SetLastWriteTimeUtc(pair.Key, previousTimes[pair.Key]); }
                    }
                    catch { incomplete = true; }
                }
                if (!incomplete) CleanupRecovery();
                throw new IOException(failure.Message + (incomplete ? " Recovery copies remain in " + recovery : " Previous editor files were restored."), failure);
            }
            finally { FileFingerprints.Invalidate(files.Keys); }
        }, token);
        statusSnapshots.Remove(project.Id);
    }
}
