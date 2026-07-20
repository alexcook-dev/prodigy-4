import AppKit
import SwiftUI
import WebKit

/// Renders email HTML (with images) inside the Mail reading pane.
struct MailHTMLWebView: NSViewRepresentable {
    let html: String
    var baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        // Allow file:// images next to message.html
        if #available(macOS 13.3, *) {
            view.isInspectable = true
        }
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Avoid reload loops when parent re-renders same HTML.
        if context.coordinator.lastHTML == html { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Keep in-place loads; open external http(s) in the system browser.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
