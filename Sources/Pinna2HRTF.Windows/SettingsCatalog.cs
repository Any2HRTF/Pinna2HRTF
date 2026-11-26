using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Pinna2HRTF.Windows;

internal static class SettingsCatalog
{
    static JsonObject? rules, defaults;

    internal static async Task InitializeAsync(Func<string, Task<JsonElement>> request)
    {
        var defaultReply = await request("defaults");
        var ruleReply = await request("rules");
        var config = JsonNode.Parse(defaultReply.GetProperty("config").GetRawText())!.AsObject();
        var schema = JsonNode.Parse(ruleReply.GetRawText())!.AsObject();
        if (config["preprocessing"] is not JsonObject || config["numcalc"] is not JsonObject || schema["fields"] is not JsonArray { Count: > 0 })
            throw new InvalidDataException("The CLI did not return its settings defaults and validation rules.");
        defaults = config;
        rules = schema;
    }

    static JsonObject Rules => rules ?? new JsonObject();
    static JsonObject Defaults => defaults ?? new JsonObject();

    internal static string RuleId(string id) => id == "scan_preparation.scan_path" ? "scan.path"
        : id.StartsWith("scan_preparation.", StringComparison.Ordinal) ? "scan." + id["scan_preparation.".Length..] : id;

    static IEnumerable<JsonObject> Fields => (Rules["fields"] as JsonArray ?? new JsonArray()).OfType<JsonObject>();
    static IEnumerable<JsonObject> Relations => (Rules["relations"] as JsonArray ?? new JsonArray()).OfType<JsonObject>();
    static JsonObject? Field(string id) => Fields.FirstOrDefault(rule => (string?)rule["id"] == RuleId(id));

    internal static string Text(string key)
    {
        var parts = key.Split('.', 2);
        var value = Defaults[parts[0]]?[parts[1]];
        return value == null ? "" : value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : value.ToJsonString();
    }

    internal static bool Flag(string key)
    {
        var parts = key.Split('.', 2);
        return Defaults[parts[0]]?[parts[1]]?.GetValueKind() == JsonValueKind.True;
    }

    internal static double Decimal(string key) =>
        double.TryParse(Text(key), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : 0;
    internal static int Whole(string key) =>
        int.TryParse(Text(key), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : 0;

    internal static string? Check(IReadOnlyDictionary<string, string> values, string id)
    {
        id = RuleId(id);
        if (values.TryGetValue(id, out var text) && FieldMessage(id, text) is string message) return message;
        var related = Relations.Where(relation => (string?)relation["id"] == id || (string?)relation["other"] == id ||
                (relation["fields"] as JsonArray)?.Any(field => (string?)field == id) == true)
            .Select(relation => (string)relation["id"]!).ToHashSet();
        return Issues(values, null).Where(issue => related.Contains(issue.Id)).Select(issue => issue.Message).FirstOrDefault();
    }

    internal static bool AffectsStage(string id, string stage) => (Field(id)?["stages"] as JsonArray)?.Any(value => (string?)value == stage) == true;

    internal static bool IsNumeric(string id) => (string?)Field(id)?["kind"] is "integer" or "decimal";
    internal static bool IsInteger(string id) => (string?)Field(id)?["kind"] == "integer";

    static double? Number(string text, string kind)
    {
        text = text.Trim();
        if (kind == "integer") return int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var whole) ? whole : null;
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) ? value : null;
    }

    static string? Message(JsonObject rule, string text)
    {
        var kind = (string)rule["kind"]!;
        var parse = (string?)Rules["parse_messages"]?[kind];
        if (string.IsNullOrWhiteSpace(text)) return rule["optional"]?.GetValue<bool>() == true ? null : parse ?? (string?)rule["message"];
        if (kind == "text")
            return rule["choices"] is JsonArray choices && !choices.Any(choice => (string?)choice == text.Trim()) ? (string?)rule["message"] : null;
        if (Number(text, kind) is not double value) return parse;
        var message = (string?)rule["message"];
        if (rule["minimum"] is JsonNode minimum && value < minimum.GetValue<double>()) return message;
        if (rule["exclusive_minimum"] is JsonNode exclusive && value <= exclusive.GetValue<double>()) return message;
        if (rule["maximum"] is JsonNode maximum && value > maximum.GetValue<double>()) return message;
        if (rule["exclusive_maximum"] is JsonNode upper && value >= upper.GetValue<double>()) return message;
        if (rule["multiple_of"] is JsonNode step && value % step.GetValue<double>() != 0) return message;
        return null;
    }

    internal static string? FieldMessage(string id, string text) => Field(id) is JsonObject rule ? Message(rule, text) : null;

    internal static List<(string Id, string Message)> Issues(IReadOnlyDictionary<string, string> values, string? stage)
    {
        bool Active(JsonObject rule) => (string?)rule["when"] is not string condition ||
            values.TryGetValue(condition, out var flag) && flag.Equals("true", StringComparison.OrdinalIgnoreCase);
        bool InStage(JsonObject rule) => stage == null || (rule["stages"] as JsonArray ?? new JsonArray()).Any(item => (string?)item == stage);
        var found = new List<(string Id, string Message, bool Included)>();
        foreach (var rule in Fields.Where(Active))
            if (values.TryGetValue((string)rule["id"]!, out var text) && Message(rule, text) is string message)
                found.Add(((string)rule["id"]!, message, InStage(rule)));
        var invalid = found.Select(issue => issue.Id).ToHashSet();
        foreach (var relation in Relations.Where(Active))
        {
            var id = (string)relation["id"]!;
            var message = (string)relation["message"]!;
            if ((string?)relation["kind"] == "any")
            {
                var fields = (relation["fields"] as JsonArray ?? new JsonArray()).Select(item => (string?)item ?? "");
                if (!fields.Any(field => values.TryGetValue(field, out var flag) && flag.Equals("true", StringComparison.OrdinalIgnoreCase)))
                    found.Add((id, message, InStage(relation)));
                continue;
            }
            var other = (string?)relation["other"];
            if (other == null || invalid.Contains(id) || invalid.Contains(other) || Field(id)?["kind"] is not JsonNode kindNode) continue;
            var kind = (string)kindNode!;
            if (!values.TryGetValue(id, out var valueText) || !values.TryGetValue(other, out var boundText)) continue;
            if (Number(valueText, kind) is not double value || Number(boundText, kind) is not double bound) continue;
            var relationKind = (string?)relation["kind"];
            if (relationKind == "greater" && value <= bound || relationKind == "at_least" && value < bound)
                found.Add((id, message, InStage(relation)));
        }
        return found.Where(issue => issue.Included).Select(issue => (issue.Id, issue.Message)).ToList();
    }
}
