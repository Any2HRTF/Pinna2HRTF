using System.Text.Json;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    sealed record StatusSnapshot(string Revision, Dictionary<Stage, bool> Stages, Dictionary<Stage, string?> Reasons, string NumCalc, HashSet<Stage> Outdated, DateTime Checked);
    readonly Dictionary<Guid, StatusSnapshot> statusSnapshots = [];
    readonly HashSet<Guid> pendingStatus = [];
    static string StatusRevision(ProjectRecord p) => JsonSerializer.Serialize(new { p.LeftEar, p.RightEar, p.SaveLocation, p.Settings, p.PreservedConfigJSON });
    bool CachedStageComplete(Stage stage, ProjectRecord project)
    {
        var revision = StatusRevision(project);
        statusSnapshots.TryGetValue(project.Id, out var saved);
        if ((saved == null || saved.Revision != revision || DateTime.UtcNow - saved.Checked > TimeSpan.FromSeconds(3)) && !pendingStatus.Contains(project.Id))
            _ = RefreshStatusSnapshotAsync(project, false);
        return saved != null && saved.Revision == revision && saved.Stages.GetValueOrDefault(stage);
    }
    async Task RefreshStatusSnapshotAsync(ProjectRecord project, bool decisive)
    {
        if (!decisive && !pendingStatus.Add(project.Id)) return;
        var snapshot = Clone(project); var revision = StatusRevision(snapshot);
        try
        {
            var result = await Task.Run(() =>
            {
                using var fresh = decisive ? FileFingerprints.Fresh() : null;
                var inspection = new ArtifactInspection { Background = true };
                var stages = Stage.GetValues().ToDictionary(stage => stage, stage =>
                { try { return StageIsComplete(stage, snapshot, inspection); } catch { return false; } });
                var progress = "NumCalc: checking results…";
                try { progress = NumCalcStatus(snapshot, inspection); } catch { }
                var reasons = Stage.GetValues().ToDictionary(stage => stage, stage =>
                { try { return StageAvailabilityReason(stage, snapshot, inspection); } catch (Exception error) { return "Could not check inputs: " + error.Message; } });
                var outdated = new HashSet<Stage>();
                if (!stages[Stage.Preprocessing] && PreprocessingFilesPresent(snapshot)) outdated.Add(Stage.Preprocessing);
                if (!stages[Stage.Postprocessing] && SofaFilesPresent(snapshot)) outdated.Add(Stage.Postprocessing);
                if (!stages[Stage.Numcalc] && outdated.Contains(Stage.Preprocessing) && outdated.Contains(Stage.Postprocessing)) outdated.Add(Stage.Numcalc);
                return (stages, reasons, progress, outdated);
            });
            if (!shutdownCleanupDone && projects.Contains(project) && StatusRevision(project) == revision)
            {
                var inputAvailabilityChanged = !statusSnapshots.TryGetValue(project.Id, out var previous) || previous.Revision != revision ||
                    new[] { Stage.ScanPreparation, Stage.Inference, Stage.Preprocessing }.Any(stage => previous.Stages.GetValueOrDefault(stage) != result.stages.GetValueOrDefault(stage));
                statusSnapshots[project.Id] = new(revision, result.stages, result.reasons, result.progress, result.outdated, DateTime.UtcNow);
                if (inputAvailabilityChanged && selectedProject == project) { RefreshArtifacts(); RefreshGeometry(); }
            }
        }
        finally { if (!decisive) pendingStatus.Remove(project.Id); }
        if (!shutdownCleanupDone) RefreshPipelineStatus();
    }
}
