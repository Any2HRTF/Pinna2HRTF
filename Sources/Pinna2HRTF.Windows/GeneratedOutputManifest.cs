using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Pinna2HRTF.Windows;

// Optional project metadata. No absolute paths or GUI project IDs are persisted.
internal sealed class GeneratedOutputManifest
{
    internal enum OutputStage { ScanPreparation = -1, Inference = 0, Preprocessing, Numcalc, Postprocessing }
    internal sealed class Entry
    {
        public OutputStage Stage { get; set; }
        public long Size { get; set; }
        public long ModifiedUtcTicks { get; set; }
        public string Sha256 { get; set; } = "";
    }
    internal sealed class PendingRun
    {
        public OutputStage Stage { get; set; }
        public Dictionary<string, Entry> Before { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public List<string> Directories { get; set; } = [];
    }
    internal sealed class Document
    {
        public int Version { get; set; } = 1;
        public Dictionary<string, Entry> Files { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, OutputStage> Directories { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public PendingRun? Pending { get; set; }
    }
    internal sealed class ResetResult
    {
        public int Deleted { get; set; }
        public int ProtectedInputs { get; set; }
        public int Modified { get; set; }
        public int NonEmpty { get; set; }
        public int Errors { get; set; }
        public bool Success => Errors == 0;
        public string Summary(OutputStage? stage) =>
            $"Outputs reset ({(stage == null ? "all" : stage == OutputStage.Numcalc ? "NumCalc onward" : stage + " onward")}): deleted {Deleted}, kept modified {Modified}, kept non-empty directories {NonEmpty}, errors {Errors}.";
    }

    readonly string root;
    readonly string rootIdentity;
    readonly string? outputPrefix;
    readonly HashSet<string> protectedFiles;
    readonly object gate = new();
    FileStream? runLock;
    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new OutputStageConverter(), new System.Text.Json.Serialization.JsonStringEnumConverter() }
    };
    sealed class OutputStageConverter : System.Text.Json.Serialization.JsonConverter<OutputStage>
    {
        public override OutputStage Read(ref Utf8JsonReader reader,Type type,JsonSerializerOptions options)
        {
            if(reader.TokenType==JsonTokenType.Number&&reader.TryGetInt32(out var number)&&Enum.IsDefined(typeof(OutputStage),number))return (OutputStage)number;
            if(reader.TokenType==JsonTokenType.String&&Enum.TryParse<OutputStage>(reader.GetString()!.Replace("-",""),true,out var stage)&&Enum.IsDefined(stage))return stage;
            throw new JsonException("Unknown output stage.");
        }
        public override void Write(Utf8JsonWriter writer,OutputStage stage,JsonSerializerOptions options)=>writer.WriteStringValue(stage==OutputStage.ScanPreparation?"Scan-Preparation":stage.ToString());
    }
    string Metadata => Path.Combine(root, ".pinna2hrtf");
    string Manifest => Path.Combine(Metadata, "generated-output-manifest.json");

    public GeneratedOutputManifest(string projectRoot, IEnumerable<string> inputs, string? outputFolder = null)
    {
        if (string.IsNullOrWhiteSpace(projectRoot)) throw new IOException("Project folder is missing.");
        root = Path.TrimEndingDirectorySeparator(PathIdentity.Resolve(projectRoot));
        rootIdentity = PathIdentity.Read(root).Id;
        if (root == Path.GetPathRoot(root)) throw new IOException("A drive root cannot be an output project.");
        protectedFiles = inputs.Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(PathIdentity.Resolve).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(outputFolder))
        {
            var destination = PathIdentity.Resolve(outputFolder);
            if (PathIdentity.Contains(root, destination))
            {
                outputPrefix = Path.GetRelativePath(root, destination).Replace('\\', '/');
                if (outputPrefix == "." || outputPrefix.Split('/')[0] is ".pinna2hrtf" or "Input" or "Prepared" or "MeshEdits" or "Manual PPM" or "Projects" or "Intermediates" ||
                    protectedFiles.Any(p => PathIdentity.Contains(destination, p) || PathIdentity.Contains(p, destination)))
                    throw new IOException("Choose a separate SOFA output subfolder without project work or inputs.");
            }
        }

    }

    // Timers call this on a worker thread. Existing files are not repeatedly hashed.
    public HashSet<OutputStage> Reconcile()
    {
        lock (gate)
        {
            if (runLock != null) return [];
            if (!Directory.Exists(root)) return [];
            using var lease = Acquire();
            var doc = Load();
            if (doc.Pending != null) Capture(doc); // recovery after a stopped/crashed application
            Reconcile(doc);
            Save(doc);
            return doc.Files.Values.Select(e => e.Stage).ToHashSet();
        }
    }

    public void Begin(OutputStage stage)
    {
        lock (gate)
        {
            if (runLock != null) throw new IOException("Project outputs are busy.");
            runLock = Acquire();
            try
            {
                var doc = Load();
                if (doc.Pending != null) Capture(doc);
                Reconcile(doc);
                foreach (var input in protectedFiles.Where(p => PathIdentity.Contains(root, p)))
                {
                    var relative = Path.GetRelativePath(root, input).Replace('\\', '/');
                    var normalized = NormalizedOutput(relative);
                    if (ClassifyOutput(relative) == stage || DirectoryCanBeCreatedBy(normalized, stage) ||
                        stage == OutputStage.Preprocessing && Regex.IsMatch(normalized, @"^Projects/(Left|Right)(/|$)", RegexOptions.IgnoreCase))
                        throw new IOException("This stage would replace a selected or shared input. Choose a separate input location: " + input);
                }
                var snapshot = Scan(false);
                doc.Pending = new PendingRun { Stage = stage, Before = snapshot.Files, Directories = snapshot.Directories.ToList() };
                Save(doc); // durable baseline before starting the child process
            }
            catch { runLock.Dispose(); runLock = null; throw; }
        }
    }

    public void Complete()
    {
        lock (gate)
        {
            try
            {
                if (runLock == null) return;
                var doc = Load();
                Capture(doc);
                Save(doc);
            }
            finally { runLock?.Dispose(); runLock = null; }
        }
    }

    // Shutdown can leave the durable snapshot for next startup without hashing GB of data.
    public void ReleaseForRecovery()
    {
        lock (gate) { runLock?.Dispose(); runLock = null; }
    }

    internal sealed class EditorLease(GeneratedOutputManifest owner, FileStream stream) : IDisposable
    {
        FileStream? held = stream;
        public bool BelongsTo(GeneratedOutputManifest candidate) => ReferenceEquals(owner, candidate) && held != null;
        public void Dispose() => Interlocked.Exchange(ref held, null)?.Dispose();
    }
    public EditorLease AcquireEditorLease()
    {
        lock (gate)
        {
            if (runLock != null) throw new IOException("Project outputs are busy.");
            var lease = new EditorLease(this, Acquire());
            try { var document = Load(); if (document.Pending != null) { Capture(document); Save(document); } return lease; }
            catch { lease.Dispose(); throw; }
        }
    }
    public void ValidateEditorPaths(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            var relative = Path.GetRelativePath(root, PathIdentity.Resolve(path)).Replace('\\', '/');
            if (SafePath(relative) == null || ClassifyOutput(relative) == null)
                throw new IOException("An editor output conflicts with an input or an unmanaged location: " + path);
        }
    }
    public void RecordGeneratedFiles(IEnumerable<string> paths, EditorLease? editor = null)
    {
        lock (gate)
        {
            if (runLock != null) throw new IOException("Project outputs are busy.");
            if (editor != null && !editor.BelongsTo(this)) throw new IOException("The editor output lease is invalid.");
            using var lease = editor == null ? Acquire() : null; var doc = Load();
            foreach (var path in paths)
            {
                var relative = Path.GetRelativePath(root, PathIdentity.Resolve(path)).Replace('\\','/');
                if (SafePath(relative) == null || ClassifyOutput(relative) is not { } stage || !File.Exists(path)) continue;
                var entry = Fingerprint(path); entry.Stage = stage;
                // Never rebaseline an archived template changed outside the app.
                if (relative.StartsWith("Manual PPM/Templates/", StringComparison.OrdinalIgnoreCase) && doc.Files.TryGetValue(relative, out var old) && !old.Sha256.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase)) continue;
                doc.Files[relative] = entry;
            }
            TrackDirectories(doc, Scan(false).Directories); Save(doc);
        }
    }

    public ResetResult Reset(OutputStage? from)
    {
        var result = new ResetResult();
        lock (gate)
        {
            try
            {
                if (runLock != null) throw new IOException("Project outputs are busy.");
                if (!Directory.Exists(root)) return result;
                using var lease = Acquire();
                var doc = Load();
                if (doc.Pending != null) Capture(doc);
                Reconcile(doc);
                Save(doc); // ownership must be durable before any deletion
                var cleanupAncestors = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var pair in doc.Files.ToArray())
                {
                    if (pair.Key.StartsWith("MeshEdits/", StringComparison.OrdinalIgnoreCase) || pair.Key.StartsWith("Manual PPM/", StringComparison.OrdinalIgnoreCase)) continue;
                    if (from != null && pair.Value.Stage < from) continue;
                    AddDirectoryAncestors(cleanupAncestors, pair.Key);
                    var path = SafePath(pair.Key, false);
                    if (path == null) { result.Errors++; continue; }
                    if (SafePath(pair.Key) == null) { result.ProtectedInputs++; continue; }
                    try
                    {
                        if (!File.Exists(path)) { doc.Files.Remove(pair.Key); continue; }
                        // Prevent writes while verifying and deleting this particular file.
                        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
                        var hash = Convert.ToHexString(SHA256.HashData(stream));
                        if (!hash.Equals(pair.Value.Sha256, StringComparison.OrdinalIgnoreCase)) { result.Modified++; continue; }
                        if (SafePath(pair.Key) == null) { result.Errors++; continue; }
                        File.Delete(path);
                        doc.Files.Remove(pair.Key);
                        result.Deleted++;
                    }
                    catch (IOException) { result.Errors++; }
                    catch (UnauthorizedAccessException) { result.Errors++; }
                }
                var inspectedDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var pair in doc.Directories.OrderByDescending(p => p.Key.Length).ToArray())
                {
                    if (from != null && pair.Value < from) continue;
                    AddDirectoryAncestors(cleanupAncestors, pair.Key + "/placeholder");
                    inspectedDirectories.Add(pair.Key);
                    var path = SafePath(pair.Key);
                    if (path != null && protectedFiles.Any(p => p.StartsWith(path + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) { result.NonEmpty++; continue; }
                    if (path == null) { result.Errors++; continue; }
                    try
                    {
                        if (Directory.Exists(path))
                        {
                            if (Directory.EnumerateFileSystemEntries(path).Any()) { result.NonEmpty++; continue; }
                            Directory.Delete(path, false);
                        }
                        doc.Directories.Remove(pair.Key);
                    }
                    catch (IOException) { result.Errors++; }
                    catch (UnauthorizedAccessException) { result.Errors++; }
                }
                // A pre-manifest project can contain exact, empty output shells
                // which had no file from which ownership could be inferred.
                // Removing an empty known directory cannot remove user data.
                foreach (var directory in Scan(false).Directories.OrderByDescending(p => p.Length))
                {
                    if (inspectedDirectories.Contains(directory) || ClassifyDirectory(directory) is not { } stage ||
                        from != null && stage < from && !cleanupAncestors.Contains(directory)) continue;
                    var path = SafePath(directory);
                    if (path == null) { result.Errors++; continue; }
                    try
                    {
                        if (!Directory.Exists(path)) continue;
                        if (Directory.EnumerateFileSystemEntries(path).Any()) { result.NonEmpty++; continue; }
                        Directory.Delete(path, false);
                        doc.Directories.Remove(directory);
                    }
                    catch (IOException) { result.Errors++; }
                    catch (UnauthorizedAccessException) { result.Errors++; }
                }
                Save(doc);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
            { result.Errors++; }
        }
        return result;
    }

    static void AddDirectoryAncestors(HashSet<string> directories, string relativePath)
    {
        var current = relativePath.Replace('\\', '/');
        while (current.LastIndexOf('/') is var separator && separator > 0)
        {
            current = current[..separator];
            directories.Add(current);
        }
    }

    void Capture(Document doc)
    {
        if (doc.Pending is not { } pending) return;
        var after = Scan(false);
        foreach (var pair in after.Files)
        {
            var existed = pending.Before.TryGetValue(pair.Key, out var before);
            if (existed && before!.Size == pair.Value.Size && before.ModifiedUtcTicks == pair.Value.ModifiedUtcTicks) continue;
            // Never claim an unowned pre-existing file, or bless an earlier manual edit.
            if (existed && (!doc.Files.TryGetValue(pair.Key, out var owned) ||
                owned.Size != before!.Size || owned.ModifiedUtcTicks != before.ModifiedUtcTicks)) continue;
            // A directory difference alone is not proof that an unrelated file was
            // produced by our process. Only documented producer paths are claimed.
            if (ClassifyOutput(pair.Key) is not { } stage) continue;
            if (pending.Stage == OutputStage.Postprocessing && stage != OutputStage.Postprocessing) continue;
            if (pending.Stage == OutputStage.Inference && stage != OutputStage.Inference) continue;
            var path = SafePath(pair.Key);
            if (path == null) continue;
            try { var entry = Fingerprint(path); entry.Stage = stage; doc.Files[pair.Key] = entry; }
            catch (IOException) { continue; }
        }
        foreach (var path in after.Directories.Except(pending.Directories, StringComparer.OrdinalIgnoreCase))
            if (DirectoryCanBeCreatedBy(NormalizedOutput(path), pending.Stage)) doc.Directories.TryAdd(path, pending.Stage);
        foreach (var path in doc.Files.Keys.Except(after.Files.Keys, StringComparer.OrdinalIgnoreCase).ToArray())
            if (SafePath(path) is string full && !File.Exists(full)) doc.Files.Remove(path);
        TrackDirectories(doc, after.Directories);
        doc.Pending = null;
    }

    void Reconcile(Document doc)
    {
        var scan = Scan(false);
        foreach (var path in doc.Files.Keys.ToArray())
            if (SafePath(path) is string full && !File.Exists(full)) doc.Files.Remove(path);
        TrackDirectories(doc, scan.Directories);
        TrackKnownEmptyDirectories(doc, scan.Directories);
        foreach (var path in doc.Directories.Keys.ToArray())
            if (SafePath(path) is string full && !Directory.Exists(full)) doc.Directories.Remove(path);
    }

    static void TrackDirectories(Document doc, IEnumerable<string> directories)
    {
        foreach (var directory in directories)
        {
            var prefix = directory + "/";
            var stages = doc.Files.Where(p => p.Key.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).Select(p => p.Value.Stage).ToArray();
            if (stages.Length == 0) continue;
            var earliest = stages.Min();
            if (!doc.Directories.TryGetValue(directory, out var existing) || earliest < existing) doc.Directories[directory] = earliest;
        }
    }

    void TrackKnownEmptyDirectories(Document doc, IEnumerable<string> directories)
    {
        foreach (var directory in directories)
        {
            if (doc.Directories.ContainsKey(directory) || ClassifyDirectory(directory) is not { } stage) continue;
            var path = SafePath(directory);
            if (path == null) continue;
            try
            {
                // Adopting an exact, empty output directory is safe even for a
                // project created before manifests existed: no user data can be
                // removed, while later resets can clean up failed stage shells.
                if (!Directory.EnumerateFileSystemEntries(path).Any()) doc.Directories[directory] = stage;
            }
            catch (IOException) { /* Retry during the next reconciliation. */ }
            catch (UnauthorizedAccessException) { /* Retry during the next reconciliation. */ }
        }
    }

    static bool DirectoryCanBeCreatedBy(string path, OutputStage stage)
    {
        path = path.Replace('\\', '/');
        bool Match(string pattern) => Regex.IsMatch(path, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        return stage switch
        {
            OutputStage.ScanPreparation => Match(@"^(Prepared|MeshEdits|Manual PPM)(/.*)?$"),
            OutputStage.Inference => Match(@"^Intermediates(/(Left|Right))?$") ||
                Match(@"^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)$"),
            OutputStage.Preprocessing => Match(@"^Intermediates(/(Left|Right))?$") ||
                Match(@"^Projects(/(Left|Right)(/.*)?)?$") || path.Equals(".pinna2hrtf-preprocessing-signature", StringComparison.OrdinalIgnoreCase),
            OutputStage.Numcalc => Match(@"^Projects/(Left|Right)/NumCalc/source_[0-9]+/be\.out(/be\.[0-9]+)?$"),
            OutputStage.Postprocessing => Match(@"^HRTF(/.*)?$") || Match(@"^Projects/(Left|Right)/Output2HRTF(/.*)?$"),
            _ => false
        };
    }

    static OutputStage? ClassifyEmptyDirectory(string path)
    {
        path = path.Replace('\\', '/');
        bool Match(string pattern) => Regex.IsMatch(path, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        if (Match(@"^(Prepared|MeshEdits|Manual PPM)(/Templates)?$")) return OutputStage.ScanPreparation;
        if (path.Equals("Intermediates", StringComparison.OrdinalIgnoreCase) ||
            Match(@"^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)$")) return OutputStage.Inference;
        if (Match(@"^Projects/(Left|Right)/NumCalc/source_[0-9]+/be\.out(/be\.[0-9]+)?$")) return OutputStage.Numcalc;
        if (Match(@"^Intermediates/(Left|Right)$") || path.Equals("Projects", StringComparison.OrdinalIgnoreCase) ||
            Match(@"^Projects/(Left|Right)(/(ObjectMeshes|EvaluationGrids|NumCalc)(/.*)?)?$")) return OutputStage.Preprocessing;
        if (Match(@"^HRTF(/.*)?$") || Match(@"^Projects/(Left|Right)/Output2HRTF(/.*)?$")) return OutputStage.Postprocessing;
        return null;
    }

    // Exact producer conventions, not generic *.json/*.txt or recursive folder ownership.
    // This also recognizes partial externally copied NumCalc runs without an import action.
    internal static OutputStage? Classify(string path)
    {
        path = path.Replace('\\', '/');
        bool Match(string pattern) => Regex.IsMatch(path, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        if (Match(@"^Prepared/((Left|Right)\.stl|mesh_preparation\.json|inference\.json|preprocessing\.json)$") ||
            Match(@"^MeshEdits/((Individual)?(Left|Right)\.(stl|json)|AlignedScan\.(ply|json))$") ||
            Match(@"^Manual PPM/((Left|Right)\.(stl|json|blend[0-9]*)|Templates/[^/]+\.blend)$")) return OutputStage.ScanPreparation;
        if (path.Equals(".pinna2hrtf-postprocessing-receipt.json", StringComparison.OrdinalIgnoreCase)) return OutputStage.Postprocessing;
        if (path.Equals(".pinna2hrtf-inference-receipt.json", StringComparison.OrdinalIgnoreCase)) return OutputStage.Inference;
        if (path.Equals(".pinna2hrtf-inference-signature",StringComparison.OrdinalIgnoreCase))return OutputStage.Inference;
        if (path.Equals(".pinna2hrtf_native_run.yaml", StringComparison.OrdinalIgnoreCase)) return OutputStage.Inference;
        if (Match(@"^(Intermediates/)?Results Inference\.csv$") ||
            Match(@"^Intermediates/(Left|Right)/(ICP_[^/]+\.stl|Prediction_[^/]+\.stl|Prediction_Parameters_[^/]+\.csv)$") ||
            Match(@"^(Intermediates/)?(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)/[^/]+\.(stl|csv)$")) return OutputStage.Inference;
        if (Match(@"^Intermediates/(Left|Right)/(input_ear\.stl|source_landmark\.json|closed_ear\.stl|cut_head\.stl|stitched_head\.stl|graded_head\.ply|dummy_head\.stl)$") ||
            Match(@"^Intermediates/dummy_head\.stl$") ||
            Match(@"^Projects/(Left|Right)/(\.pinna2hrtf-export\.json|parameters\.json|3d Model\.blend[0-9]*|NumCalc/source_[0-9]+/NC\.inp|(ObjectMeshes|EvaluationGrids)/[^/]+/(Nodes|Elements)\.txt)$") ||
            path.Equals(".pinna2hrtf-preprocessing-signature", StringComparison.OrdinalIgnoreCase)) return OutputStage.Preprocessing;
        if (Match(@"^Projects/(Left|Right)/NumCalc/source_[0-9]+/(NC[0-9]+-[0-9]+_log\.txt|NC([0-9]+-[0-9]+|from[0-9]+|until[0-9]+)?\.out|Memory\.txt|be\.out/be\.[0-9]+/(pBoundary|pEvalGrid|vBoundary|vEvalGrid))$")) return OutputStage.Numcalc;
        if (Match(@"^(HRTF|Projects/(Left|Right)/Output2HRTF)/(HRIR|HRTF)_[^/]+\.(sofa|png|jpg|jpeg|pdf)$") ||
            Match(@"^Projects/(Left|Right)/Output2HRTF/(report_source_[0-9]+\.csv|report_issues\.(txt|csv))$")) return OutputStage.Postprocessing;
        if (Match(@"^HRTF/Upsampled/HRIR_[^/]+/(hrtf_Nd=[0-5](_dense)?\.sofa|upsampling\.json|upsampling_report\.(mat|txt))$")) return OutputStage.Postprocessing;
        return null;
    }

    string NormalizedOutput(string path) => outputPrefix != null && (path.Equals(outputPrefix, StringComparison.OrdinalIgnoreCase) || path.StartsWith(outputPrefix + "/", StringComparison.OrdinalIgnoreCase))
        ? "HRTF" + path[outputPrefix.Length..] : path;
    OutputStage? ClassifyOutput(string path) => Classify(NormalizedOutput(path));
    OutputStage? ClassifyDirectory(string path) => ClassifyEmptyDirectory(NormalizedOutput(path));

    static bool Managed(string relative) => relative.Equals(".pinna2hrtf-postprocessing-receipt.json", StringComparison.OrdinalIgnoreCase) || relative.Equals(".pinna2hrtf-inference-receipt.json", StringComparison.OrdinalIgnoreCase) || relative.Equals(".pinna2hrtf-inference-signature",StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(relative, @"^(Prepared|MeshEdits|Manual PPM)(/|$)", RegexOptions.IgnoreCase) || relative.Split('/')[0].Equals("Intermediates", StringComparison.OrdinalIgnoreCase) ||
        relative.Split('/')[0].Equals("Projects", StringComparison.OrdinalIgnoreCase) || relative.Split('/')[0].Equals("HRTF", StringComparison.OrdinalIgnoreCase) ||
        Regex.IsMatch(relative, @"^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)(/|$)", RegexOptions.IgnoreCase) ||
        relative.Equals("Results Inference.csv", StringComparison.OrdinalIgnoreCase) ||
        relative.Equals(".pinna2hrtf-preprocessing-signature", StringComparison.OrdinalIgnoreCase) ||
        relative.Equals(".pinna2hrtf_native_run.yaml", StringComparison.OrdinalIgnoreCase);

    string? SafePath(string relative, bool protectingInputs = true)
    {
        if (PathIdentity.Read(root).Id != rootIdentity) return null;
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains(':')) return null;
        var segments = relative.Replace('\\', '/').Split('/');
        if (segments.Any(p => p is "" or "." or ".." || p.EndsWith(' ') || p.EndsWith('.')) || !Managed(NormalizedOutput(string.Join('/', segments))) && !(outputPrefix?.StartsWith(string.Join('/', segments) + "/", StringComparison.OrdinalIgnoreCase) == true)) return null;
        var path = Path.GetFullPath(Path.Combine(root, Path.Combine(segments)));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            protectingInputs && protectedFiles.Any(p => p.Equals(path, StringComparison.OrdinalIgnoreCase) || Directory.Exists(p) && path.StartsWith(p + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) return null;
        return HasReparseAncestor(path) ? null : path;
    }

    bool HasReparseAncestor(string path)
    {
        for (string? current = path; !string.IsNullOrEmpty(current) && !current.Equals(root, StringComparison.OrdinalIgnoreCase); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return true;
        return false;
    }

    (Dictionary<string, Entry> Files, HashSet<string> Directories) Scan(bool hash)
    {
        if (HasReparseAncestor(root)) throw new IOException("Linked project folders are not managed automatically.");
        var files = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
        var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Visit(string folder)
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(folder))
            {
                var relative = Path.GetRelativePath(root, path).Replace('\\', '/');
                var directory = Directory.Exists(path);
                if (directory ? ClassifyDirectory(relative) == null && !(outputPrefix?.StartsWith(relative + "/", StringComparison.OrdinalIgnoreCase) == true) : ClassifyOutput(relative) == null) continue;
                if (SafePath(relative) == null) continue;
                if (directory) { directories.Add(relative); Visit(path); }
                else files[relative] = hash ? Fingerprint(path) : FileMetadata(path);
            }
        }
        if (Directory.Exists(root)) Visit(root);
        return (files, directories);
    }

    static Entry Fingerprint(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var size = stream.Length;
        var stamp = File.GetLastWriteTimeUtc(path).Ticks;
        var hash = Convert.ToHexString(SHA256.HashData(stream));
        if (stream.Length != size || File.GetLastWriteTimeUtc(path).Ticks != stamp) throw new IOException("Output is still changing.");
        return new Entry { Size = size, ModifiedUtcTicks = stamp, Sha256 = hash };
    }

    static Entry FileMetadata(string path)
    {
        var info = new FileInfo(path);
        return new Entry { Size = info.Length, ModifiedUtcTicks = info.LastWriteTimeUtc.Ticks };
    }

    FileStream Acquire()
    {
        if (PathIdentity.Read(root).Id != rootIdentity) throw new IOException("The save location was replaced. Select it again or restart the app before changing its outputs.");
        if (HasReparseAncestor(Metadata) || HasReparseAncestor(Manifest)) throw new IOException("Linked metadata is not supported.");
        Directory.CreateDirectory(Metadata);
        var lockPath = Path.Combine(Metadata, "outputs.lock");
        if (HasReparseAncestor(lockPath)) throw new IOException("Linked metadata is not supported.");
        return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    Document Load()
    {
        if (!File.Exists(Manifest)) return new Document();
        var doc = JsonSerializer.Deserialize<Document>(File.ReadAllText(Manifest), Json) ?? throw new IOException("Invalid output manifest.");
        if (doc.Version != 1 || doc.Files == null || doc.Directories == null) throw new IOException("Unsupported output manifest.");
        doc.Files = new(doc.Files, StringComparer.OrdinalIgnoreCase);
        doc.Directories = new(doc.Directories, StringComparer.OrdinalIgnoreCase);
        if (doc.Files.Any(p => p.Value == null || !Enum.IsDefined(p.Value.Stage) || !Regex.IsMatch(p.Value.Sha256, "^[a-fA-F0-9]{64}$"))) throw new IOException("Invalid output manifest.");
        if (doc.Pending != null) doc.Pending.Before = new(doc.Pending.Before, StringComparer.OrdinalIgnoreCase);
        return doc;
    }

    void Save(Document doc)
    {
        var temp = Path.Combine(Metadata, Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { JsonSerializer.Serialize(stream, doc, Json); stream.Flush(true); }
            File.Move(temp, Manifest, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
