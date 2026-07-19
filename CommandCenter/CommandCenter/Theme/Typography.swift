import SwiftUI

/// San Francisco type scale for Prodigy.
///
/// Uses the system font (SF Pro / SF Mono) via SwiftUI semantic text styles so
/// Dynamic Type and platform metrics stay correct. Prefer these over ad-hoc
/// point sizes so the UI matches Apple HIG.
enum AppTypography {
    /// Primary reading text (chat body, list rows).
    static let body = Font.body

    /// Slightly tighter body for dense chrome.
    static let callout = Font.callout

    /// Section headers ("PROJECTS", "AGENTS", panel titles).
    static let section = Font.subheadline.weight(.semibold)

    /// Secondary labels, captions under rows.
    static let secondary = Font.subheadline

    /// Compact filters / chips / kbd hints.
    static let caption = Font.caption

    /// Smallest chrome (status, tertiary hints).
    static let caption2 = Font.caption2

    /// Emphasized actions (primary buttons).
    static let action = Font.body.weight(.semibold)

    /// Monospaced SF Mono for paths / keycaps.
    static let mono = Font.body.monospaced()
    static let monoCaption = Font.caption.monospaced()
}
