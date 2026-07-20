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

    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    static let textTertiary = Color("TextTertiary")
    static let textRow = Color("TextRow")
    static let textOnAccent = Color("TextOnAccent")

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

// MARK: - Layout constants (from sc1/sc2 shell proportions)

enum LayoutMetrics {
    // MARK: Sidebar

    /// Left sidebar ideal width — sc1 / sc2 proportions.
    static let sidebarWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 320

    // MARK: Center

    static let centerMinWidth: CGFloat = 360

    /// Max readable width for chat text on large displays (panel still fills).
    static let maxReadingWidth: CGFloat = 920

    // MARK: Right column

    static let rightColumnWidth: CGFloat = 360
    static let rightColumnMinWidth: CGFloat = 240
    static let rightColumnMaxWidth: CGFloat = 520
    static let rightColumnDrawerWidth: CGFloat = 360
    static let rightColumnCollapseBreakpoint: CGFloat = 1000

    // MARK: Window

    static let defaultWindowWidth: CGFloat = 1400
    static let defaultWindowHeight: CGFloat = 860
    static let minWindowWidth: CGFloat = 640
    static let minWindowHeight: CGFloat = 420

    // MARK: Nested resizable stacks

    static let nestedPaneMinHeight: CGFloat = 120
    static let nestedPaneMaxFraction: Double = 0.82
    static let rightColumnFilesDefaultFraction: Double = 0.68
    static let sidebarProjectsDefaultFraction: Double = 0.62
    static let settingsCardHeight: CGFloat = 40
}
