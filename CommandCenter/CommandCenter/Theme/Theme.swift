import SwiftUI

/// Semantic color tokens for the workspace shell.
///
/// All values live in the asset catalog as adaptive Light/Dark color sets.
/// Views must use these tokens only — never raw hex, never ad-hoc Color(red:…).
///
/// Dark values follow PLAN.md Visual System; Light values are the Step 1
/// derivation (D7 / T15) so system appearance switches without relaunch.
enum Theme {
    // MARK: - Surfaces

    /// App chrome / outer window background.
    static let appBackground = Color("AppBackground")

    /// Dominant center chat/preview surface.
    static let centerBackground = Color("CenterBackground")

    /// Deepest surface / window border edge.
    static let deepest = Color("Deepest")

    /// Left sidebar fill.
    static let sidebarBackground = Color("SidebarBackground")

    /// Elevated controls (composer field, tip cards, chips).
    static let elevatedSurface = Color("ElevatedSurface")

    /// Terminal panel background (stays dark in both appearances).
    static let terminalBackground = Color("TerminalBackground")

    // MARK: - Text

    /// Body / primary labels. Clears 4.5:1 on center and app surfaces.
    static let textPrimary = Color("TextPrimary")

    /// Secondary captions, section headers, legends. Clears 4.5:1.
    static let textSecondary = Color("TextSecondary")

    /// Decorative only (kbd chrome, collapse chevrons). Not for functional captions.
    static let textTertiary = Color("TextTertiary")

    /// Default sidebar / list row label (unselected).
    static let textRow = Color("TextRow")

    /// Text drawn on accent fills (selected row, primary CTA).
    static let textOnAccent = Color("TextOnAccent")

    // MARK: - Accent

    /// Non-text UI accent: selection fill, focus ring, primary CTA, borders.
    static let accent = Color("Accent")

    /// Text/link accent — contrast-safe variant, never use `accent` for body text.
    static let accentText = Color("AccentText")

    /// Focus outline around the active pane.
    static let focusRing = Color("FocusRing")

    // MARK: - Status

    /// Actively streaming tokens (focused or background).
    static let statusBusy = Color("StatusBusy")

    /// Unread completed activity (clears when the thread is next opened).
    static let statusDone = Color("StatusDone")

    // MARK: - Error

    static let errorBackground = Color("ErrorBackground")
    static let errorBorder = Color("ErrorBorder")
    static let errorText = Color("ErrorText")

    // MARK: - Borders

    /// Structural section dividers.
    static let borderStructural = Color("BorderStructural")

    /// Hairline panel separators.
    static let borderHairline = Color("BorderHairline")

    /// Secondary control outlines (Stop, pills).
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

// MARK: - Layout constants (from wireframe proportions)

enum LayoutMetrics {
    /// Left sidebar column width (wf-1 `224px`).
    static let sidebarWidth: CGFloat = 224

    /// Right column width (wf-1 `320px`).
    static let rightColumnWidth: CGFloat = 320

    /// Default minimum window size that still shows all three columns.
    static let defaultWindowWidth: CGFloat = 1200
    static let defaultWindowHeight: CGFloat = 760
    static let minWindowWidth: CGFloat = 900
    static let minWindowHeight: CGFloat = 520
}
