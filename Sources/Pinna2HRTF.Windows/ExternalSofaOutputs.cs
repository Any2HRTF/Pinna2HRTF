using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Pinna2HRTF.Windows;

// External destinations have separate, explicit ownership; no directory is
// recursively deleted and pre-existing foreign files are never claimed.
internal sealed class ExternalSofaOutputs
{
    readonly string metadata;
    readonly string selectedRoot;
    readonly HashSet<string> protectedPaths;
    static readonly Regex Names = new(@"^(HRIR|HRTF)_[^/\\]+\.(sofa|png|jpe?g|pdf)$", RegexOptions.IgnoreCase);
    internal ExternalSofaOutputs(string project, IEnumerable<string> inputs, string destination)
    {
        metadata = Path.Combine(PathIdentity.Resolve(project),".pinna2hrtf","external-sofa-outputs.json");
        selectedRoot = PathIdentity.Resolve(destination);
        protectedPaths=inputs.Where(p=>!string.IsNullOrWhiteSpace(p)).Select(PathIdentity.Resolve).ToHashSet(StringComparer.OrdinalIgnoreCase);
    }
    static bool Safe(string path)
    {
        for(string? current=path;!string.IsNullOrEmpty(current);current=Path.GetDirectoryName(current))
            if((File.Exists(current)||Directory.Exists(current))&&(File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)return false;
        return true;
    }
    static string Hash(string path) { using var stream=File.OpenRead(path);return Convert.ToHexString(SHA256.HashData(stream)); }
    Dictionary<string,string> Load() => File.Exists(metadata)?JsonSerializer.Deserialize<Dictionary<string,string>>(File.ReadAllText(metadata))??throw new IOException("Invalid external SOFA ownership."):new(StringComparer.OrdinalIgnoreCase);
    void Save(Dictionary<string,string> entries){Directory.CreateDirectory(Path.GetDirectoryName(metadata)!);HeadGeometry.AtomicWrite(metadata,JsonSerializer.Serialize(entries,new JsonSerializerOptions{WriteIndented=true}));}
    internal static Dictionary<string,string> Snapshot(string directory)
    {
        if(!Safe(directory))throw new IOException("Linked SOFA destinations are not managed automatically.");
        return Directory.Exists(directory)?Directory.EnumerateFiles(directory).Where(p=>Names.IsMatch(Path.GetFileName(p))).ToDictionary(Path.GetFullPath,Hash,StringComparer.OrdinalIgnoreCase):new(StringComparer.OrdinalIgnoreCase);
    }
    internal void Capture(string directory,Dictionary<string,string> before)
    {
        var entries=Load();
        foreach(var pair in Snapshot(directory))
        {
            if(protectedPaths.Contains(pair.Key))continue;
            if(before.TryGetValue(pair.Key,out var previous)&&(!entries.TryGetValue(pair.Key,out var owned)||!owned.Equals(previous,StringComparison.OrdinalIgnoreCase)))continue;
            entries[pair.Key]=pair.Value;
        }
        Save(entries);
    }
    static bool ManagedName(string relative) => Names.IsMatch(relative) || Regex.IsMatch(relative.Replace('\\','/'),
        @"^Upsampled/HRIR_[^/]+/(hrtf_Nd=[0-5](_dense)?\.sofa|upsampling\.json|upsampling_report\.(mat|txt))$", RegexOptions.IgnoreCase);
    internal void Publish(string staging,string directory)
    {
        var entries = Load();
        var destination = PathIdentity.Resolve(directory);
        var main = Path.Combine(Path.GetDirectoryName(metadata)!, "generated-output-manifest.json");
        if (File.Exists(main))
        {
            using var document = JsonDocument.Parse(File.ReadAllText(main));
            foreach (var item in document.RootElement.GetProperty("Files").EnumerateObject())
            {
                var path = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(metadata))!, item.Name));
                if (PathIdentity.Contains(destination, path) && ManagedName(Path.GetRelativePath(destination, path)))
                    entries.TryAdd(path, item.Value.GetProperty("Sha256").GetString()!);
            }
        }
        var files = Directory.GetFiles(staging, "*", SearchOption.AllDirectories)
            .Select(path => (Source: path, Relative: Path.GetRelativePath(staging, path))).Where(p => ManagedName(p.Relative)).ToArray();
        if (!files.Any(p => Path.GetExtension(p.Source).Equals(".sofa", StringComparison.OrdinalIgnoreCase))) throw new IOException("Postprocessing produced no SOFA files.");
        bool SafeTarget(string target)
        {
            if (!PathIdentity.Contains(destination, target) || protectedPaths.Any(p => PathIdentity.Contains(p, target) || PathIdentity.Contains(target, p))) return false;
            for (var current = target; !current.Equals(destination, StringComparison.OrdinalIgnoreCase); current = Path.GetDirectoryName(current)!)
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return false;
            return true;
        }
        foreach (var file in files)
        {
            var target = Path.GetFullPath(Path.Combine(destination, file.Relative));
            if (!SafeTarget(target)) throw new IOException("An export conflicts with a protected or linked path: " + target);
            if (File.Exists(target) && (!entries.TryGetValue(target, out var owned) || !Hash(target).Equals(owned, StringComparison.OrdinalIgnoreCase)))
                throw new IOException("An output is unowned or was edited externally. Choose another SOFA folder: " + target);
        }
        Directory.CreateDirectory(destination);
        var backupRoot = Path.Combine(staging, ".publication-backups"); Directory.CreateDirectory(backupRoot);
        var installed = new List<(string Target, string Backup, string NewHash)>();
        try
        {
            foreach (var file in files)
            {
                var target = Path.GetFullPath(Path.Combine(destination, file.Relative));
                var backup = Path.Combine(backupRoot, file.Relative);
                if (!SafeTarget(target)) throw new IOException("The export path changed during publication.");
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                if (File.Exists(target))
                {
                    if (!entries.TryGetValue(target, out var owned) || !Hash(target).Equals(owned, StringComparison.OrdinalIgnoreCase)) throw new IOException("An export changed during publication.");
                    Directory.CreateDirectory(Path.GetDirectoryName(backup)!); File.Copy(target, backup);
                    if (!Hash(target).Equals(owned, StringComparison.OrdinalIgnoreCase)) throw new IOException("An export changed while making its backup.");
                }
                var temporary = target + "." + Guid.NewGuid() + ".tmp";
                var newHash = Hash(file.Source);
                try { File.Copy(file.Source, temporary); File.Move(temporary, target, true); }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
                installed.Add((target, backup, newHash)); entries[target] = newHash;
            }
            Save(entries);
        }
        catch (Exception failure)
        {
            var recoveryFailed = false;
            foreach (var file in installed.AsEnumerable().Reverse())
            {
                try
                {
                    if (File.Exists(file.Target) && !Hash(file.Target).Equals(file.NewHash, StringComparison.OrdinalIgnoreCase)) { recoveryFailed = true; continue; }
                    if (File.Exists(file.Backup)) File.Move(file.Backup, file.Target, true);
                    else if (File.Exists(file.Target)) File.Delete(file.Target);
                }
                catch { recoveryFailed = true; }
            }
            throw new IOException(failure.Message + (recoveryFailed ? " Recovery copies remain in " + backupRoot : " Previous exports were restored."), failure);
        }
    }
    internal GeneratedOutputManifest.ResetResult Reset()
    {
        var result=new GeneratedOutputManifest.ResetResult();var entries=Load();
        foreach(var pair in entries.ToArray())
        {
            if (!PathIdentity.Contains(selectedRoot, PathIdentity.Resolve(pair.Key))) { result.ProtectedInputs++; continue; }
            if(!ManagedName(Path.GetFileName(pair.Key)) && !Regex.IsMatch(pair.Key.Replace('\\','/'), @"/Upsampled/HRIR_[^/]+/(hrtf_Nd=[0-5](_dense)?\.sofa|upsampling\.json|upsampling_report\.(mat|txt))$", RegexOptions.IgnoreCase) || !Safe(pair.Key)){result.Errors++;continue;}
            if(protectedPaths.Contains(pair.Key)){result.ProtectedInputs++;continue;}
            try
            {
                if(!File.Exists(pair.Key)){entries.Remove(pair.Key);continue;}
                using var stream=new FileStream(pair.Key,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
                if(!Convert.ToHexString(SHA256.HashData(stream)).Equals(pair.Value,StringComparison.OrdinalIgnoreCase)){result.Modified++;continue;}
                File.Delete(pair.Key);entries.Remove(pair.Key);result.Deleted++;
            }
            catch(IOException){result.Errors++;}
        }
        Save(entries);return result;
    }
}
