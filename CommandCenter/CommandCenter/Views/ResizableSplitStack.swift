import AppKit
import SwiftUI

/// Two stacked panes with a **gap handle** between them (not a drawn line).
/// Drag the handle to resize; min/max heights prevent overlap. Hover shows a
/// tooltip and a vertical-resize cursor (Finder / Xcode pattern).
struct ResizableVStack<Top: View, Bottom: View>: View {
    /// Fraction of available height given to the top pane (0…1), excluding gap.
    @Binding var topFraction: Double

    var minTop: CGFloat = LayoutMetrics.nestedPaneMinHeight
    var minBottom: CGFloat = LayoutMetrics.nestedPaneMinHeight
    /// Cap how large the top pane can grow as a fraction of free height.
    var maxTopFraction: Double = LayoutMetrics.nestedPaneMaxFraction
    /// Cap how large the bottom pane can grow (symmetric clamp on top).
    var maxBottomFraction: Double = LayoutMetrics.nestedPaneMaxFraction
    var gap: CGFloat = LiquidGlassMetrics.interPaneGap
    var tooltip: String = "Drag to resize"

    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.height, 1)
            let free = max(total - gap, 1)
            let clamped = Self.clampFraction(
                topFraction,
                free: free,
                minTop: minTop,
                minBottom: minBottom,
                maxTopFraction: maxTopFraction,
                maxBottomFraction: maxBottomFraction
            )
            let topH = free * clamped
            let bottomH = free - topH

            VStack(spacing: 0) {
                top()
                    .frame(width: geo.size.width, height: topH, alignment: .top)
                    .clipped()

                ResizeHandle(
                    axis: .vertical,
                    tooltip: tooltip,
                    onDrag: { delta in
                        let next = topFraction + Double(delta / free)
                        topFraction = Self.clampFraction(
                            next,
                            free: free,
                            minTop: minTop,
                            minBottom: minBottom,
                            maxTopFraction: maxTopFraction,
                            maxBottomFraction: maxBottomFraction
                        )
                    }
                )
                .frame(width: geo.size.width, height: gap)

                bottom()
                    .frame(width: geo.size.width, height: bottomH, alignment: .top)
                    .clipped()
            }
            .onAppear {
                topFraction = clamped
            }
            .onChange(of: geo.size.height) { _, _ in
                topFraction = Self.clampFraction(
                    topFraction,
                    free: free,
                    minTop: minTop,
                    minBottom: minBottom,
                    maxTopFraction: maxTopFraction,
                    maxBottomFraction: maxBottomFraction
                )
            }
        }
    }

    static func clampFraction(
        _ value: Double,
        free: CGFloat,
        minTop: CGFloat,
        minBottom: CGFloat,
        maxTopFraction: Double,
        maxBottomFraction: Double
    ) -> Double {
        guard free > 0 else { return 0.5 }
        let minTopF = Double(minTop / free)
        let minBottomF = Double(minBottom / free)
        // Room left after mins
        let maxTopByMin = 1.0 - minBottomF
        let minTopByMin = minTopF
        let lo = max(minTopByMin, 1.0 - maxBottomFraction)
        let hi = min(maxTopByMin, maxTopFraction)
        let low = min(lo, hi)
        let high = max(lo, hi)
        return min(max(value, low), high)
    }
}

// MARK: - Handle

private enum ResizeAxis {
    case vertical
    case horizontal
}

/// Invisible hit target in the gap between cards. Always shows tooltip on hover
/// and the platform resize cursor so users know the edge is draggable.
private struct ResizeHandle: View {
    let axis: ResizeAxis
    let tooltip: String
    let onDrag: (CGFloat) -> Void

    @State private var isHovering = false

    var body: some View {
        ResizeHandleRepresentable(
            axis: axis,
            tooltip: tooltip,
            isHovering: $isHovering,
            onDrag: onDrag
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Drag to change the size of the adjacent panes")
    }
}

/// AppKit hit-testing for reliable cursor + tooltip on the full gap edge.
private struct ResizeHandleRepresentable: NSViewRepresentable {
    let axis: ResizeAxis
    let tooltip: String
    @Binding var isHovering: Bool
    let onDrag: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(axis: axis, onDrag: onDrag)
    }

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        view.axis = axis
        view.toolTip = tooltip
        view.onHover = { hovering in
            isHovering = hovering
        }
        view.onDrag = { delta in
            onDrag(delta)
        }
        return view
    }

    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.axis = axis
        view.toolTip = tooltip
        view.onDrag = { delta in
            onDrag(delta)
        }
        view.onHover = { hovering in
            isHovering = hovering
        }
    }

    final class Coordinator {
        let axis: ResizeAxis
        let onDrag: (CGFloat) -> Void
        init(axis: ResizeAxis, onDrag: @escaping (CGFloat) -> Void) {
            self.axis = axis
            self.onDrag = onDrag
        }
    }
}

private final class ResizeHandleView: NSView {
    var axis: ResizeAxis = .vertical
    var onDrag: ((CGFloat) -> Void)?
    var onHover: ((Bool) -> Void)?

    private var tracking: NSTrackingArea?
    private var dragStart: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect,
            .cursorUpdate,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor = (axis == .vertical) ? .resizeUpDown : .resizeLeftRight
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        let cursor: NSCursor = (axis == .vertical) ? .resizeUpDown : .resizeLeftRight
        cursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        let cursor: NSCursor = (axis == .vertical) ? .resizeUpDown : .resizeLeftRight
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = (axis == .vertical) ? p.y : p.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        // AppKit Y grows upward; SwiftUI layout grows downward for top pane height.
        if axis == .vertical {
            let delta = start - p.y
            dragStart = p.y
            onDrag?(delta)
        } else {
            let delta = p.x - start
            dragStart = p.x
            onDrag?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
