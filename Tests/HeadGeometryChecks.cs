using System.Text.Json.Nodes;
using Pinna2HRTF.Windows;
static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
var original = new GeometryValues(80, 70);
var changed = original.AtDistance(85);
Require(changed.Left == 90 && changed.Right == 80, "Mean edit did not preserve asymmetry");
try { original.AtDistance(1); throw new Exception("Impossible placement accepted"); } catch (InvalidDataException) { }
Require(original.Left == 80 && original.Right == 70, "Rejected edit mutated geometry");
Require(new GeometryValues(null, 70).AtDistance(80).Left == null, "Single-ear edit invented an ear");
Require(HeadGeometry.Parse("90,5") == 90.5 && HeadGeometry.Number(90.5) == "90.5", "Culture-dependent numbers");
Require(HeadGeometry.NeedsWarning(49.9) && HeadGeometry.NeedsWarning(50) && !HeadGeometry.NeedsWarning(50.1), "Warning threshold incorrect");
foreach (var enabled in new[] { true, false })
{
    var json = """{"Projects":[{"Settings":{"Preprocessing":{"HeadRadius":"80","UseCustomHeadRadius":ENABLED}}}]}""".Replace("ENABLED", enabled ? "true" : "false");
    var converted = HeadGeometry.MigrateRegistry(json, out var migrated);
    Require(migrated, "Legacy registry not converted");
    var settings=JsonNode.Parse(converted)!["Projects"]![0]!["Settings"]!["Preprocessing"]!;
    Require(settings["HeadRadius"]==null, "Deprecated field survived");
    Require(enabled ? settings["earDistance"]!.GetValue<string>()=="80" : settings["earDistance"]==null, "Enabled/disabled override changed");
    Require(HeadGeometry.MigrateRegistry(converted,out migrated)==converted && !migrated,"Conversion repeated");
}
var canonical="""{"projects":[{"settings":{"preprocessing":{"earDistance":"95","headRadius":"80"}}}]}""";
var result=JsonNode.Parse(HeadGeometry.MigrateRegistry(canonical,out _))!;
Require(result["projects"]![0]!["settings"]!["preprocessing"]!["earDistance"]!.GetValue<string>()=="95","Canonical value lost");
var automatic="""{"projects":[{"settings":{"preprocessing":{"earDistance":null,"headRadius":"80"}}}]}""";
var automaticResult=JsonNode.Parse(HeadGeometry.MigrateRegistry(automatic,out _))!;
Require(automaticResult["projects"]![0]!["settings"]!["preprocessing"]!["earDistance"]==null,"Explicit automatic mode was overwritten by a legacy value");
var directory=Path.Combine(Path.GetTempPath(),"pinna-distance-"+Guid.NewGuid());Directory.CreateDirectory(directory);
try {
    var path=Path.Combine(directory,"registry.json");File.WriteAllText(path,"old");
    HeadGeometry.AtomicWrite(path,"new");Require(File.ReadAllText(path)=="new" && Directory.GetFiles(directory).Length==1,"Atomic persistence failed");
} finally { Directory.Delete(directory,true); }
Console.WriteLine("Passed Windows checks: asymmetric mean edits, single ears, invalid edits, decimal culture, warning boundary, legacy/canonical overrides, repeat conversion, atomic save.");
