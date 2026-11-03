using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
namespace Pinna2HRTF.Windows;

public partial class MainWindow
{
    Window? documentationWindow;
    async Task OpenOfflineDocumentationAsync()
    {
        if (documentationWindow != null) { documentationWindow.Activate(); return; }
        var website = Path.Combine(packageRoot, "Website");
        if (!Directory.Exists(website)) website = Path.Combine(packageRoot, "website");
        if (!File.Exists(Path.Combine(website, "docs", "index.html"))) throw new IOException("The bundled documentation is missing.");
        var window = new Window { Title = "Pinna2HRTF Help" }; documentationWindow = window;
        var root = new Grid { RequestedTheme = Root.ActualTheme };
        root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new());
        var title = new TextBlock { Text = window.Title, FontSize = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12) };
        var header = new Grid { MinHeight = 48 }; header.Children.Add(title); root.Children.Add(header);
        var body = new Grid(); body.ColumnDefinitions.Add(new() { Width = new GridLength(230) }); body.ColumnDefinitions.Add(new());
        Grid.SetRow(body, 1); root.Children.Add(body);
        var pages = new[] { ("index", "Overview"), ("desktop-app", "Desktop app"), ("scan-preparation", "Scan preparation and ear editing"),
            ("manual-fitting", "Manual PPM fitting"), ("results", "Simulation and results"), ("cli", "Python CLI"), ("building", "Build from source") };
        var list = new ListView { Margin = new Thickness(8) };
        foreach (var page in pages) list.Items.Add(new ListViewItem { Content = new TextBlock { Text = page.Item2, TextWrapping = TextWrapping.Wrap, FontSize = 14, Margin = new Thickness(0, 5, 0, 5) } });
        list.SelectedIndex = 0; body.Children.Add(list);
        var content = new Grid(); Grid.SetColumn(content, 1); body.Children.Add(content);
        var web = new WebView2(); content.Children.Add(web);
        window.Content = root; var chrome = new WindowChrome(window, root, header, title, 760, 500);
        var closed = false;
        window.Closed += (_, _) => { closed = true; web.Close(); chrome.Dispose(); documentationWindow = null; };
        window.AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1020, 760)); window.Activate();
        try
        {
            await web.EnsureCoreWebView2Async(); if (closed) return;
            web.CoreWebView2.SetVirtualHostNameToFolderMapping("pinna-help.local", website, CoreWebView2HostResourceAccessKind.DenyCors);
            web.CoreWebView2.NavigationStarting += (_, args) =>
            {
                if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri)) { args.Cancel = true; return; }
                if (uri.Scheme == "https" && uri.Host == "pinna-help.local") return;
                args.Cancel = true; if (uri.Scheme is "https" or "http" or "mailto") OpenExternal(uri.AbsoluteUri);
            };
            web.CoreWebView2.NewWindowRequested += (_, args) => { args.Handled = true; if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" or "mailto") OpenExternal(uri.AbsoluteUri); };
            await web.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("document.addEventListener('DOMContentLoaded',()=>{const s=document.createElement('style');s.textContent='.docs-header,.docs-sidebar,.skip-link,.docs-footer{display:none!important}body{padding:0}.docs-frame{border:0;width:100%}.docs-layout{display:block}.docs-content{max-width:900px;margin:auto}';document.head.appendChild(s);});");
            void Navigate() { if (!closed && list.SelectedIndex >= 0) web.Source = new Uri("https://pinna-help.local/docs/" + pages[list.SelectedIndex].Item1 + ".html"); }
            list.SelectionChanged += (_, _) => Navigate(); Navigate();
        }
        catch (Exception error)
        {
            if (closed) return;
            content.Children.Clear();
            var panel = new StackPanel { Spacing = 12, Margin = new Thickness(20) };
            panel.Children.Add(new TextBlock { Text = "The embedded Help view could not start. The guides are available offline in your browser.\n" + error.Message, TextWrapping = TextWrapping.Wrap });
            var open = new Button { Content = "Open local guide" };
            open.Click += (_, _) => OpenExternal(Path.Combine(website, "docs", pages[Math.Max(0, list.SelectedIndex)].Item1 + ".html"));
            panel.Children.Add(open); content.Children.Add(panel);
        }
    }
}
