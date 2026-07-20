import AppKit
import SwiftUI
import WebKit

/// In-app Safari-style browser tab (WKWebView) for the center pane.
struct SafariBrowserView: View {
    let tab: BrowserTab
    var onClose: () -> Void
    var onUpdate: (String, String) -> Void // title, urlString

    @StateObject private var model = BrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            chrome
            WebViewRepresentable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.centerBackground)
        .onAppear {
            model.load(urlString: tab.urlString)
        }
        .onChange(of: model.pageTitle) { _, title in
            onUpdate(title.isEmpty ? "Safari" : title, model.currentURLString)
        }
        .onChange(of: model.currentURLString) { _, url in
            onUpdate(model.pageTitle.isEmpty ? "Safari" : model.pageTitle, url)
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
            if !addressField.hasPrefix(url) {
                // Don't clobber while the user is typing.
                if !webView.isLoading || addressField == currentURLString {
                    addressField = url
                }
            }
        }
        pageTitle = webView.title ?? pageTitle
    }
}

// MARK: - WKWebView bridge

private struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        model.webView = view
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        model.webView = nsView
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                model.syncNavigationState(from: webView)
            }
        }
    }
}
