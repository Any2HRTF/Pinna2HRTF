using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using VirtualKey = Windows.System.VirtualKey;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    [DllImport("user32.dll")] static extern uint GetDoubleClickTime();
    DispatcherQueueTimer? folderNameClickTimer;
    ProjectFolder? editingProjectFolder;
    TextBox? folderNameInput;
    bool creatingProjectFolder;

    void RenameFocusedFolder(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.F2 || editingProjectFolder != null) return;
        for (var item = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject; item != null; item = VisualTreeHelper.GetParent(item))
        {
            var folder = (item as FrameworkElement)?.Tag as ProjectFolder
                ?? ((item as ListViewItem)?.Content as FrameworkElement)?.Tag as ProjectFolder;
            if (folder == null) continue;
            BeginFolderNameEdit(folder); args.Handled = true; return;
        }
    }

    void FinishFolderNameForClose()
    {
        folderNameClickTimer?.Stop(); folderNameClickTimer = null;
        if (editingProjectFolder == null || folderNameInput == null) return;
        var name = folderNameInput.Text.Trim();
        if (name.Length > 0) editingProjectFolder.Name = name;
        else if (creatingProjectFolder) registry.Folders.Remove(editingProjectFolder);
        editingProjectFolder = null; folderNameInput = null; creatingProjectFolder = false;
        Persist();
    }

    void DeferFolderNameClick(ProjectFolder folder)
    {
        folderNameClickTimer?.Stop();
        var timer = DispatcherQueue.CreateTimer();
        folderNameClickTimer = timer;
        timer.Interval = TimeSpan.FromMilliseconds(GetDoubleClickTime() + 30);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            if (!ReferenceEquals(folderNameClickTimer, timer)) return;
            folderNameClickTimer = null;
            if (editingProjectFolder == null && registry.Folders.Contains(folder)) ToggleProjectFolder(folder);
        };
        timer.Start();
    }

    void BeginFolderNameEdit(ProjectFolder? folder = null)
    {
        folderNameClickTimer?.Stop(); folderNameClickTimer = null;
        FinishFolderNameEdit(cancel: false);
        creatingProjectFolder = folder == null;
        if (folder == null) { folder = new ProjectFolder { Name = "New folder" }; registry.Folders.Add(folder); }
        editingProjectFolder = folder;
        RefreshProjectList();
        var row = folderRows[folder.Id];
        var label = (TextBlock)row.Children[1];
        var input = row.Children.OfType<TextBox>().FirstOrDefault();
        if (input == null)
        {
            input = new TextBox { FontSize = 13, MinWidth = 0, MinHeight = 32, Padding = new Thickness(5, 3, 5, 3), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(input, "Folder name");
            Grid.SetColumn(input, 1); row.Children.Add(input);
            input.KeyDown += (_, args) =>
            {
                if (args.Key == VirtualKey.Escape) { FinishFolderNameEdit(cancel: true); args.Handled = true; }
                else if (args.Key == VirtualKey.Enter) { FinishFolderNameEdit(cancel: false, explicitCommit: true); args.Handled = true; }
            };
            input.LostFocus += (_, _) => { if (ReferenceEquals(folderNameInput, input)) FinishFolderNameEdit(cancel: false); };
        }
        folderNameInput = input;
        input.Text = creatingProjectFolder ? "" : folder.Name;
        input.PlaceholderText = "Folder name";
        label.Visibility = Visibility.Collapsed; input.Visibility = Visibility.Visible;
        projectList.ScrollIntoView(row);
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => { if (ReferenceEquals(folderNameInput, input)) { projectList.ScrollIntoView(row); input.Focus(FocusState.Keyboard); input.SelectAll(); } });
    }

    void FinishFolderNameEdit(bool cancel, bool explicitCommit = false)
    {
        if (editingProjectFolder == null || folderNameInput == null) return;
        var folder = editingProjectFolder; var input = folderNameInput;
        var name = input.Text.Trim();
        if (!cancel && name.Length == 0 && explicitCommit) return;
        var removeDraft = creatingProjectFolder && (cancel || name.Length == 0);
        editingProjectFolder = null; folderNameInput = null; creatingProjectFolder = false;
        input.Visibility = Visibility.Collapsed;
        if (folderRows.TryGetValue(folder.Id, out var row)) ((TextBlock)row.Children[1]).Visibility = Visibility.Visible;
        if (removeDraft) registry.Folders.Remove(folder);
        else if (!cancel && name.Length > 0) folder.Name = name;
        Persist(); RefreshProjectList();
        if (row != null && !removeDraft && (cancel || explicitCommit)) ((Button)row.Children[0]).Focus(FocusState.Programmatic);
    }
}
