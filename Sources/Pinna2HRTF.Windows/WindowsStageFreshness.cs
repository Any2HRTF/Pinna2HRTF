using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    string PostprocessingInputStamp(ProjectRecord project) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
        JsonSerializer.Serialize(new { project.Settings.Postprocessing, preprocessing = PreprocessingStamp(project) }))));
    string PostprocessingStamp(ProjectRecord project)
    {
        var paths = new List<string>();
        var destination = SofaDirectory(project);
        if (Directory.Exists(destination))
        {
            paths.AddRange(Directory.EnumerateFiles(destination, "*.sofa"));
            var upsampled = Path.Combine(destination, "Upsampled");
            if (Directory.Exists(upsampled) && (File.GetAttributes(upsampled) & FileAttributes.ReparsePoint) == 0)
                foreach (var folder in Directory.EnumerateDirectories(upsampled, "HRIR_*"))
                    if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) == 0)
                        paths.AddRange(Directory.EnumerateFiles(folder).Where(p => Path.GetExtension(p) == ".sofa" || Path.GetFileName(p) == "upsampling.json"));
            if (paths.Any(p => (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)) throw new IOException("Linked SOFA outputs require review.");
        }
        foreach (var side in new[] { "Left", "Right" })
        {
            var folder = Path.Combine(project.SaveLocation, "Projects", side, "Output2HRTF");
            if (Directory.Exists(folder)) paths.AddRange(Directory.EnumerateFiles(folder, "*.sofa"));
        }
        var value = PostprocessingInputStamp(project) + string.Join("\n", paths.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).Select(x => x + ":" + FileDigest(x)));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }
    static string PostprocessingReceipt(ProjectRecord p) => Path.Combine(p.SaveLocation, ".pinna2hrtf-postprocessing-receipt.json");
    bool PostprocessingIsCurrent(ProjectRecord p)
    {
        try
        {
            return SofaFilesPresent(p) && File.Exists(PostprocessingReceipt(p)) &&
                File.ReadAllText(PostprocessingReceipt(p)) == PostprocessingStamp(p) && SpatialOutputsCurrent(p);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException or FormatException) { return false; }
    }
    bool SpatialOutputsCurrent(ProjectRecord p)
    {
        var settings = p.Settings.Postprocessing;
        if (settings?.SpatialUpsampling != true) return true;
        var root = SofaDirectory(p); var sources = Directory.GetFiles(root, "HRIR_*.sofa");
        if (sources.Length == 0 || !int.TryParse(settings.SpatialSubdivisions, out var divisions)) return false;
        foreach (var source in sources)
        {
            var folder = Path.Combine(root, "Upsampled", Path.GetFileNameWithoutExtension(source));
            var dense = Path.Combine(folder, $"hrtf_Nd={divisions}{(divisions == 0 ? "_dense" : "")}.sofa");
            if (!File.Exists(dense) || !File.Exists(Path.Combine(folder, "upsampling.json"))) return false;
            using var receipt = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "upsampling.json")));
            var value = receipt.RootElement;
            bool IdentityMatches(JsonElement identity, string path)
            {
                var info = new FileInfo(path);
                return info.Length == identity.GetProperty("size").GetInt64() &&
                    Math.Abs((info.LastWriteTimeUtc - DateTime.UnixEpoch).TotalSeconds - identity.GetProperty("mtime").GetDouble()) < 0.000002;
            }
            if (value.GetProperty("method").GetString() != "LocaDyn-1948" || value.GetProperty("subdivisions").GetInt32() != divisions ||
                value.GetProperty("normalize").GetBoolean() != settings.SpatialNormalize ||
                !IdentityMatches(value.GetProperty("input"), source) || !IdentityMatches(value.GetProperty("output"), dense)) return false;
        }
        return true;
    }
    IEnumerable<string> StaleReviewSides(ProjectRecord p) => p.Settings.ScanPreparation.Enabled
        ? new[] { "left", "right" }.Where(side => !string.IsNullOrWhiteSpace(side == "left" ? p.Settings.ScanPreparation.ReviewedLeft : p.Settings.ScanPreparation.ReviewedRight) && !EarReviewIsCurrent(p, side))
        : [];
    async Task<bool> RecoverStaleReviewAsync(ProjectRecord project)
    {
        var side = StaleReviewSides(project).FirstOrDefault(); if (side == null) return true;
        queuedStages.Remove(project.Id);
        var path = side == "left" ? project.Settings.ScanPreparation.ReviewedLeft : project.Settings.ScanPreparation.ReviewedRight;
        var dialog = new ContentDialog { Title = $"Saved {side} ear edit is out of date", Content = $"{path}\n\nReview this ear again, or explicitly use the current prepared ear. The saved mesh stays on disk.",
            PrimaryButtonText = "Review ear", SecondaryButtonText = "Use prepared ear", CloseButtonText = "Cancel" };
        var result = await ShowDialogAsync(dialog);
        if (!projects.Contains(project) || shutdownCleanupDone) return false;
        if (result == ContentDialogResult.Secondary && !ProjectBusy(project.Id))
        {
            if (side == "left") { project.Settings.ScanPreparation.ReviewedLeft = null; project.Settings.Preprocessing.SourcePositionInputLeft = null; }
            else { project.Settings.ScanPreparation.ReviewedRight = null; project.Settings.Preprocessing.SourcePositionInputRight = null; }
            Persist(); if (selectedProject == project) { LoadSelectedProject(); RefreshArtifacts(); }
        }
        else if (result == ContentDialogResult.Primary && selectedProject == project) await EditPreparedEarAsync(side);
        RefreshPipelineStatus(); return false; // Recovery is explicit; never auto-continue.
    }
}
