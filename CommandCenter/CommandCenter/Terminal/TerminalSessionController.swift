import AppKit
import Combine
import Foundation
import SwiftTerm

/// Owns terminal session UI state: cwd title, process-ended banner, restart.
///
/// A crashed or exited shell must never look like a frozen pane (PLAN.md
/// Constraints + Interaction States table + T7). When the PTY child exits we
/// surface "Shell exited (code N)" with a Restart action.
@MainActor
final class TerminalSessionController: ObservableObject {
    @Published private(set) var isProcessRunning: Bool = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var headerTitle: String = "zsh"
    @Published private(set) var currentDirectory: String?

    /// Bumps when Restart is requested so the representable can respawn.
    @Published private(set) var restartToken: UInt = 0

    var showsProcessEndedBar: Bool { !isProcessRunning }

    var processEndedMessage: String {
        if let exitCode {
            return "Shell exited (code \(exitCode))"
        }
        return "Shell exited"
    }

    func markRunning() {
        isProcessRunning = true
        exitCode = nil
    }

    func markTerminated(exitCode: Int32?) {
        isProcessRunning = false
        self.exitCode = exitCode
    }

    func updateTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        headerTitle = trimmed.isEmpty ? "zsh" : trimmed
    }

    func updateDirectory(_ directory: String?) {
        currentDirectory = directory
        if let directory, let path = Self.displayPath(fromOSC7: directory) {
            headerTitle = path
        }
    }

    func requestRestart() {
        restartToken &+= 1
    }

    /// OSC 7 may be a `file://` URL; surface a short path for the header.
    private static func displayPath(fromOSC7 value: String) -> String? {
        if let url = URL(string: value), url.isFileURL {
            return abbreviateHome(url.path)
        }
        if value.hasPrefix("/") {
            return abbreviateHome(value)
        }
        return nil
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - LocalProcessTerminalViewDelegate bridge

/// Thin AppKit-side delegate that posts process lifecycle into the controller.
/// Kept off the SwiftUI view so the representable coordinator can own it.
final class TerminalProcessDelegate: LocalProcessTerminalViewDelegate {
    weak var controller: TerminalSessionController?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // PTY winsize already updated by KeyPassthroughTerminalView/LocalProcessTerminalView.
        // No window-level resize — the terminal lives inside a fixed pane.
        _ = (source, newCols, newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            controller?.updateTitle(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor in
            controller?.updateDirectory(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            controller?.markTerminated(exitCode: exitCode)
        }
    }
}
