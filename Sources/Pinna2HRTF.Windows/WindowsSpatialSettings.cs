using Microsoft.UI.Xaml.Controls;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    readonly CheckBox spatialUpsamplingBox = new() { Content = "Spatial HRTF upsampling" };
    readonly CheckBox spatialNormalizeBox = new() { Content = "Normalize spatial output" };
    readonly TextBox spatialSubdivisionsBox = new();

    void AddSpatialSettings(StackPanel settings)
    {
        AddExpander(settings, "Spatial upsampling", [
            AddSettingPanel("Spatial HRTF upsampling", "postprocessing.spatial_upsampling", spatialUpsamplingBox, "Spatial HRTF upsampling"),
            AddSettingPanel("Subdivisions (0–5)", "postprocessing.spatial_subdivisions", spatialSubdivisionsBox),
            AddSettingPanel("Normalize spatial output", "postprocessing.spatial_normalize", spatialNormalizeBox, "Normalize spatial output")]);
    }
}
