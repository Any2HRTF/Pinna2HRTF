using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    Task<JsonElement> StageReceiptAsync(string action, string stage, ProjectRecord project) =>
        RequestPythonAsync("project", new { action, stage, config = ProjectDocument.Build(project, environment), app = "windows", project });

    bool StageReceiptIsCurrent(string stage, ProjectRecord project)
    {
        try { return StageReceiptAsync("stage-status", stage, project).GetAwaiter().GetResult().GetProperty("current").GetBoolean(); }
        catch (Exception error) when (error is IOException or InvalidOperationException or JsonException or KeyNotFoundException or System.ComponentModel.Win32Exception) { return false; }
    }

    bool PostprocessingIsCurrent(ProjectRecord p)
    {
        try { return SofaFilesPresent(p) && StageReceiptIsCurrent("postprocessing", p); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
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
        RefreshPipelineStatus(); return false;
    }
}
