using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Pinna2HRTF.Windows;

internal static class NavigationHelp
{
    public static Button Command(string text) => new()
    {
        Content = text, FontSize = 12, Width = 88, Height = 28, MinWidth = 0, MinHeight = 0,
        Padding = new Thickness(8, 4, 8, 4), HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center
    };

    public static Button Create()
    {
        var content = new StackPanel { Spacing = 12, MinWidth = 260, MaxWidth = 330 };
        void Group(string title, params (string Action, string Input)[] entries)
        {
            content.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            var rows = new Grid { RowSpacing = 6, ColumnSpacing = 18 };
            rows.ColumnDefinitions.Add(new() { Width = new GridLength(65) }); rows.ColumnDefinitions.Add(new());
            foreach (var (action, input) in entries)
            {
                var row = rows.RowDefinitions.Count; rows.RowDefinitions.Add(new() { Height = GridLength.Auto });
                var label = new TextBlock { Text = action }; var keys = new TextBlock { Text = input, TextWrapping = TextWrapping.Wrap };
                Grid.SetRow(label, row); Grid.SetRow(keys, row); Grid.SetColumn(keys, 1); rows.Children.Add(label); rows.Children.Add(keys);
            }
            content.Children.Add(rows);
        }
        Group("Mouse", ("Rotate", "Middle-button drag"), ("Pan", "Shift + middle-button drag"), ("Zoom", "Scroll wheel"));
        Group("Precision Touchpad", ("Rotate", "Move two fingers"), ("Pan", "Shift + move two fingers"), ("Zoom", "Pinch"));
        var button = Command("Controls");
        button.Flyout = new Flyout { Content = content };
        AutomationProperties.SetName(button, "3D navigation controls");
        ToolTipService.SetToolTip(button, "Show mouse and touchpad controls");
        return button;
    }
}
