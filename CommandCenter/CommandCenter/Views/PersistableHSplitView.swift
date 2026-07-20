import AppKit
import SwiftUI

/// A horizontal multi-pane layout backed by AppKit `NSSplitView`.
///
/// Dividers are draggable; widths are persisted via `autosaveName` (UserDefaults).
/// Use a distinct autosave name per layout mode (wide vs narrow) so collapsing the
/// right column does not corrupt the three-column divider positions.
///
/// Holding priority is low on the flexible pane (center) so it absorbs free space;
/// fixed-intent panes (sidebar, right column) keep their dragged widths.
struct PersistableHSplitView: NSViewRepresentable {
    struct Pane {
        var minWidth: CGFloat
        var idealWidth: CGFloat?
        /// Preferred share of available split width (e.g. 0.25 = 25%). Wins over idealWidth when set.
        var idealFraction: CGFloat?
        var maxWidth: CGFloat?
        /// Cap as a fraction of available width (e.g. 0.40). Combined with maxWidth when both set.
        var maxFraction: CGFloat?
        /// Higher priority resists growth when the split grows.
        var holdingPriority: NSLayoutConstraint.Priority
        var content: AnyView

        init(
            minWidth: CGFloat,
            idealWidth: CGFloat? = nil,
            idealFraction: CGFloat? = nil,
            maxWidth: CGFloat? = nil,
            maxFraction: CGFloat? = nil,
            holdingPriority: NSLayoutConstraint.Priority = .defaultLow,
            @ViewBuilder content: () -> some View
        ) {
            self.minWidth = minWidth
            self.idealWidth = idealWidth
            self.idealFraction = idealFraction
            self.maxWidth = maxWidth
            self.maxFraction = maxFraction
            self.holdingPriority = holdingPriority
            self.content = AnyView(content())
        }

        func resolvedMaxWidth(available: CGFloat) -> CGFloat? {
            let fromFraction = maxFraction.map { available * $0 }
            switch (maxWidth, fromFraction) {
            case let (a?, b?): return min(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    let autosaveName: String
    let panes: [Pane]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let split = WorkspaceNSSplitView()
        split.isVertical = true // vertical divider → side-by-side panes
        // Transparent, thicker dividers so floating glass cards have air between them.
        split.dividerStyle = .paneSplitter
        split.delegate = context.coordinator
        split.autosaveName = NSSplitView.AutosaveName(autosaveName)
        split.arrangesAllSubviews = true
        split.wantsLayer = true
        split.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.splitView = split
        context.coordinator.autosaveName = autosaveName
        context.coordinator.apply(panes: panes, to: split, forceRebuild: true)

        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        if split.autosaveName != NSSplitView.AutosaveName(autosaveName) {
            split.autosaveName = NSSplitView.AutosaveName(autosaveName)
            context.coordinator.autosaveName = autosaveName
        }
        context.coordinator.apply(panes: panes, to: split, forceRebuild: false)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        var autosaveName: String = ""
        private var slots: [HostingSlot] = []
        private var paneSpecs: [Pane] = []
        /// After the user drags a divider we stop auto-reapplying fractions.
        private var userHasCustomizedWidths = false
        private var isApplyingProgrammaticLayout = false
        private var lastSplitWidth: CGFloat = 0
        private var lastPaneWidths: [CGFloat] = []
        private var pendingFractionApply = false

        private var usesFractions: Bool {
            paneSpecs.contains { $0.idealFraction != nil }
        }

        private var customizedKey: String {
            "prodigy.split.customized.\(autosaveName)"
        }

        func apply(panes: [Pane], to split: NSSplitView, forceRebuild: Bool) {
            let needsRebuild = forceRebuild
                || panes.count != slots.count
                || panes.count != split.arrangedSubviews.count

            if needsRebuild {
                userHasCustomizedWidths = UserDefaults.standard.bool(forKey: customizedKey)
                lastSplitWidth = 0
                lastPaneWidths = []

                for view in split.arrangedSubviews {
                    split.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                slots.removeAll(keepingCapacity: true)

                for pane in panes {
                    let slot = HostingSlot()
                    slot.setContent(pane.content)
                    split.addArrangedSubview(slot)
                    slots.append(slot)
                }

                for (index, pane) in panes.enumerated() {
                    split.setHoldingPriority(pane.holdingPriority, forSubviewAt: index)
                }

                paneSpecs = panes
                scheduleFractionLayout(on: split, attemptsLeft: 12)
            } else {
                for (index, pane) in panes.enumerated() where index < slots.count {
                    slots[index].setContent(pane.content)
                    split.setHoldingPriority(pane.holdingPriority, forSubviewAt: index)
                }
                paneSpecs = panes
            }
        }

        /// Retry until the split has a real width (first frame is often 0).
        private func scheduleFractionLayout(on split: NSSplitView, attemptsLeft: Int) {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.async { [weak self, weak split] in
                guard let self, let split else { return }
                if split.bounds.width < 2 {
                    self.scheduleFractionLayout(on: split, attemptsLeft: attemptsLeft - 1)
                    return
                }
                if self.usesFractions && !self.userHasCustomizedWidths {
                    self.applyFractionalLayout(to: split)
                } else {
                    self.applyNonOverlappingLayout(to: split)
                }
            }
        }

        /// Force 25% / 50% / 25% (or whatever idealFraction is set) of the live width.
        private func applyFractionalLayout(to split: NSSplitView) {
            guard !paneSpecs.isEmpty, split.bounds.width > 1 else { return }
            guard usesFractions else {
                applyNonOverlappingLayout(to: split)
                return
            }

            let count = paneSpecs.count
            let divider = split.dividerThickness
            let available = max(split.bounds.width - CGFloat(max(count - 1, 0)) * divider, 0)
            guard available > 1 else { return }

            var widths = paneSpecs.map { pane -> CGFloat in
                if let f = pane.idealFraction {
                    return available * f
                }
                return max(pane.minWidth, pane.idealWidth ?? pane.minWidth)
            }
            let sum = widths.reduce(CGFloat(0), +)
            if sum > 0 {
                let scale = available / sum
                widths = widths.map { $0 * scale }
            }
            widths = Self.clampWidths(widths, specs: paneSpecs, available: available)

            isApplyingProgrammaticLayout = true
            defer { isApplyingProgrammaticLayout = false }

            var x: CGFloat = 0
            let height = max(split.bounds.height, 1)
            for i in 0..<count {
                split.arrangedSubviews[i].frame = NSRect(
                    x: x, y: 0, width: widths[i], height: height
                )
                x += widths[i] + divider
            }
            lastSplitWidth = split.bounds.width
            lastPaneWidths = widths
            // Write frames so NSSplitView autosave stores the fraction layout.
            split.adjustSubviews()
        }

        // MARK: NSSplitViewDelegate

        func splitView(_ splitView: NSSplitView, canCollapse subview: NSView) -> Bool {
            // Never collapse a column — collapse is what lets neighbors overlap.
            false
        }

        /// Leftmost legal divider position (see `dividerLimits`).
        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let limits = dividerLimits(splitView, dividerIndex: dividerIndex)
            return max(proposedMinimumPosition, limits.min)
        }

        /// Rightmost legal divider position (see `dividerLimits`).
        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let limits = dividerLimits(splitView, dividerIndex: dividerIndex)
            return min(proposedMaximumPosition, limits.max)
        }

        /// Legal [min, max] range for a divider so panes never overlap or exceed
        /// max widths. When mins don't fit the window, range collapses to a
        /// single point (no room to drag) instead of min > max.
        private func dividerLimits(
            _ splitView: NSSplitView,
            dividerIndex: Int
        ) -> (min: CGFloat, max: CGFloat) {
            let divider = splitView.dividerThickness
            let count = paneSpecs.count
            let width = splitView.bounds.width
            guard count > 0, dividerIndex >= 0, dividerIndex < count - 1, width > 0 else {
                return (0, width)
            }

            // Left group mins (panes 0…dividerIndex).
            var leftMins: CGFloat = 0
            for i in 0...dividerIndex {
                leftMins += paneSpecs[i].minWidth
                if i < dividerIndex { leftMins += divider }
            }

            // Right group mins (panes after divider).
            var rightMins: CGFloat = 0
            let rightStart = dividerIndex + 1
            for i in rightStart..<count {
                rightMins += paneSpecs[i].minWidth
                if i > rightStart { rightMins += divider }
            }

            // Divider cannot enter the right-min reserved zone.
            var lo = leftMins
            var hi = width - divider - rightMins

            let available = max(width - CGFloat(max(count - 1, 0)) * divider, 0)

            // Right-group max widths: divider cannot go left of (width - div - rightMaxes).
            if rightStart < count {
                var rightMaxSum: CGFloat = 0
                var allHaveMax = true
                for i in rightStart..<count {
                    guard let maxW = paneSpecs[i].resolvedMaxWidth(available: available) else {
                        allHaveMax = false
                        break
                    }
                    rightMaxSum += maxW
                    if i > rightStart { rightMaxSum += divider }
                }
                if allHaveMax {
                    let fromRightMax = width - divider - rightMaxSum
                    // Only apply if it doesn't invert the range past left mins.
                    if fromRightMax <= hi {
                        lo = max(lo, fromRightMax)
                    }
                }
            }

            // Left-group max: pane at dividerIndex.
            if dividerIndex < splitView.arrangedSubviews.count,
               let maxWidth = paneSpecs[dividerIndex].resolvedMaxWidth(available: available) {
                let leftEdge = splitView.arrangedSubviews[dividerIndex].frame.minX
                let fromLeftMax = leftEdge + maxWidth
                if fromLeftMax >= lo {
                    hi = min(hi, fromLeftMax)
                }
            }

            // If all left panes publish a max, also cap by their sum.
            var leftMaxSum: CGFloat = 0
            var allLeftHaveMax = true
            for i in 0...dividerIndex {
                guard let maxW = paneSpecs[i].resolvedMaxWidth(available: available) else {
                    allLeftHaveMax = false
                    break
                }
                leftMaxSum += maxW
                if i < dividerIndex { leftMaxSum += divider }
            }
            if allLeftHaveMax, leftMaxSum >= lo {
                hi = min(hi, leftMaxSum)
            }

            // Conflict (window narrower than sum of mins): collapse to a point
            // so NSSplitView never gets min > max (which enables free overlap).
            if lo > hi {
                // Prefer keeping left mins when possible.
                let preferred = min(leftMins, max(width - divider - rightMins, 0))
                let x = min(max(preferred, 0), max(width - divider, 0))
                return (x, x)
            }

            return (lo, hi)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            guard !isApplyingProgrammaticLayout else { return }

            let widths = splitView.arrangedSubviews.map(\.frame.width)
            let total = splitView.bounds.width

            // Same overall width but panes moved → user dragged a divider.
            if usesFractions,
               lastSplitWidth > 1,
               abs(total - lastSplitWidth) < 1.5,
               lastPaneWidths.count == widths.count {
                let moved = zip(widths, lastPaneWidths).contains { abs($0 - $1) > 2 }
                if moved {
                    userHasCustomizedWidths = true
                    UserDefaults.standard.set(true, forKey: customizedKey)
                }
            }

            lastSplitWidth = total
            lastPaneWidths = widths

            // Only clamp — do not re-force fractions here (avoids a layout loop).
            if userHasCustomizedWidths || !usesFractions {
                applyNonOverlappingLayout(to: splitView)
            }
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            guard !isApplyingProgrammaticLayout else { return }
            // Window grew/shrank: re-apply 25/50/25 so layout tracks display/window size.
            if usesFractions && !userHasCustomizedWidths,
               abs(oldSize.width - splitView.bounds.width) > 1 {
                applyFractionalLayout(to: splitView)
                return
            }
            applyNonOverlappingLayout(to: splitView)
        }

        /// Assign non-overlapping frames that honor min/max and never sum past
        /// the split bounds (fixes window-shrink and drag-past-max overlap).
        private func applyNonOverlappingLayout(to splitView: NSSplitView) {
            guard !splitView.arrangedSubviews.isEmpty, !paneSpecs.isEmpty else { return }

            let count = splitView.arrangedSubviews.count
            guard count == paneSpecs.count else {
                splitView.adjustSubviews()
                return
            }

            let divider = splitView.dividerThickness
            let totalDividers = CGFloat(max(count - 1, 0)) * divider
            let available = max(splitView.bounds.width - totalDividers, 0)

            var widths = splitView.arrangedSubviews.map(\.frame.width)
            if widths.allSatisfy({ $0 < 1 }) {
                widths = paneSpecs.map { max($0.minWidth, $0.idealWidth ?? $0.minWidth) }
            }

            widths = Self.clampWidths(
                widths,
                specs: paneSpecs,
                available: available
            )

            var x: CGFloat = 0
            let height = splitView.bounds.height
            for i in 0..<count {
                splitView.arrangedSubviews[i].frame = NSRect(
                    x: x,
                    y: 0,
                    width: widths[i],
                    height: height
                )
                x += widths[i] + divider
            }
        }

        /// Fit `widths` into `available` without overlap.
        /// Prefer shrinking the flexible (lowest holding priority) pane; if mins
        /// still don't fit, scale everything proportionally so frames never stack.
        static func clampWidths(
            _ input: [CGFloat],
            specs: [Pane],
            available: CGFloat
        ) -> [CGFloat] {
            let count = specs.count
            guard count > 0, available > 0 else {
                return specs.map(\.minWidth)
            }

            var widths = input
            if widths.count != count {
                widths = specs.map { max($0.minWidth, $0.idealWidth ?? $0.minWidth) }
            }

            // Hard clamp each pane into [min, max] (absolute and/or fractional max).
            for i in 0..<count {
                widths[i] = max(specs[i].minWidth, widths[i])
                if let maxW = specs[i].resolvedMaxWidth(available: available) {
                    widths[i] = min(maxW, widths[i])
                }
            }

            var flexibleIndex = 0
            var lowest = specs[0].holdingPriority
            for i in 1..<count {
                if specs[i].holdingPriority < lowest {
                    lowest = specs[i].holdingPriority
                    flexibleIndex = i
                }
            }

            let fixedSum = widths.enumerated()
                .filter { $0.offset != flexibleIndex }
                .map(\.element)
                .reduce(CGFloat(0), +)

            // Flexible pane takes the remainder (within its own min/max).
            var flex = available - fixedSum
            flex = max(specs[flexibleIndex].minWidth, flex)
            if let maxW = specs[flexibleIndex].maxWidth {
                flex = min(maxW, flex)
            }
            widths[flexibleIndex] = flex

            var total = widths.reduce(0, +)
            if total <= available + 0.5 {
                // Absorb tiny slack into flexible pane if under and room under max.
                let slack = available - total
                if slack > 0.5 {
                    var room = slack
                    if let maxW = specs[flexibleIndex].maxWidth {
                        room = min(room, maxW - widths[flexibleIndex])
                    }
                    if room > 0 {
                        widths[flexibleIndex] += room
                    }
                }
                return widths
            }

            // Still over: shrink panes that are above their min, flexible first,
            // then others with surplus, never below minWidth.
            var deficit = total - available
            // Pass 1 — flexible
            let flexSurplus = widths[flexibleIndex] - specs[flexibleIndex].minWidth
            if flexSurplus > 0 {
                let cut = min(flexSurplus, deficit)
                widths[flexibleIndex] -= cut
                deficit -= cut
            }
            // Pass 2 — other panes above min (prefer higher holding-priority sides
            // that the user grew large, i.e. anything with surplus).
            if deficit > 0.5 {
                for i in 0..<count where i != flexibleIndex {
                    let surplus = widths[i] - specs[i].minWidth
                    guard surplus > 0 else { continue }
                    let cut = min(surplus, deficit)
                    widths[i] -= cut
                    deficit -= cut
                    if deficit <= 0.5 { break }
                }
            }

            // Pass 3 — absolute emergency: available < sum(mins). Scale mins so
            // frames still tile without overlapping (rare tiny windows).
            total = widths.reduce(0, +)
            if total > available + 0.5 {
                let minSum = specs.map(\.minWidth).reduce(CGFloat(0), +)
                if minSum > 0 {
                    let scale = available / max(minSum, total)
                    for i in 0..<count {
                        widths[i] = max(1, widths[i] * scale)
                    }
                    // Fix rounding so sum == available.
                    let sum = widths.reduce(0, +)
                    if abs(sum - available) > 0.5, !widths.isEmpty {
                        widths[flexibleIndex] = max(1, widths[flexibleIndex] + (available - sum))
                    }
                }
            }

            return widths
        }
    }
}

// MARK: - Hosting slot

/// NSView that hosts a type-erased SwiftUI tree and fills its split-view slot.
private final class HostingSlot: NSView {
    private var hostingView: NSHostingView<AnyView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        // Clip so a pane never paints over its neighbor when the split is tight.
        clipsToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ content: AnyView) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            // Transparent host so SwiftUI Liquid Glass can sample content behind.
            if #available(macOS 14.0, *) {
                // layer-backed clear
            }
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(host)
            hostingView = host
        }
    }
}

// MARK: - Transparent split view subclass

/// Flush multi-column shell (sc1 / Cursor-style): **1pt hairline dividers**
/// between edge-to-edge panes — no floating card gaps.
private final class WorkspaceNSSplitView: NSSplitView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Thin column separator (not a wide glass gap).
    override var dividerThickness: CGFloat {
        LiquidGlassMetrics.columnDividerWidth
    }

    override func drawDivider(in rect: NSRect) {
        // sc1/sc2 hairline — asset color adapts with Light/Dark appearance.
        let color = NSColor(named: "BorderHairline") ?? NSColor.separatorColor
        color.setFill()
        let hairline = NSRect(
            x: floor(rect.midX),
            y: rect.minY,
            width: 1,
            height: rect.height
        )
        hairline.fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func resetCursorRects() {
        discardCursorRects()
        // Always show horizontal resize cursor on every divider gap.
        let thickness = dividerThickness
        guard thickness > 0, !arrangedSubviews.isEmpty else { return }
        var x: CGFloat = 0
        for (index, sub) in arrangedSubviews.enumerated() {
            x += sub.frame.width
            if index < arrangedSubviews.count - 1 {
                let rect = NSRect(x: x, y: 0, width: thickness, height: bounds.height)
                addCursorRect(rect, cursor: .resizeLeftRight)
                // Tooltip so hover always explains the edge is movable.
                // (NSView toolTip is one string; set on the split — refined below.)
                x += thickness
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Ensure cursor rects refresh when layout changes.
        window?.invalidateCursorRects(for: self)
        // Per-divider tooltips via tracking areas owned by the split.
        trackingAreas
            .filter { ($0.userInfo?["prodigyDivider"] as? Bool) == true }
            .forEach { removeTrackingArea($0) }

        let thickness = dividerThickness
        guard thickness > 0, !arrangedSubviews.isEmpty else { return }
        var x: CGFloat = 0
        for (index, sub) in arrangedSubviews.enumerated() {
            x += sub.frame.width
            if index < arrangedSubviews.count - 1 {
                let rect = NSRect(x: x, y: 0, width: thickness, height: bounds.height)
                let area = NSTrackingArea(
                    rect: rect,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: ["prodigyDivider": true]
                )
                addTrackingArea(area)
                x += thickness
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["prodigyDivider"] as? Bool == true {
            toolTip = "Drag to resize panes"
            NSCursor.resizeLeftRight.set()
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["prodigyDivider"] as? Bool == true {
            toolTip = nil
            NSCursor.arrow.set()
        }
        super.mouseExited(with: event)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        needsUpdateConstraints = true
        // Rebuild tracking areas after layout so tooltips track divider positions.
        updateTrackingAreas()
    }
}
