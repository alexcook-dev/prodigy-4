import SwiftUI

/// Apple Liquid Glass (macOS 26+) chrome helpers for Prodigy.
///
/// Use glass on **controls and navigational surfaces** (sidebar, tabs, composer,
/// panel headers, drawer). Keep primary reading content (message stream,
/// terminal buffer) clear enough to stay legible.
enum LiquidGlassMetrics {
    static let paneCorner: CGFloat = 18
    static let controlCorner: CGFloat = 12
    static let pillCorner: CGFloat = 9
    static let interPaneSpacing: CGFloat = 10
    static let windowInset: CGFloat = 10
}

extension View {
    /// Full-height pane chrome (sidebar, center shell, right column).
    func liquidGlassPane(cornerRadius: CGFloat = LiquidGlassMetrics.paneCorner) -> some View {
        self
            .background(Color.clear)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// Interactive control chrome (composer field, chips, small panels).
    func liquidGlassControl(
        cornerRadius: CGFloat = LiquidGlassMetrics.controlCorner,
        interactive: Bool = true
    ) -> some View {
        let glass: Glass = interactive ? .regular.interactive() : .regular
        return self
            .background(Color.clear)
            .glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// Capsule / pill glass (model·effort chips, compact tabs).
    func liquidGlassCapsule(interactive: Bool = true) -> some View {
        let glass: Glass = interactive ? .regular.interactive() : .regular
        return self
            .background(Color.clear)
            .glassEffect(glass, in: Capsule(style: .continuous))
    }

    /// Clearer glass for overlays that should feel lighter (drawer dim stack).
    func liquidGlassClear(cornerRadius: CGFloat = LiquidGlassMetrics.paneCorner) -> some View {
        self
            .background(Color.clear)
            .glassEffect(
                .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// Soft ambient fill so glass has color/light to refract when the desktop is flat.
struct LiquidGlassAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Base — near-clear so wallpaper can participate when the window is translucent.
            Color.clear

            // Gentle radial washes (system accent + cool neutral) behind the panes.
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 520
            )
            RadialGradient(
                colors: [
                    Color.cyan.opacity(colorScheme == .dark ? 0.14 : 0.10),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 480
            )
            LinearGradient(
                colors: [
                    Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.06),
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.03),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}
