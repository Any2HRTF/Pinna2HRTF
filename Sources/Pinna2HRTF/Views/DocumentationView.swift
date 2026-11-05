import SwiftUI
import WebKit
import AppKit

private struct HelpPage: Identifiable, Hashable {
    let id: String
    let title: String
    static let all: [HelpPage] = [
        .init(id: "index", title: "Overview"),
        .init(id: "desktop-app", title: "Desktop app"),
        .init(id: "scan-preparation", title: "Scan preparation and ear editing"),
        .init(id: "manual-fitting", title: "Manual PPM fitting"),
        .init(id: "results", title: "Simulation and results"),
        .init(id: "cli", title: "Python CLI"),
        .init(id: "building", title: "Build from source")
    ]
}

struct DocumentationView: View {
    @State private var selection: HelpPage? = HelpPage.all.first

    var body: some View {
        NavigationSplitView {
            List(HelpPage.all, selection: $selection) { page in
                Text(page.title).tag(page)
            }
            .navigationTitle("Help")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let page = selection {
                DocumentationPage(page: page, selection: $selection)
            } else {
                Text("Select a guide")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct DocumentationPage: NSViewRepresentable {
    let page: HelpPage
    @Binding var selection: HelpPage?

    private var root: URL {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("Website/docs/index.html").path) {
            return resources.appendingPathComponent("Website", isDirectory: true)
        }
        return Defaults.packageRoot().appendingPathComponent("website", isDirectory: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, root: root) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        let script = """
        const style = document.createElement('style');
        style.textContent = '.docs-header,.docs-sidebar,.skip-link,.docs-footer{display:none!important} body{padding:0} .docs-frame{border:0;width:100%} .docs-layout{display:block} .docs-content{max-width:900px;margin:auto}';
        document.documentElement.appendChild(style);
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let url = root.appendingPathComponent("docs/\(page.id).html")
        if web.url?.standardizedFileURL.path != url.standardizedFileURL.path {
            web.loadFileURL(url, allowingReadAccessTo: root)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var selection: HelpPage?
        let root: URL
        init(selection: Binding<HelpPage?>, root: URL) { _selection = selection; self.root = root }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url,
                  let page = HelpPage.all.first(where: { $0.id + ".html" == url.lastPathComponent }),
                  selection != page else { return }
            selection = page
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.isFileURL {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root.standardizedFileURL.path + "/") else { decisionHandler(.cancel); return }
                decisionHandler(.allow)
            } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else { decisionHandler(.cancel) }
        }
    }
}
