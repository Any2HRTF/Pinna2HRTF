using System.Text.Json;
using System.Numerics;

namespace Pinna2HRTF.Windows;

internal enum NavigationAction { None, Orbit, Pan, Zoom }

internal sealed class TrackpadGestureState
{
    Vector3 previous; float previousScale; bool active, pinching;
    public void Begin(Vector3 position, float scale) { previous = position; previousScale = scale; active = true; pinching = false; }
    public void End() { active = false; pinching = false; }
    public (NavigationAction Action, Vector2 Delta, float Ratio) Next(Vector3 position, float scale, bool shift)
    {
        if (!active || !float.IsFinite(scale) || scale <= 0 || !float.IsFinite(position.X) || !float.IsFinite(position.Y)) return (NavigationAction.None, default, 1);
        var delta = position - previous; var ratio = scale / previousScale;
        previous = position; previousScale = scale;
        if (Math.Abs(Math.Log(ratio)) > .000001) pinching = true;
        return (pinching ? NavigationAction.Zoom : shift ? NavigationAction.Pan : NavigationAction.Orbit, new(delta.X, delta.Y), ratio);
    }
}

internal readonly record struct NavigationPose(Vector3 Position, Vector3 LookDirection, Vector3 UpDirection, float FieldOfView);
internal static class CameraNavigation
{
    static bool Valid(NavigationPose pose) => float.IsFinite(pose.Position.X) && float.IsFinite(pose.Position.Y) && float.IsFinite(pose.Position.Z)
        && float.IsFinite(pose.LookDirection.LengthSquared()) && pose.LookDirection.LengthSquared() > 1e-12f;
    public static NavigationPose Orbit(NavigationPose pose, float x, float y)
    {
        if (!Valid(pose) || !float.IsFinite(x) || !float.IsFinite(y)) return pose;
        var target = pose.Position + pose.LookDirection; var offset = -pose.LookDirection;
        var distance = Math.Max(offset.Length(), .0001f);
        var yaw = MathF.Atan2(offset.Y, offset.X) - x * .008f;
        var pitch = Math.Clamp(MathF.Asin(Math.Clamp(offset.Z / distance, -1, 1)) + y * .008f, -1.55f, 1.55f);
        offset = distance * new Vector3(MathF.Cos(pitch) * MathF.Cos(yaw), MathF.Cos(pitch) * MathF.Sin(yaw), MathF.Sin(pitch));
        return pose with { Position = target + offset, LookDirection = -offset, UpDirection = Vector3.UnitZ };
    }
    public static NavigationPose Pan(NavigationPose pose, float x, float y, float height)
    {
        if (!Valid(pose) || !float.IsFinite(x) || !float.IsFinite(y) || !float.IsFinite(height)) return pose;
        var forward = Vector3.Normalize(pose.LookDirection); var right = Vector3.Normalize(Vector3.Cross(forward, pose.UpDirection));
        var up = Vector3.Normalize(Vector3.Cross(right, forward));
        var scale = pose.LookDirection.Length() * 2 * MathF.Tan(pose.FieldOfView * MathF.PI / 360) / Math.Max(height, 1);
        return pose with { Position = pose.Position + (-right * x + up * y) * scale };
    }
    public static NavigationPose Zoom(NavigationPose pose, float ratio)
    {
        if (!Valid(pose) || !float.IsFinite(ratio) || ratio <= 0) return pose;
        var target = pose.Position + pose.LookDirection;
        var distance = Math.Clamp(pose.LookDirection.Length() / Math.Clamp(ratio, .1f, 10), .0001f, 1e7f);
        var look = Vector3.Normalize(pose.LookDirection) * distance;
        return pose with { Position = target - look, LookDirection = look };
    }
}

internal static class NavigationBindings
{
    public const string MouseHelp = "Middle/right-drag: rotate · Shift-middle/right: pan · Wheel / Ctrl-middle: zoom";
    public const string ShortHelp = "Middle-drag: rotate · Shift-middle: pan · Wheel: zoom";
    public const string Help = MouseHelp + "\nPrecision Touchpad: two fingers rotate · Shift-two fingers pan · Pinch zoom. Other devices retain wheel zoom.";
    public static NavigationAction Mouse(bool middle, bool right, bool shift, bool control) => middle
        ? control ? NavigationAction.Zoom : shift ? NavigationAction.Pan : NavigationAction.Orbit
        : right ? shift ? NavigationAction.Pan : NavigationAction.Orbit : NavigationAction.None;
}

// Reconcile flattened folder lists without removing/reinserting their anchors.
// Projects crossing a folder boundary are removed first, then inserted below
// their destination. Status updates and collapse/expand leave folder rows alive.
internal static class StableRows
{
    public static void Reconcile(IList<object> current, IReadOnlyList<object> desired, Func<object, bool> anchor)
    {
        var regions = new Dictionary<object, object?>(ReferenceEqualityComparer.Instance);
        object? region = null;
        foreach (var item in desired) { if (anchor(item)) region = item; else regions[item] = region; }
        region = null;
        for (var i = 0; i < current.Count;)
        {
            var item = current[i];
            if (anchor(item))
            {
                if (!desired.Any(x => ReferenceEquals(x, item))) { current.RemoveAt(i); continue; }
                region = item;
            }
            else if (!regions.TryGetValue(item, out var destination) || !ReferenceEquals(region, destination))
            { current.RemoveAt(i); continue; }
            i++;
        }
        for (var i = 0; i < desired.Count; i++)
        {
            if (i < current.Count && ReferenceEquals(current[i], desired[i])) continue;
            var existing = -1;
            for (var j = i; j < current.Count; j++) if (ReferenceEquals(current[j], desired[i])) { existing = j; break; }
            if (existing >= 0) current.RemoveAt(existing);
            current.Insert(i, desired[i]);
        }
        while (current.Count > desired.Count) current.RemoveAt(current.Count - 1);
    }
}

internal sealed record PPMControl(string Id, string Section, string Group, string Label, string Unit, double Minimum, double Maximum)
{
    public string Kind => Id.Split('|') is { Length: 4 } p ? p[2] : "";
    public string ShortLabel => Id.Split('|') is { Length: 4 } p
        ? Section == "global" ? p[3] : $"{p[1]} · {(p[2] == "Location" ? "Position" : p[2])} {p[3]}"
        : Label;
    public double Step => Unit is "mm" or "°" ? .1 : .01;
}

internal sealed class PPMControlCatalog
{
    public List<PPMControl> All { get; } = [];
    public Dictionary<string, double> Values { get; } = [];
    public IEnumerable<PPMControl> Section(string section) => All.Where(c => c.Section == section);
    public bool ShouldCommitNumber(string id, double value, double displayedValue) => double.IsFinite(value) && value != Values[id] && value != displayedValue;
    public void Load(JsonElement controls)
    {
        All.Clear(); Values.Clear();
        foreach (var c in controls.EnumerateArray())
        {
            var id = c.GetProperty("id").GetString()!;
            All.Add(new(id, c.GetProperty("section").GetString()!, c.GetProperty("group").GetString()!,
                c.GetProperty("label").GetString()!, c.GetProperty("unit").GetString()!, c.GetProperty("minimum").GetDouble(), c.GetProperty("maximum").GetDouble()));
            Values[id] = c.GetProperty("value").GetDouble();
        }
    }
    public void Restore(IReadOnlyDictionary<string, double> snapshot)
    {
        foreach (var id in Values.Keys.ToArray()) Values[id] = snapshot[id];
    }
}
