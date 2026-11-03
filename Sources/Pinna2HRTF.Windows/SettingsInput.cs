using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    // Keep drafts out of the saved project until Enter or focus loss. In particular,
    // a rounded automatic distance must never become a manual geometry override.
    readonly Dictionary<TextBox, (ProjectRecord? Project, string Text)> settingInputStarts = [];
    readonly HashSet<TextBox> committingSettingInputs = [];
    readonly Dictionary<(Guid Project, string Id), (string Draft, string Error)> invalidSettingDrafts = [];
    bool HasInvalidSettingDraft(TextBox box) => selectedProject != null && box.Tag is string id && invalidSettingDrafts.ContainsKey((selectedProject.Id, id));
    string? SettingDraftError(ProjectRecord p) => invalidSettingDrafts.FirstOrDefault(x => x.Key.Project == p.Id).Value.Error;
    void DraftError(TextBox box, ProjectRecord project, string id, string? error)
    {
        if (error == null) invalidSettingDrafts.Remove((project.Id, id));
        else invalidSettingDrafts[(project.Id, id)] = (box.Text, error);
        box.Description = error;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(box, error ?? "");
    }
    void RestoreSettingDrafts(ProjectRecord? project)
    {
        foreach (var pair in textSettings)
        {
            var box = pair.Value.Control;
            if (project != null && invalidSettingDrafts.TryGetValue((project.Id, pair.Key), out var draft))
            { box.Text = draft.Draft; box.Description = draft.Error; }
            else box.Description = null;
        }
    }

    void AttachSettingInput(TextBox box)
    {
        box.GotFocus += (_, _) => RebaseSettingInput(box);
        box.LostFocus += async (_, _) => await CommitSettingInputAsync(box);
        box.KeyDown += SettingInputKeyDown;
    }

    void RebaseSettingInput(TextBox box) => settingInputStarts[box] = (selectedProject, box.Text);

    void RebaseSettingInputs()
    {
        foreach (var box in settingControls.Values.OfType<TextBox>()) RebaseSettingInput(box);
    }

    bool HasSettingDraft(TextBox box) =>
        settingInputStarts.TryGetValue(box, out var start) && start.Project == selectedProject && start.Text != box.Text;

    async void SettingInputKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (sender is not TextBox box) return;
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            if (!committingSettingInputs.Contains(box) && settingInputStarts.TryGetValue(box, out var start) && start.Project == selectedProject)
            {
                if (selectedProject != null && box.Tag is string id) DraftError(box, selectedProject, id, null);
                box.Text = selectedProject != null && box.Tag is string bindingId && textSettings.TryGetValue(bindingId, out var binding)
                    ? binding.Read(selectedProject) ?? binding.DefaultValue : start.Text;
                RebaseSettingInput(box);
                box.SelectAll();
            }
        }
        else if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            var project = selectedProject;
            await CommitSettingInputAsync(box);
            if (selectedProject == project && box.IsEnabled)
            {
                box.Focus(FocusState.Keyboard);
                box.SelectAll();
            }
        }
    }

    async Task CommitSettingInputAsync(TextBox box)
    {
        if (loading || box.Tag is not string id || !HasSettingDraft(box) ||
            selectedProject == null || !committingSettingInputs.Add(box)) return;
        try
        {
            var originalProject = selectedProject;
            if (NumericInput.IsNumeric(id))
            {
                try
                {
                    var canonical = NumericInput.Canonical(box.Text, NumericInput.IsInteger(id));
                    if (textSettings.TryGetValue(id, out var binding))
                    {
                        var candidate = System.Text.Json.JsonSerializer.Deserialize<ProjectRecord>(System.Text.Json.JsonSerializer.Serialize(originalProject))!;
                        binding.Write(candidate, canonical);
                        if (ProjectDocument.ValidationError(candidate) is string validation) throw new InvalidDataException(validation);
                    }
                    box.Text = canonical;
                    DraftError(box, originalProject, id, null);
                }
                catch (Exception error) when (error is InvalidDataException or FormatException or OverflowException)
                { DraftError(box, originalProject, id, error.Message); RefreshPipelineStatus(); return; }
            }
            if (id.StartsWith("project.", StringComparison.OrdinalIgnoreCase) || id == "scan_preparation.scan_path")
            {
                if (ProjectBusy(selectedProject.Id)) LoadSelectedProject();
                else ProjectEdited(this, new RoutedEventArgs());
            }
            else await HandleSettingChangeAsync(id);
        }
        catch (Exception error)
        {
            if (selectedProject != null) DraftError(box, selectedProject, id, error.Message);
            AppendLog("Could not commit the setting: " + error.Message);
        }
        finally
        {
            committingSettingInputs.Remove(box);
            if (!HasInvalidSettingDraft(box)) RebaseSettingInput(box);
        }
    }

    void SetGeometryInputText(string text)
    {
        // An asynchronous mesh measurement can finish while a user is typing.
        if (earDistanceBox.FocusState != FocusState.Unfocused && HasSettingDraft(earDistanceBox) && !geometryEditing) return;
        earDistanceBox.Text = text;
        RebaseSettingInput(earDistanceBox);
    }
}
