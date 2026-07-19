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
        var maxWidth: CGFloat?
        /// Higher priority resists growth when the split grows.
        var holdingPriority: NSLayoutConstraint.Priority
        var content: AnyView

        init(
            minWidth: CGFloat,
            idealWidth: CGFloat? = nil,
            maxWidth: CGFloat? = nil,
            holdingPriority: NSLayoutConstraint.Priority = .defaultLow,
            @ViewBuilder content: () -> some View
        ) {
            self.minWidth = minWidth
            self.idealWidth = idealWidth
            self.maxWidth = maxWidth
            self.holdingPriority = holdingPriority
            self.content = AnyView(content())
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
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.autosaveName = NSSplitView.AutosaveName(autosaveName)
        split.arrangesAllSubviews = true

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
        private var hasAppliedInitialWidths = false

        func apply(panes: [Pane], to split: NSSplitView, forceRebuild: Bool) {
            let needsRebuild = forceRebuild
                || panes.count != slots.count
                || panes.count != split.arrangedSubviews.count

            if needsRebuild {
                hasAppliedInitialWidths = false

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

                // Defer initial sizing until the split has a real bounds.
                DispatchQueue.main.async { [weak self, weak split] in
                    guard let self, let split else { return }
                    self.applyInitialOrRestoredWidths(to: split)
                }
            } else {
                for (index, pane) in panes.enumerated() where index < slots.count {
                    slots[index].setContent(pane.content)
                    split.setHoldingPriority(pane.holdingPriority, forSubviewAt: index)
                }
                paneSpecs = panes
            }
        }

        /// Prefer NSSplitView autosave restoration; if none exists yet, seed ideal widths.
        private func applyInitialOrRestoredWidths(to split: NSSplitView) {
            guard !hasAppliedInitialWidths, split.bounds.width > 0, !paneSpecs.isEmpty else { return }
            hasAppliedInitialWidths = true

            // If autosave already restored non-trivial frames, keep them.
            let existing = split.arrangedSubviews.map(\.frame.width)
            let hasRestoredFrames = existing.count == paneSpecs.count
                && existing.allSatisfy { $0 > 1 }
                && existing.reduce(0, +) > split.bounds.width * 0.5

            if hasRestoredFrames {
                return
            }

            let count = paneSpecs.count
            let divider = split.dividerThickness
            let available = max(split.bounds.width - CGFloat(max(count - 1, 0)) * divider, 0)

            var widths = paneSpecs.map { pane -> CGFloat in
                let ideal = pane.idealWidth ?? pane.minWidth
                var w = max(pane.minWidth, ideal)
                if let maxW = pane.maxWidth {
                    w = min(maxW, w)
                }
                return w
            }

            // Flexible pane (lowest holding priority) absorbs remainder.
            var flexibleIndex = count - 1
            var lowest = paneSpecs[0].holdingPriority
            flexibleIndex = 0
            for i in 1..<count {
                if paneSpecs[i].holdingPriority < lowest {
                    lowest = paneSpecs[i].holdingPriority
                    flexibleIndex = i
                }
            }

            let fixedSum = widths.enumerated()
                .filter { $0.offset != flexibleIndex }
                .map(\.element)
                .reduce(CGFloat(0), +)
            widths[flexibleIndex] = max(paneSpecs[flexibleIndex].minWidth, available - fixedSum)

            var x: CGFloat = 0
            let height = split.bounds.height
            for i in 0..<count {
                split.arrangedSubviews[i].setFrameSize(NSSize(width: widths[i], height: height))
                split.arrangedSubviews[i].setFrameOrigin(NSPoint(x: x, y: 0))
                x += widths[i] + divider
            }

            // Persist the seed so the next launch restores via autosave.
            split.adjustSubviews()
        }

        // MARK: NSSplitViewDelegate

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            var minX: CGFloat = 0
            for i in 0...dividerIndex where i < paneSpecs.count {
                minX += paneSpecs[i].minWidth
                if i < dividerIndex {
                    minX += splitView.dividerThickness
                }
            }
            return max(proposedMinimumPosition, minX)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            var reserved: CGFloat = 0
            let start = dividerIndex + 1
            if start < paneSpecs.count {
                for i in start..<paneSpecs.count {
                    reserved += paneSpecs[i].minWidth
                    if i > start {
                        reserved += splitView.dividerThickness
                    }
                }
                reserved += splitView.dividerThickness
            }
            let maxX = splitView.bounds.width - reserved

            if dividerIndex < paneSpecs.count, let maxWidth = paneSpecs[dividerIndex].maxWidth {
                let leftEdge = dividerIndex == 0
                    ? 0
                    : splitView.arrangedSubviews[dividerIndex].frame.minX
                return min(proposedMaximumPosition, min(maxX, leftEdge + maxWidth))
            }

            return min(proposedMaximumPosition, maxX)
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            // Keep fixed-intent panes at their widths; flexible pane absorbs delta.
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
            // First layout can report zeros — seed ideals.
            if widths.allSatisfy({ $0 < 1 }) {
                widths = paneSpecs.map { max($0.minWidth, $0.idealWidth ?? $0.minWidth) }
            }

            for i in 0..<count {
                widths[i] = max(paneSpecs[i].minWidth, widths[i])
                if let maxW = paneSpecs[i].maxWidth {
                    widths[i] = min(maxW, widths[i])
                }
            }

            var flexibleIndex = 0
            var lowest = paneSpecs[0].holdingPriority
            for i in 1..<count {
                if paneSpecs[i].holdingPriority < lowest {
                    lowest = paneSpecs[i].holdingPriority
                    flexibleIndex = i
                }
            }

            let fixedSum = widths.enumerated()
                .filter { $0.offset != flexibleIndex }
                .map(\.element)
                .reduce(CGFloat(0), +)
            widths[flexibleIndex] = max(paneSpecs[flexibleIndex].minWidth, available - fixedSum)

            let total = widths.reduce(0, +)
            if total > available {
                widths[flexibleIndex] = max(
                    paneSpecs[flexibleIndex].minWidth,
                    widths[flexibleIndex] - (total - available)
                )
            }

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
    }
}

// MARK: - Hosting slot

/// NSView that hosts a type-erased SwiftUI tree and fills its split-view slot.
private final class HostingSlot: NSView {
    private var hostingView: NSHostingView<AnyView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
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
            addSubview(host)
            hostingView = host
        }
    }
}

// MARK: - Thin split view subclass

/// Lets the split view participate cleanly in SwiftUI layout (intrinsic size flexible).
private final class WorkspaceNSSplitView: NSSplitView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
