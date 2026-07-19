import AppKit
import SwiftUI

/// Semantic color tokens mapped to **Apple system colors**.
///
/// Light and Dark automatically follow the system (or the user’s Prodigy
/// appearance setting) via `NSColor` dynamic providers — no custom Light/Dark
/// hex pairs. Matches standard macOS apps (Mail, Notes, Finder lists).
///
/// Views should use these tokens (or SwiftUI `Color.primary` / `.secondary`)
/// rather than hard-coded RGB.
enum Theme {
    // MARK: - Surfaces

    /// App chrome / outer window background.
    static let appBackground = Color(nsColor: .windowBackgroundColor)

    /// Dominant center chat/preview surface (document/text well).
    static let centerBackground = Color(nsColor: .textBackgroundColor)

    /// Deepest edge / hairline companion.
    static let deepest = Color(nsColor: .separatorColor)

    /// Sidebar / list chrome.
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)

    /// Elevated controls (fields, chips, sheets).
    static let elevatedSurface = Color(nsColor: .controlBackgroundColor)

    /// Terminal panel background (system text well — adapts in Light/Dark).
    static let terminalBackground = Color(nsColor: .textBackgroundColor)

    // MARK: - Text

    /// Body / primary labels.
    static let textPrimary = Color(nsColor: .labelColor)

    /// Secondary captions, section headers.
    static let textSecondary = Color(nsColor: .secondaryLabelColor)

    /// Tertiary / decorative chrome.
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    /// Default list row label (unselected).
    static let textRow = Color(nsColor: .labelColor)

    /// Text drawn on accent / selected fills.
    static let textOnAccent = Color(nsColor: .alternateSelectedControlTextColor)

    // MARK: - Accent

    /// System control accent (user’s accent color from System Settings).
    static let accent = Color(nsColor: .controlAccentColor)

    /// Links / accent text — system accent (adapts for contrast).
    static let accentText = Color(nsColor: .controlAccentColor)

    /// Keyboard focus indicator.
    static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)

    // MARK: - Status

    /// Actively streaming tokens.
    static let statusBusy = Color(nsColor: .systemOrange)

    /// Unread completed activity.
    static let statusDone = Color(nsColor: .systemGreen)

    // MARK: - Error

    static let errorBackground = Color(nsColor: .systemRed).opacity(0.12)
    static let errorBorder = Color(nsColor: .systemRed).opacity(0.45)
    static let errorText = Color(nsColor: .systemRed)

    // MARK: - Borders

    static let borderStructural = Color(nsColor: .separatorColor)
    static let borderHairline = Color(nsColor: .separatorColor)
    static let controlBorder = Color(nsColor: .separatorColor)

    // MARK: - Selection / messages

    /// Selected list row / control (system blue or user accent).
    static let selectionFill = Color(nsColor: .selectedContentBackgroundColor)

    /// File tree selection.
    static let fileSelectionFill = Color(nsColor: .selectedContentBackgroundColor)

    /// User chat bubble fill — subtle system fill (not a custom brand color).
    static let userMessageFill = Color(nsColor: .quaternaryLabelColor).opacity(0.35)

    static let userMessageBorder = Color(nsColor: .separatorColor)

    // MARK: - Terminal

    static let terminalText = Color(nsColor: .textColor)
    static let terminalPrompt = Color(nsColor: .controlAccentColor)

    // MARK: - Chrome

    static let chipBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.25)
    static let kbdBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.20)
}

// MARK: - Layout constants (from wireframe proportions + T16 window behavior)

enum LayoutMetrics {
    // MARK: Sidebar

    /// Left sidebar ideal width (wf-1 `224px`).
    static let sidebarWidth: CGFloat = 224
    static let sidebarMinWidth: CGFloat = 160
    static let sidebarMaxWidth: CGFloat = 320

    // MARK: Center

    /// Center pane must stay usable when tiled; no hard floor on the window itself.
    static let centerMinWidth: CGFloat = 280

    /// Max readable width for center-pane chat content on large/external displays
    /// (PLAN.md Responsive & Accessibility: ~900–1000px).
    static let maxReadingWidth: CGFloat = 960

    // MARK: Right column

    /// Right column ideal width (wf-1 `320px`).
    static let rightColumnWidth: CGFloat = 320
    static let rightColumnMinWidth: CGFloat = 200
    static let rightColumnMaxWidth: CGFloat = 480

    /// Overlay drawer width when the right column is collapsed at narrow widths.
    static let rightColumnDrawerWidth: CGFloat = 320

    /// Below this window width the right column (Files/Terminal) collapses to an
    /// overlay/drawer — Mail.app / Xcode pattern. No hard minimum window size;
    /// ~650–700px tiles are daily use. 3-col needs roughly 224+360+320 ≈ 900.
    static let rightColumnCollapseBreakpoint: CGFloat = 960

    // MARK: Window

    static let defaultWindowWidth: CGFloat = 1200
    static let defaultWindowHeight: CGFloat = 760

    /// Soft platform floor only — deliberately low so windows can tile to ~650–700.
    /// PLAN.md: "No hard minimum window size."
    static let minWindowWidth: CGFloat = 480
    static let minWindowHeight: CGFloat = 360
}
