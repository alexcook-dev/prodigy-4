import AppKit
import SwiftUI

/// Apple Liquid Glass metrics and helpers for Prodigy (macOS 26+).
///
/// Design rules (WWDC25):
/// - Glass is for **chrome** (sidebar, floating controls, cards) — not full-bleed
///   opaque content areas that need dense reading contrast.
/// - Leave **air** between glass shapes so refraction reads as separate lenses.
/// - Prefer `.regular` / `.regular.interactive()` for controls; `.clear` for light shells.
enum LiquidGlassMetrics {
    /// Outer rounded card radius for major panes.
    static let paneCorner: CGFloat = 22
    /// Nested cards (Files / Terminal within the right column).
    static let nestedCorner: CGFloat = 16
    /// Composer field / dense controls.
    static let controlCorner: CGFloat = 14
    /// Gap between floating glass panes (also used as split divider thickness).
    static let interPaneGap: CGFloat = 12
    /// Inset from the window edge so panes float inside the frame.
    static let windowInset: CGFloat = 12
    /// Inset of glass shape inside an NSSplitView slot.
    static let slotInset: CGFloat = 2
}

// MARK: - View modifiers

extension View {
    /// Floating major pane: glass lens with continuous rounded corners.
    /// Apply **inside** split slots; pair with transparent split dividers for gaps.
    func liquidGlassCard(
        cornerRadius: CGFloat = LiquidGlassMetrics.paneCorner,
        interactive: Bool = false
    ) -> some View {
        let material: Glass = interactive ? .regular.interactive() : .regular
        return self
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEffect(
                material,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// Nested card (Files / Terminal stack).
    func liquidGlassNested(interactive: Bool = false) -> some View {
        liquidGlassCard(
            cornerRadius: LiquidGlassMetrics.nestedCorner,
            interactive: interactive
        )
    }

    /// Interactive control field (composer).
    func liquidGlassControl(
        cornerRadius: CGFloat = LiquidGlassMetrics.controlCorner,
        interactive: Bool = true
    ) -> some View {
        let material: Glass = interactive ? .regular.interactive() : .regular
        return self
            .background(Color.clear)
            .glassEffect(
                material,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// Capsule chip (model / effort / compact tabs).
    func liquidGlassCapsule(interactive: Bool = true) -> some View {
        let material: Glass = interactive ? .regular.interactive() : .regular
        return self
            .background(Color.clear)
            .glassEffect(material, in: Capsule(style: .continuous))
    }

    /// Lighter clear glass for secondary chrome strips.
    func liquidGlassClearBar(cornerRadius: CGFloat = LiquidGlassMetrics.controlCorner) -> some View {
        self
            .background(Color.clear)
            .glassEffect(
                .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    /// Inset a floating glass card inside an NSSplitView slot so neighboring
    /// cards don't share an edge (divider gap + slot inset).
    func liquidGlassFloatingSlot(
        cornerRadius: CGFloat = LiquidGlassMetrics.paneCorner
    ) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassCard(cornerRadius: cornerRadius)
            .padding(LiquidGlassMetrics.slotInset)
    }
}

// MARK: - Ambient window fill

/// Neutral ambient fill so glass has light to refract without blue tint.
/// Kept translucent so the desktop can participate when the window is clear.
struct LiquidGlassAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Soft neutral base (not pure clear — pure clear can make glass look flat).
            (colorScheme == .dark
                ? Color(nsColor: .windowBackgroundColor).opacity(0.35)
                : Color(nsColor: .windowBackgroundColor).opacity(0.45))

            // Subtle depth — desaturated, no accent blue.
            EllipticalGradient(
                colors: [
                    Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07),
                    Color.clear,
                ],
                center: .topLeading,
                startRadiusFraction: 0.05,
                endRadiusFraction: 0.85
            )
            EllipticalGradient(
                colors: [
                    Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadiusFraction: 0.0,
                endRadiusFraction: 0.75
            )

            // Ultra-thin material veil so Liquid Glass has real blur sample content.
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.55 : 0.40)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Window chrome (transparent titlebar so glass reads correctly)

/// Configures the hosting `NSWindow` for Liquid Glass: clear background,
/// transparent titlebar, full-size content. Apply once on the root view.
struct LiquidGlassWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            Self.apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(to: nsView.window)
        }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        // Let the content view composite glass against the ambient fill.
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
