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
                box.Text = start.Text;
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
            if (id.StartsWith("project.", StringComparison.OrdinalIgnoreCase))
            {
                if (runningProcesses.ContainsKey(selectedProject.Id) || outputOperations.Contains(selectedProject.Id)) LoadSelectedProject();
                else ProjectEdited(this, new RoutedEventArgs());
            }
            else await HandleSettingChangeAsync(id);
        }
        finally
        {
            committingSettingInputs.Remove(box);
            RebaseSettingInput(box);
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
