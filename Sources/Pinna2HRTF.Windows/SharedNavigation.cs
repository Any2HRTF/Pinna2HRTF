using HelixToolkit;
using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI.Composition.Interactions;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using System.Numerics;

namespace Pinna2HRTF.Windows;

// Precision Touchpad input is captured by Composition only over this viewport.
// Mouse wheel messages remain with Helix; no wheel-size/device heuristics and
// no global input-mode switching are used.
internal sealed class SharedNavigation : IInteractionTrackerOwner, IDisposable
{
    readonly Viewport3DX viewport;
    readonly Action? beforeNavigation;
    readonly Action? changed;
    InteractionTracker? tracker;
    VisualInteractionSource? source;
    readonly TrackpadGestureState gesture = new();
    bool disposed;
    public SharedNavigation(Viewport3DX viewport, Action? beforeNavigation = null, Action? changed = null)
    {
        this.viewport = viewport; this.beforeNavigation = beforeNavigation; this.changed = changed;
        viewport.UseDefaultGestures = true;
        viewport.InputController = new MeshInputController();
        viewport.CameraMode = CameraMode.Inspect;
        viewport.CameraRotationMode = CameraRotationMode.Turntable;
        viewport.ModelUpDirection = Vector3.UnitZ;
        viewport.IsInertiaEnabled = false;
        // Help is available through a deliberate Controls flyout, not a hover popup over the mesh.
        viewport.Loaded += Loaded;
        viewport.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(MousePressed), true);
        if (viewport.IsLoaded) Initialize();
    }
    void MousePressed(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(viewport).Properties;
        if (p.IsRightButtonPressed || p.IsMiddleButtonPressed) beforeNavigation?.Invoke();
    }
    void Loaded(object sender, RoutedEventArgs e) => Initialize();
    void Initialize()
    {
        if (disposed || tracker != null) return;
        try
        {
            var visual = ElementCompositionPreview.GetElementVisual(viewport);
            tracker = InteractionTracker.CreateWithOwner(visual.Compositor, this);
            tracker.MinPosition = new(-1000000); tracker.MaxPosition = new(1000000);
            tracker.MinScale = .000001f; tracker.MaxScale = 1000000;
            source = VisualInteractionSource.Create(visual);
            source.ManipulationRedirectionMode = VisualInteractionSourceRedirectionMode.CapableTouchpadOnly;
            source.PositionXSourceMode = source.PositionYSourceMode = InteractionSourceMode.EnabledWithoutInertia;
            source.ScaleSourceMode = InteractionSourceMode.EnabledWithoutInertia;
            source.IsPositionXRailsEnabled = source.IsPositionYRailsEnabled = false;
            source.PositionXChainingMode = source.PositionYChainingMode = source.ScaleChainingMode = InteractionChainingMode.Never;
            source.PointerWheelConfig.PositionXSourceMode = source.PointerWheelConfig.PositionYSourceMode = source.PointerWheelConfig.ScaleSourceMode = InteractionSourceRedirectionMode.Disabled;
            tracker.InteractionSources.Add(source);
            Diagnose("attached", null);
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or NotSupportedException)
        {
            // Older systems/drivers keep ordinary mouse-compatible navigation.
            source?.Dispose(); tracker?.Dispose(); source = null; tracker = null;
            Diagnose("mouse-compatible fallback", error.Message);
        }
    }
    static void Diagnose(string status, string? error)
    {
        var path = Environment.GetEnvironmentVariable("PINNA2HRTF_CHROME_DIAGNOSTICS");
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) return;
        try { File.AppendAllText(path + ".navigation.jsonl", System.Text.Json.JsonSerializer.Serialize(new { status, error, source = "CapableTouchpadOnly", mouseWheelRedirected = false }) + Environment.NewLine); }
        catch (Exception) { }
    }
    void Dispatch(Action action) => viewport.DispatcherQueue.TryEnqueue(() => { if (!disposed) action(); });
    public void InteractingStateEntered(InteractionTracker sender, InteractionTrackerInteractingStateEnteredArgs args) => Dispatch(() =>
    { gesture.Begin(sender.Position, sender.Scale); beforeNavigation?.Invoke(); });
    public void IdleStateEntered(InteractionTracker sender, InteractionTrackerIdleStateEnteredArgs args) => Dispatch(() =>
    {
        gesture.End();
        sender.TryUpdatePosition(Vector3.Zero); sender.TryUpdateScale(1, Vector3.Zero);
    });
    public void ValuesChanged(InteractionTracker sender, InteractionTrackerValuesChangedArgs args)
    {
        var position = args.Position; var scale = args.Scale;
        Dispatch(() =>
        {
            var shift = (InputKeyboardSource.GetKeyStateForCurrentThread(global::Windows.System.VirtualKey.Shift) & global::Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
            var (action, delta, ratio) = gesture.Next(position, scale, shift);
            if (action == NavigationAction.None || viewport.Camera is not PerspectiveCamera camera) return;
            var pose = new NavigationPose(camera.Position, camera.LookDirection, camera.UpDirection, (float)camera.FieldOfView);
            if (action == NavigationAction.Zoom)
            {
                if (!viewport.IsZoomEnabled) return;
                pose = CameraNavigation.Zoom(pose, ratio);
            }
            else if (action == NavigationAction.Pan)
            {
                if (!viewport.IsPanEnabled) return;
                pose = CameraNavigation.Pan(pose, delta.X, delta.Y, (float)viewport.ActualHeight);
            }
            else
            {
                if (!viewport.IsRotationEnabled) return;
                pose = CameraNavigation.Orbit(pose, delta.X, delta.Y);
            }
            camera.Position = pose.Position; camera.LookDirection = pose.LookDirection; camera.UpDirection = pose.UpDirection;
            changed?.Invoke();
        });
    }
    public void CustomAnimationStateEntered(InteractionTracker sender, InteractionTrackerCustomAnimationStateEnteredArgs args) { }
    public void InertiaStateEntered(InteractionTracker sender, InteractionTrackerInertiaStateEnteredArgs args) { }
    public void RequestIgnored(InteractionTracker sender, InteractionTrackerRequestIgnoredArgs args) { }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        viewport.Loaded -= Loaded; viewport.RemoveHandler(UIElement.PointerPressedEvent, new PointerEventHandler(MousePressed));
        tracker?.InteractionSources.RemoveAll(); source?.Dispose(); tracker?.Dispose();
    }
}
