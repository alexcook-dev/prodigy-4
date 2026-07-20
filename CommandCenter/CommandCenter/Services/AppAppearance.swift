import SwiftUI

/// User-facing appearance preference (persisted).
/// Matches System Settings language: System / Light / Dark.
///
/// Visual references (Desktop):
/// - **Dark** → `sc1.png` (workspace shell)
/// - **Light** → `sc2.png` (workspace empty), `sc3.png` (dashboard),
///   `sc4.png` (active chat)
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` means follow the macOS system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

enum AppStorageKey {
    static let appearance = "prodigy.appAppearance"
    /// Content zoom factor (1.0 = actual size). Driven by ⌘+/⌘-/⌘0.
    static let contentZoom = "prodigy.contentZoom"
    /// Full Mac agent mode: tools on + permission bypass (OpenClaw-style). Default off.
    static let fullMacAccess = "prodigy.access.fullMac"

    // MARK: General — tools & safety

    /// Load connector/tools on demand in new conversations (default true).
    static let loadToolsWhenNeeded = "prodigy.general.loadToolsWhenNeeded"
    /// Let the model search the connector/skill directory for relevant tools.
    static let connectorSearch = "prodigy.general.connectorSearch"
    /// Auto-switch models when a message is safety-flagged (vs pause the chat).
    static let switchModelsWhenFlagged = "prodigy.general.switchModelsWhenFlagged"

    // MARK: Visuals

    /// Generate artifacts in a dedicated side surface.
    static let artifactsEnabled = "prodigy.visuals.artifacts"
    /// Artifacts may embed model calls / interactive apps.
    static let aiPoweredArtifacts = "prodigy.visuals.aiPoweredArtifacts"
    /// Charts / diagrams / interactive viz inline in chat.
    static let inlineVisualizations = "prodigy.visuals.inlineVisualizations"
}

/// Window content zoom (like browser zoom). Persisted across launches.
enum ContentZoom {
    static let `default`: Double = 1.0
    static let minimum: Double = 0.75
    static let maximum: Double = 2.0
    static let step: Double = 0.1

    static func clamped(_ value: Double) -> Double {
        let stepped = (value / step).rounded() * step
        return min(maximum, max(minimum, stepped))
    }

    static func zoomIn(_ current: Double) -> Double {
        clamped(current + step)
    }

    static func zoomOut(_ current: Double) -> Double {
        clamped(current - step)
    }

    /// Percentage label for menus / settings (e.g. "100%").
    static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Scales the whole workspace (layout + hit testing) like browser zoom.
struct ContentZoomModifier: ViewModifier {
    let zoom: Double

    func body(content: Content) -> some View {
        let z = ContentZoom.clamped(zoom)
        GeometryReader { geo in
            content
                .frame(
                    width: geo.size.width / z,
                    height: geo.size.height / z,
                    alignment: .topLeading
                )
                .scaleEffect(z, anchor: .topLeading)
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: .topLeading
                )
        }
    }
}

extension View {
    /// Apply persisted UI zoom (avoid naming `contentZoom` — clashes with bindings).
    func prodigyContentZoom(_ zoom: Double) -> some View {
        modifier(ContentZoomModifier(zoom: zoom))
    }
}

/// Sizes the host NSWindow to a fraction of the screen on first show
/// (macOS often ignores SwiftUI `.defaultSize` when restoring windows).
struct WindowScreenSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.applyIfNeeded(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.applyIfNeeded(to: nsView.window)
        }
    }

    private static let appliedKey = "prodigy.window.screenSized.v1"

    private static func applyIfNeeded(to window: NSWindow?) {
        guard let window else { return }
        // Only auto-size once per install unless the user never got a proper frame.
        let already = UserDefaults.standard.bool(forKey: appliedKey)
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        let target = LayoutMetrics.defaultWindowSize(for: screen)
        let tooSmall = frame.width < LayoutMetrics.minWindowWidth + 40
            || frame.height < LayoutMetrics.minWindowHeight + 40
        // Also re-apply if restored window is far smaller than the display target.
        let muchSmallerThanDisplay = frame.width < target.width * 0.55
            || frame.height < target.height * 0.55
        guard !already || tooSmall || muchSmallerThanDisplay else { return }

        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: target.width, height: target.height)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        UserDefaults.standard.set(true, forKey: appliedKey)
    }
}
