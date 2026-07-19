import AppKit
import SwiftUI

/// Apple Liquid Glass metrics and helpers for Prodigy (macOS 26+).
///
/// Design rules (WWDC25 / HIG):
/// - Glass is for **discrete chrome cards**, not one fused slab.
/// - Keep gaps **tight** (Apple multi-column apps use ~6–8pt, not large voids).
/// - Prefer `.regular` / `.regular.interactive()` for controls; nested cards share the same language as Files/Terminal.
enum LiquidGlassMetrics {
    /// Outer rounded card radius for major panes (sidebar column / center).
    static let paneCorner: CGFloat = 14
    /// Nested cards (Projects, Agents, Files, Terminal).
    static let nestedCorner: CGFloat = 12
    /// Composer field / dense controls.
    static let controlCorner: CGFloat = 10
    /// Gap between floating glass cards (also NSSplitView divider thickness).
    static let interPaneGap: CGFloat = 6
    /// Inset from the window edge.
    static let windowInset: CGFloat = 6
    /// Inset of a glass card inside a split slot.
    static let slotInset: CGFloat = 1
}

// MARK: - View modifiers

extension View {
    /// Floating major pane card.
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

    /// Nested card (Projects / Agents / Files / Terminal).
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

    /// Inset a floating glass card inside an NSSplitView slot.
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

/// Neutral ambient fill so glass has light to sample (no blue tint).
struct LiquidGlassAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark
                ? Color(nsColor: .windowBackgroundColor).opacity(0.40)
                : Color(nsColor: .windowBackgroundColor).opacity(0.50))

            EllipticalGradient(
                colors: [
                    Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    Color.clear,
                ],
                center: .topLeading,
                startRadiusFraction: 0.05,
                endRadiusFraction: 0.85
            )
            EllipticalGradient(
                colors: [
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadiusFraction: 0.0,
                endRadiusFraction: 0.75
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.50 : 0.35)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Window chrome

/// Clear / full-size-content window so Liquid Glass can composite correctly.
struct LiquidGlassWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
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
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
