using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Microsoft.UI.Windowing;

namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    bool notificationsRegistered;

    async void InitializeNotifications()
    {
        try
        {
            var activation = await Task.Run(() => {
                AppNotificationManager.Default.NotificationInvoked += NotificationInvoked;
                AppNotificationManager.Default.Register();
                return Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
            });
            notificationsRegistered = true;
            if (shutdownCleanupDone) { CloseNotifications(); return; }
            if (activation.Data is AppNotificationActivatedEventArgs notification) ActivateFromNotification(notification);
        }
        catch (Exception error) { AppendLog("Windows notifications unavailable: " + error.Message); }
    }

    void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
        => ActivateFromNotification(args);

    internal void ActivateFromNotification(AppNotificationActivatedEventArgs args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (AppWindow.Presenter is OverlappedPresenter presenter && presenter.State == OverlappedPresenterState.Minimized) presenter.Restore();
            Activate();
            CloseAppSettings();
            if (args.Arguments.TryGetValue("project", out var id) && Guid.TryParse(id, out var projectId) &&
                projects.FirstOrDefault(p => p.Id == projectId) is { } project)
                SelectProjectFromContext(project);
        });
    }

    void SendStageNotification(ProjectRecord project, Stage stage, bool successful)
    {
        if (!notificationsRegistered || !appPreferences.NotifyAll ||
            (successful ? !appPreferences.NotifyCompletion : !appPreferences.NotifyFailure)) return;
        try
        {
            if (AppNotificationManager.Default.Setting != AppNotificationSetting.Enabled) return;
            var notice = new AppNotificationBuilder().AddArgument("project", project.Id.ToString())
                .AddText(stage.Title + (successful ? " complete" : " failed"))
                .AddText(project.Name).BuildNotification();
            AppNotificationManager.Default.Show(notice);
        }
        catch (Exception error) { AppendLog("Could not show notification: " + error.Message, project.Id); }
    }

    void CloseNotifications()
    {
        if (!notificationsRegistered) return;
        AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
        AppNotificationManager.Default.Unregister();
        notificationsRegistered = false;
    }
}
