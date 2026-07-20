import AppKit
import SwiftUI

/// Apple Liquid Glass metrics and helpers for Prodigy (macOS 26+).
///
/// Design rules (WWDC25 / HIG):
/// - Glass is for **discrete chrome cards**, not one fused slab.
/// - Keep gaps **tight** (Apple multi-column apps use ~6–8pt, not large voids).
/// - Prefer `.regular` / `.regular.interactive()` for controls; nested cards share the same language as Files/Terminal.
/// - Gap regions (between cards) must stay **Liquid Glass** in windowed **and**
///   fullscreen — never a solid opaque fill.
enum LiquidGlassMetrics {
    /// Outer pane radius — 0 for flush Cursor-style columns (sc1).
    static let paneCorner: CGFloat = 0
    /// Nested section radius (composer / chips only).
    static let nestedCorner: CGFloat = 8
    /// Composer field / dense controls.
    static let controlCorner: CGFloat = 10
    /// Gap between major columns — hairline only (sc1 / Cursor shell).
    /// Main columns use NSSplitView dividers; nested stacks use this as the
    /// drag handle thickness.
    static let interPaneGap: CGFloat = 1
    /// No outer window padding — panels go edge-to-edge (sc1).
    static let windowInset: CGFloat = 0
    /// Inset of content inside a split slot.
    static let slotInset: CGFloat = 0
    /// Visible hairline divider color lives on Theme.borderHairline.
    static let columnDividerWidth: CGFloat = 1
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

// MARK: - Ambient window fill (gaps between cards)

/// Full-window Liquid Glass backdrop. Cards float on top; **gaps between cards
/// reveal this glass** — same look in windowed and fullscreen (fullscreen has
/// no desktop wallpaper, so a solid color would read as opaque voids).
struct LiquidGlassAmbientBackground: View {
    var body: some View {
        ZStack {
            // System visual effect — reliable frosted fill in fullscreen spaces.
            LiquidGlassVisualEffectBackground(
                material: .underWindowBackground,
                blendingMode: .withinWindow
            )

            // Liquid Glass clear lens across the whole window so interstitial
            // space matches the glass language of the cards themselves.
            Color.clear
                .glassEffect(.clear, in: Rectangle())
        }
        .ignoresSafeArea()
    }
}

/// AppKit `NSVisualEffectView` wrapper — keeps gap regions frosted when the
/// window is fullscreen (SwiftUI materials alone often go solid black there).
struct LiquidGlassVisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
    }
}

// MARK: - Window chrome (transparent + fullscreen-safe)

/// Configures the hosting `NSWindow` for Liquid Glass in **windowed and fullscreen**.
/// macOS often resets opacity/background when entering fullscreen — we re-apply
/// on enter/exit notifications so interstitial glass stays transparent.
struct LiquidGlassWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onWindowChange = { window in
            context.coordinator.attach(to: window)
        }
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        deinit {
            detach()
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window === window {
                Self.apply(to: window)
                return
            }
            detach()
            self.window = window
            Self.apply(to: window)

            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                        guard let window = note.object as? NSWindow else { return }
                        // Fullscreen transition can run layout before the space settles.
                        Self.apply(to: window)
                        DispatchQueue.main.async {
                            Self.apply(to: window)
                        }
                        self?.window = window
                    }
                )
            }
        }

        func detach() {
            let center = NotificationCenter.default
            for token in observers {
                center.removeObserver(token)
            }
            observers.removeAll()
            window = nil
        }

        static func apply(to window: NSWindow) {
            // Flush sc1/sc2 shell: solid chrome that tracks Light/Dark assets.
            let bg = NSColor(named: "AppBackground") ?? .windowBackgroundColor
            window.isOpaque = true
            window.backgroundColor = bg
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }

            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = bg.cgColor
            window.contentView?.layer?.isOpaque = true

            if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
                titlebar.wantsLayer = true
                titlebar.layer?.backgroundColor = bg.cgColor
            }
        }

        private static func clearOpaqueBackgrounds(in view: NSView) {
            view.wantsLayer = true
            if view.layer?.backgroundColor != nil {
                // Don't wipe NSVisualEffectView — those are intentional gap fills.
                if !(view is NSVisualEffectView) {
                    let isHosting = String(describing: type(of: view)).contains("Hosting")
                    let isSplit = view is NSSplitView
                    if isHosting || isSplit || view.subviews.isEmpty == false {
                        // Keep structure; only force non-opaque where we own it.
                    }
                }
            }
            if view is NSSplitView {
                view.layer?.backgroundColor = NSColor.clear.cgColor
                view.layer?.isOpaque = false
            }
            for sub in view.subviews {
                if sub is NSVisualEffectView { continue }
                if sub is NSSplitView {
                    sub.wantsLayer = true
                    sub.layer?.backgroundColor = NSColor.clear.cgColor
                    sub.layer?.isOpaque = false
                }
                clearOpaqueBackgrounds(in: sub)
            }
        }
    }

    /// Notifies the representable when the view is re-parented into a window.
    private final class TrackingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            onWindowChange?(window)
        }
    }
}
