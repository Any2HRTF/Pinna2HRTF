namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    async Task PublishEditorFilesAsync(ProjectRecord project, Dictionary<string, byte[]> files, CancellationToken token,
        Dictionary<string, DateTime>? timestamps = null, Dictionary<string, string>? expectedInputs = null)
    {
        EnsureProjectRoot(project);
        _ = OutputsFor(project);
        var workspace = Directory.CreateTempSubdirectory("pinna-editor-");
        try
        {
            var entries = new List<object>();
            foreach (var pair in files)
            {
                var source = Path.Combine(workspace.FullName, entries.Count.ToString());
                await File.WriteAllBytesAsync(source, pair.Value, token);
                entries.Add(new { source, destination = pair.Key });
            }
            await RequestPythonAsync("project", new {
                action = "publish-editor", root = project.SaveLocation, files = entries,
                expected = expectedInputs, timestamps = timestamps?.ToDictionary(pair => pair.Key, pair => pair.Value.Ticks),
                @protected = projects.SelectMany(p => ProtectedInputs(p, project.Id)).ToArray()
            }, token);
        }
        finally
        {
            workspace.Delete(true);
            FileFingerprints.Invalidate(files.Keys);
            statusSnapshots.Remove(project.Id);
        }
    }
}
