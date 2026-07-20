import SwiftUI

/// Native macOS type styles (San Francisco via system text styles).
/// Prefer these over point sizes so Dynamic Type and HIG metrics apply.
enum AppTypography {
    /// Primary reading text.
    static let body = Font.body

    /// Dense chrome / secondary body.
    static let callout = Font.callout

    /// Section headers.
    static let section = Font.subheadline.weight(.semibold)

    /// Secondary labels.
    static let secondary = Font.subheadline

    /// Compact filters / chips.
    static let caption = Font.caption

    /// Smallest chrome.
    static let caption2 = Font.caption2

    /// Emphasized actions.
    static let action = Font.body.weight(.semibold)

    /// Monospaced system font (paths / keycaps / code).
    static let mono = Font.body.monospaced()
    static let monoCaption = Font.caption.monospaced()
}
