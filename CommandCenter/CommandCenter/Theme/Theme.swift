import AppKit
import SwiftUI

/// Semantic color tokens for Prodigy’s shell.
///
/// ## Design references (Desktop)
/// | File | Mode | View |
/// |------|------|------|
/// | `sc1.png` | **Dark** | Workspace: chat + files + terminal |
/// | `sc2.png` | **Light** | Workspace: empty/minimal chat |
/// | `sc3.png` | **Light** | **Dashboard** — project board columns |
/// | `sc4.png` | **Light** | Workspace: **active chat** (markdown, composer focus) |
/// | `sc5.png` | **Light** | File preview: **HTML** rendered + Preview/Edit |
/// | `sc6.png` | **Light** | File preview: **image** centered canvas |
/// | `sc7.png` | **Light** | File preview: **text/code** with line numbers |
///
/// Dark palette tracks sc1; light palette tracks sc2/sc3/sc4 (same chrome).
/// Tokens resolve through the asset catalog so Settings → Appearance works.
enum Theme {
    // MARK: - Surfaces (sc1 dark / sc2 light)

    /// Outer chrome / window fill.
    static let appBackground = Color("AppBackground")

    /// Dominant center chat/preview surface (sc2 pure white / sc1 near-black).
    static let centerBackground = Color("CenterBackground")

    /// Deepest edge companion.
    static let deepest = Color("Deepest")

    /// Sidebar list chrome (sc2 cool gray / sc1 elevated charcoal).
    static let sidebarBackground = Color("SidebarBackground")

    /// Elevated controls (composer card, chips, sheets).
    static let elevatedSurface = Color("ElevatedSurface")

    /// Terminal panel background (matches center in both modes).
    static let terminalBackground = Color("TerminalBackground")

    // MARK: - Text
    //
    // Use system label colors so Light/Dark always stay readable (sc2 light =
    // near-black labels on gray chrome). Asset-catalog text tokens previously
    // paired with white-on-selection caused white-on-light in the sidebar.

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let textRow = Color(nsColor: .labelColor)
    /// Text drawn on a **saturated accent** fill (true control accent / blue).
    /// Not for the soft sidebar selection chip (use `textPrimary` there).
    static let textOnAccent = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: - Accent

    /// System control accent (still follows the user’s accent color).
    static let accent = Color(nsColor: .controlAccentColor)
    static let accentText = Color(nsColor: .controlAccentColor)
    static let focusRing = Color("FocusRing")

    // MARK: - Status

    static let statusBusy = Color("StatusBusy")
    static let statusDone = Color("StatusDone")

    // MARK: - Error

    static let errorBackground = Color("ErrorBackground")
    static let errorBorder = Color("ErrorBorder")
    static let errorText = Color("ErrorText")

    // MARK: - Borders (hairlines between flush columns)

    static let borderStructural = Color("BorderStructural")
    static let borderHairline = Color("BorderHairline")
    static let controlBorder = Color("ControlBorder")

    // MARK: - Selection / messages

    static let selectionFill = Color("SelectionFill")
    static let fileSelectionFill = Color("FileSelectionFill")
    static let userMessageFill = Color("UserMessageFill")
    static let userMessageBorder = Color("UserMessageBorder")

    // MARK: - Terminal

    static let terminalText = Color("TerminalText")
    static let terminalPrompt = Color("TerminalPrompt")

    // MARK: - Chrome

    static let chipBackground = Color("ChipBackground")
    static let kbdBackground = Color("KbdBackground")
}

// MARK: - Layout constants (display-relative shell)

enum LayoutMetrics {
    // MARK: Main column fractions (of window width after hairline dividers)

    /// Left sidebar default share of the split.
    static let sidebarDefaultFraction: CGFloat = 0.25
    /// Center (chat / browser) default share.
    static let centerDefaultFraction: CGFloat = 0.50
    /// Right files/terminal default share.
    static let rightColumnDefaultFraction: CGFloat = 0.25

    /// Narrow (2-pane) layout: sidebar / center when right column collapses.
    static let sidebarNarrowDefaultFraction: CGFloat = 0.25
    static let centerNarrowDefaultFraction: CGFloat = 0.75

    /// How far a side pane can grow when dragged (still leaves room for center).
    static let sidePaneMaxFraction: CGFloat = 0.40

    // MARK: Absolute mins (floor so columns stay usable on small displays)

    static let sidebarMinWidth: CGFloat = 160
    static let centerMinWidth: CGFloat = 280
    static let rightColumnMinWidth: CGFloat = 160

    /// Legacy absolute ideals (used only as fallbacks when fraction is unavailable).
    static let sidebarWidth: CGFloat = 240
    static let rightColumnWidth: CGFloat = 360
    /// Soft absolute caps — primary limit is `sidePaneMaxFraction`.
    static let sidebarMaxWidth: CGFloat = 1200
    static let rightColumnMaxWidth: CGFloat = 1200

    /// Max readable width for chat text on large displays (panel still fills).
    static let maxReadingWidth: CGFloat = 920

    static let rightColumnDrawerWidth: CGFloat = 360
    /// Collapse right column below this window width (still scales with small screens).
    static let rightColumnCollapseBreakpoint: CGFloat = 900

    // MARK: Window (fraction of the active display’s visible frame)

    static let windowWidthScreenFraction: CGFloat = 0.92
    static let windowHeightScreenFraction: CGFloat = 0.88
    static let minWindowWidth: CGFloat = 640
    static let minWindowHeight: CGFloat = 420

    /// Fallback when no screen is available yet.
    static let defaultWindowWidth: CGFloat = 1400
    static let defaultWindowHeight: CGFloat = 860

    /// Size the main window relative to the user’s display.
    static func defaultWindowSize(for screen: NSScreen? = NSScreen.main) -> (width: CGFloat, height: CGFloat) {
        let frame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: defaultWindowWidth, height: defaultWindowHeight)
        let width = max(minWindowWidth, floor(frame.width * windowWidthScreenFraction))
        let height = max(minWindowHeight, floor(frame.height * windowHeightScreenFraction))
        return (width, height)
    }

    // MARK: Nested resizable stacks

    static let nestedPaneMinHeight: CGFloat = 120
    static let nestedPaneMaxFraction: Double = 0.82
    static let rightColumnFilesDefaultFraction: Double = 0.68
    static let sidebarProjectsDefaultFraction: Double = 0.62
    static let settingsCardHeight: CGFloat = 40
}
