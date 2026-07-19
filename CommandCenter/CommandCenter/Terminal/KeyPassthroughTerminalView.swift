import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` subclass that implements the keyboard-passthrough
/// contract from PLAN.md T10 / design review Pass 6 #1-2.
///
/// Premise 1 names AppKit focus/keyboard routing between the embedded terminal
/// and workspace panes as a real secondary risk. The contract is:
/// - ⌘1–⌘4 return `false` from `performKeyEquivalent` so they bubble to the
///   window/menu and switch panes even while the shell is first responder.
/// - Every other key, **including Esc**, is forwarded to the terminal
///   untouched (so vim/less keep Esc; Esc must never flip the center pane).
final class KeyPassthroughTerminalView: LocalProcessTerminalView {

    /// Optional hook when a pane shortcut is observed. Primary routing still
    /// relies on returning `false` so AppKit menu key-equivalents fire.
    var onPaneShortcut: ((WorkspacePane) -> Void)?

    // MARK: - Keyboard passthrough (T10)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let pane = Self.workspacePane(for: event) {
            // Do not consume — pass through to the responder chain / main menu.
            // Menu items registered for ⌘1–⌘4 perform the actual pane switch.
            onPaneShortcut?(pane)
            return false
        }
        // Forward everything else (Esc, Ctrl-C, arrows, printable keys, …)
        // to TerminalView / AppKit default handling.
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘1–⌘4 only, with no other modifiers (Shift/Option/Control disqualify).
    static func workspacePane(for event: NSEvent) -> WorkspacePane? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.shift),
              !flags.contains(.option),
              !flags.contains(.control),
              let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let ch = chars.first
        else {
            return nil
        }
        switch ch {
        case "1": return .sidebar
        case "2": return .chat
        case "3": return .files
        case "4": return .terminal
        default: return nil
        }
    }

    // MARK: - Main-thread data feed (T7)

    /// Belt-and-suspenders: LocalProcess already defaults to `DispatchQueue.main`,
    /// but feed is not thread-safe, so force main-thread delivery if a custom
    /// queue ever feeds us off-main.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        if Thread.isMainThread {
            feed(byteArray: slice)
        } else {
            let bytes = Array(slice)
            DispatchQueue.main.async { [weak self] in
                self?.feed(byteArray: bytes[...])
            }
        }
    }

    // MARK: - Alt-screen / resize (T7)
    //
    // LocalProcessTerminalView.sizeChanged already pushes winsize to the PTY
    // (SIGWINCH) whenever the cell grid changes — that covers pane drag and
    // alt-screen apps (vim, less). No override needed; layout is driven by
    // the NSViewRepresentable keeping the view filled and needsLayout=true.
}
