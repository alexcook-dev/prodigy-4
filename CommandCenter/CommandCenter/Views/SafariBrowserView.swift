import AppKit
import SwiftUI
import WebKit

/// In-app browser tab (WKWebView) for the center pane.
///
/// Identity is the tab UUID. Title/URL updates must not remount this view or
/// the WebView loses history and in-page link clicks appear to “leave” the tab.
struct SafariBrowserView: View {
    let tabID: UUID
    let initialURLString: String
    /// Fallback tab label when the page has no title yet (e.g. "Safari", "Teams").
    var defaultTitle: String = "Safari"
    var onClose: () -> Void
    var onUpdate: (String, String) -> Void // title, urlString

    @StateObject private var model = BrowserModel()
    @State private var didLoadInitial = false

    var body: some View {
        VStack(spacing: 0) {
            chrome
            WebViewRepresentable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Absorb SwiftUI hit-testing so parent center-pane gestures
                // cannot steal clicks meant for Google result links.
                .contentShape(Rectangle())
        }
        .background(Theme.centerBackground)
        .onAppear {
            // Load once — never re-load when parent re-renders for title updates.
            if !didLoadInitial {
                didLoadInitial = true
                model.pageTitle = defaultTitle
                model.load(urlString: initialURLString)
            }
        }
        .onChange(of: model.pageTitle) { _, title in
            onUpdate(title.isEmpty ? defaultTitle : title, model.currentURLString)
        }
        .onChange(of: model.currentURLString) { _, url in
            onUpdate(model.pageTitle.isEmpty ? defaultTitle : model.pageTitle, url)
        }
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)
            .help("Back")

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoForward)
            .help("Forward")

            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload")

            TextField("Search or enter website name", text: $model.addressField)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.load(urlString: model.addressField) }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .font(Font.callout)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.centerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }
}

// MARK: - Model

@MainActor
final class BrowserModel: ObservableObject {
    /// Desktop Safari UA so sites like Teams / Microsoft login treat us as a real browser.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    @Published var addressField: String = "https://www.apple.com"
    @Published var currentURLString: String = "https://www.apple.com"
    @Published var pageTitle: String = "Safari"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    weak var webView: WKWebView?

    func load(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolved: URL?
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            resolved = URL(string: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            resolved = URL(string: "https://\(trimmed)")
        } else {
            let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            resolved = URL(string: "https://www.google.com/search?q=\(q)")
        }
        guard let url = resolved else { return }
        addressField = url.absoluteString
        currentURLString = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func syncNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let url = webView.url?.absoluteString {
            currentURLString = url
            // Update the address bar for navigations (including Google result clicks),
            // but avoid fighting the user while they are typing a new URL.
            let editing = addressField != currentURLString
                && addressField != url
                && !webView.isLoading
            if !editing {
                addressField = url
            } else if webView.isLoading {
                // In-flight navigation always wins over stale field text.
                addressField = url
            }
        }
        if let title = webView.title, !title.isEmpty {
            pageTitle = title
        }
    }
}

// MARK: - WKWebView bridge

/// Container so the WebView fills space and receives mouse events without
/// competing SwiftUI layout re-parenting.
private final class WebViewHost: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(webView)
        super.mouseDown(with: event)
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WebViewHost {
        let config = WKWebViewConfiguration()
        // Required so window.open / target=_blank reach createWebViewWith.
        // We still keep those navigations in *this* tab (no second window).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        // Safari-like UA helps Microsoft login / Teams web accept the embedded view.
        webView.customUserAgent = BrowserModel.safariUserAgent
        // Prefer in-app navigation over handing off to the system browser.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        model.webView = webView
        context.coordinator.observe(webView)

        return WebViewHost(webView: webView)
    }

    func updateNSView(_ nsView: WebViewHost, context: Context) {
        model.webView = nsView.webView
        // Do not reload here — parent re-renders must not reset navigation.
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel) {
            self.model = model
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.canGoBack) { [weak self] v, _ in
                    Task { @MainActor in self?.model.syncNavigationState(from: v) }
                },
                webView.observe(\.canGoForward) { [weak self] v, _ in
                    Task { @MainActor in self?.model.syncNavigationState(from: v) }
                },
                webView.observe(\.isLoading) { [weak self] v, _ in
                    Task { @MainActor in self?.model.syncNavigationState(from: v) }
                },
                webView.observe(\.title) { [weak self] v, _ in
                    Task { @MainActor in self?.model.syncNavigationState(from: v) }
                },
                webView.observe(\.url) { [weak self] v, _ in
                    Task { @MainActor in self?.model.syncNavigationState(from: v) }
                },
            ]
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""

            // Keep http(s)/about in this tab. Never hand off to system Safari
            // for normal link clicks — that was part of the “leave tab” feel.
            if scheme == "http" || scheme == "https" || scheme == "about" || scheme.isEmpty {
                // target=_blank without a UIDelegate path: still allow; createWebViewWith
                // also catches new-window requests.
                decisionHandler(.allow)
                return
            }

            // mailto:/tel: etc. open externally; stay on this tab.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                model.syncNavigationState(from: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor in
                model.syncNavigationState(from: webView)
            }
        }

        // MARK: WKUIDelegate — target=_blank / window.open → same web view

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Google SERP links use target=_blank / window.open. Returning nil
            // without loading drops the click; load into this same WKWebView so
            // the user never leaves the Safari tab.
            if navigationAction.targetFrame == nil {
                let request = navigationAction.request
                if let url = request.url, url.absoluteString != "about:blank" {
                    webView.load(request)
                } else if let url = navigationAction.request.url {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        /// Block JS `alert`/`confirm` from stealing focus awkwardly; no-op safe defaults.
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}
