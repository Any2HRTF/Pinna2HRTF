using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Pinna2HRTF.Windows;

internal sealed record GeometryValues(
    [property: JsonPropertyName("ear_distance_left")] double? Left,
    [property: JsonPropertyName("ear_distance_right")] double? Right)
{
    public double Distance => new[] { Left, Right }.Where(x => x.HasValue).Average(x => x!.Value);
    public GeometryValues AtDistance(double value)
    {
        var delta = value - Distance;
        var result = this with { Left = Left + delta, Right = Right + delta };
        result.Validate();
        return result;
    }
    public void Validate()
    {
        if (!double.IsFinite(Distance) || Distance <= 0 || new[] { Left, Right }.Any(x => x.HasValue && (!double.IsFinite(x.Value) || x < 0)))
            throw new InvalidDataException("Ear distance must be positive and leave both ear distances nonnegative, in millimetres.");
    }
}

internal static class HeadGeometry
{
    public static bool NeedsWarning(double distance) => distance <= 50;
    public static string Number(double value) => value.ToString("G17", CultureInfo.InvariantCulture);
    public static double Parse(string value)
    {
        if (!double.TryParse(value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var result) || !double.IsFinite(result))
            throw new InvalidDataException("Enter a finite number in millimetres.");
        return result;
    }
    static string Key(JsonObject node, string key) => node.Select(x => x.Key).FirstOrDefault(x => x.Equals(key, StringComparison.OrdinalIgnoreCase)) ?? key;
    static JsonNode? Get(JsonObject node, string key) => node[Key(node, key)];
    public static string MigrateRegistry(string json, out bool changed)
    {
        // Version compatibility only; remove in a future release.
        var root = JsonNode.Parse(json)?.AsObject() ?? throw new InvalidDataException("Invalid project registry.");
        changed = root.Remove(Key(root, "appVersion"));
        if (Get(root, "numericFormat")?.GetValue<string>() != "invariant-1")
        {
            var numericKeys = new HashSet<string>(new[] { "headRadius", "earDistance", "earDistanceLeft", "earDistanceRight", "rotationDegrees", "targetEdgeMM", "leftMarginMM", "rightMarginMM", "sideMinMM", "sideMaxMM",
                "minFrequency", "maxFrequency", "frequencyStepCount", "sourceAssignmentFaceCount", "meshMinEdgeLength", "meshMaxEdgeLength", "meshMaxError", "meshGamma", "meshGammaOpposite", "maxInstances", "maxCpuLoad", "levelOffsetDB", "samplingRate", "spatialSubdivisions" }, StringComparer.OrdinalIgnoreCase);
            void Normalize(JsonNode? node)
            {
                if (node is JsonObject obj)
                    foreach (var item in obj.ToArray())
                    {
                        if (numericKeys.Contains(item.Key) && item.Value is JsonValue value && value.TryGetValue<string>(out var text) &&
                            System.Text.RegularExpressions.Regex.IsMatch(text.Trim(), @"^[+-]?\d+,\d+(?:[eE][+-]?\d+)?$"))
                            obj[item.Key] = Number(Parse(text.Replace(',', '.')));
                        else Normalize(item.Value);
                    }
                else if (node is JsonArray array) foreach (var item in array) Normalize(item);
            }
            Normalize(Get(root, "projects")); root[Key(root, "numericFormat")] = "invariant-1"; changed = true;
        }
        foreach (var entry in Get(root, "projects")?.AsArray() ?? throw new InvalidDataException("Missing project list."))
        {
            if (entry is not JsonObject project || Get(project, "settings") is not JsonObject settings || Get(settings, "preprocessing") is not JsonObject p) continue;
            if (!p.ContainsKey(Key(p, "earDistance")))
            {
                // The previous unreleased review build stored per-side targets.
                var sides = new[] { Get(p, "earDistanceLeft"), Get(p, "earDistanceRight") }.Where(x => x != null).Select(x => Parse(x!.GetValue<string>())).ToArray();
                if (sides.Length > 0) p[Key(p, "earDistance")] = Number(sides.Average());
                else
                {
                    var old = Get(p, "headRadius")?.GetValue<string>();
                    var enabled = Get(p, "useCustomHeadRadius")?.GetValue<bool>() ?? !string.IsNullOrWhiteSpace(old);
                    if (enabled && !string.IsNullOrWhiteSpace(old)) p[Key(p, "earDistance")] = old;
                }
            }
            // Legacy headRadius field: version compatibility only; remove in a future release.
            foreach (var key in new[] { "headRadius", "useCustomHeadRadius", "earDistanceLeft", "earDistanceRight", "linkGeometry" })
                changed |= p.Remove(Key(p, key));
        }
        return changed ? root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) : json;
    }
    public static void AtomicWrite(string path, string contents)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, contents); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static void AtomicWriteBytes(string path, byte[] contents)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllBytes(temporary, contents); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
