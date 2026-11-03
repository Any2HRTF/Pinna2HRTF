using Microsoft.UI.Xaml.Controls;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    sealed record RemovalPlan(string? Root, string? Identity, string Reason)
    { public bool CanRecycle => Root != null && Identity != null; }
    readonly SemaphoreSlim dialogGate = new(1);
    async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        await dialogGate.WaitAsync();
        try
        {
            if (shutdownCleanupDone || Root.XamlRoot == null) return ContentDialogResult.None;
            dialog.XamlRoot = Root.XamlRoot; return await dialog.ShowAsync();
        }
        finally { dialogGate.Release(); }
    }
    RemovalPlan PlanRemoval(ProjectRecord project, ProjectRecord[] others)
    {
        RemovalPlan ListOnly(string reason) => new(null, null, reason);
        try
        {
            if (string.IsNullOrWhiteSpace(project.SaveLocation) || !Directory.Exists(project.SaveLocation)) return ListOnly("The saved folder is missing; remove the list entry only.");
            if (project.FolderProvenance != "Created" || string.IsNullOrEmpty(project.OwnedFolderIdentity))
                return ListOnly("This folder was imported, referenced, or its ownership is unknown. Its files stay on disk.");
            var candidate = PathIdentity.Read(project.SaveLocation);
            if (candidate.Id != project.OwnedFolderIdentity) return ListOnly("The folder identity changed. Its files stay on disk.");
            var root = Path.GetPathRoot(candidate.Path)!;
            // Remote/removable roots have not established safe Shell recycling.
            var drive = new DriveInfo(root);
            if (candidate.Path.StartsWith(@"\\") || drive.DriveType != DriveType.Fixed) return ListOnly("Folder recycling is not enabled for this storage location.");
            if (candidate.Path.Equals(Path.TrimEndingDirectorySeparator(root), StringComparison.OrdinalIgnoreCase)) return ListOnly("A drive root is protected.");
            foreach (var protectedRoot in PathIdentity.KnownFolders())
                if (PathIdentity.Contains(candidate.Path, PathIdentity.Resolve(protectedRoot))) return ListOnly("This folder is, or contains, a protected user or system location.");
            var runtime = PathIdentity.Resolve(packageRoot); var state = PathIdentity.Resolve(appData);
            if (candidate.Path.Equals(PathIdentity.Resolve(Path.Combine(state, "Projects")), StringComparison.OrdinalIgnoreCase))
                return ListOnly("The app's project collection folder is protected.");
            if (PathIdentity.Contains(candidate.Path, runtime) || PathIdentity.Contains(runtime, candidate.Path) ||
                PathIdentity.Contains(candidate.Path, state) || PathIdentity.Contains(state, candidate.Path) &&
                !PathIdentity.Contains(Path.Combine(state, "Projects"), candidate.Path)) return ListOnly("The app/runtime location is protected.");
            foreach (var other in others.Where(x => x.Id != project.Id && !string.IsNullOrWhiteSpace(x.SaveLocation)))
            {
                var otherRoot = PathIdentity.Resolve(other.SaveLocation);
                if (PathIdentity.Contains(candidate.Path, otherRoot) || PathIdentity.Contains(otherRoot, candidate.Path))
                    return ListOnly("The folder overlaps another project, including through a filesystem alias.");
                foreach (var dependency in ProtectedInputs(other, project.Id).Append(SofaDirectory(other)).Where(path => !string.IsNullOrWhiteSpace(path)))
                {
                    var referenced = PathIdentity.Resolve(dependency);
                    if (PathIdentity.Contains(candidate.Path, referenced) || Directory.Exists(referenced) && PathIdentity.Contains(referenced, candidate.Path))
                        return ListOnly("Another project uses inputs or results in this folder. Its files stay on disk.");
                }
            }
            return new(candidate.Path, candidate.Id, "Recycling moves every item in this folder, including files that Pinna2HRTF did not generate.");
        }
        catch (Exception error) { return ListOnly("Folder safety could not be established: " + error.Message); }
    }
    ProjectRecord? ExistingProjectRoot(string folder)
    {
        var incoming = PathIdentity.Resolve(folder);
        foreach (var project in projects.Where(p => !string.IsNullOrWhiteSpace(p.SaveLocation)))
        {
            try { if (string.Equals(PathIdentity.Resolve(project.SaveLocation), incoming, StringComparison.OrdinalIgnoreCase)) return project; }
            catch (Exception error) when (error is IOException or ArgumentException or System.ComponentModel.Win32Exception or UnauthorizedAccessException) { }
        }
        return null;
    }
    void RecordCreatedFolder(ProjectRecord project)
    {
        project.FolderProvenance = "Created";
        project.OwnedFolderIdentity = PathIdentity.Read(project.SaveLocation).Id;
    }
    void EnsureProjectRoot(ProjectRecord project)
    {
        if (Directory.Exists(project.SaveLocation)) return;
        Directory.CreateDirectory(project.SaveLocation); RecordCreatedFolder(project); Persist();
    }
}
