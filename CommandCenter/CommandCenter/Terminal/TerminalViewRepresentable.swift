import AppKit
import SwiftTerm
import SwiftUI

/// NSViewRepresentable wrapper around SwiftTerm's AppKit `TerminalView`
/// (PLAN.md Step 5 / T7). Hosts a login shell in a PTY.
struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: TerminalSessionController
    var isFocused: Bool
    var onPaneShortcut: ((WorkspacePane) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onPaneShortcut: onPaneShortcut)
    }

    func makeNSView(context: Context) -> KeyPassthroughTerminalView {
        let terminal = KeyPassthroughTerminalView(frame: .zero)
        context.coordinator.terminal = terminal
        context.coordinator.attach(to: terminal)
        context.coordinator.applyAppearance(to: terminal)
        // Start shell only once per representable lifetime.
        if !context.coordinator.hasStartedOnce {
            context.coordinator.startShell(on: terminal)
        }
        return terminal
    }

    static func dismantleNSView(_ terminal: KeyPassthroughTerminalView, coordinator: Coordinator) {
        // Tab closed (or view truly disposed) — kill the PTY so we don't leak shells.
        if terminal.process.running {
            terminal.terminate()
        }
        coordinator.hasStartedOnce = false
        coordinator.terminal = nil
    }

    func updateNSView(_ terminal: KeyPassthroughTerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.onPaneShortcut = onPaneShortcut
        terminal.onPaneShortcut = { pane in
            onPaneShortcut?(pane)
        }

        // Focus: only grab the caret when this terminal is the active surface.
        // When another center tab is selected, resign so Chat can own the keyboard.
        DispatchQueue.main.async {
            guard let window = terminal.window else { return }
            if isFocused {
                if window.firstResponder !== terminal {
                    window.makeFirstResponder(terminal)
                }
            } else if window.firstResponder === terminal {
                window.makeFirstResponder(nil)
            }
        }

        // Restart after process-ended "Restart shell" only — never on tab re-select.
        if context.coordinator.lastRestartToken != session.restartToken {
            context.coordinator.lastRestartToken = session.restartToken
            if context.coordinator.hasStartedOnce {
                context.coordinator.restartShell(on: terminal)
            }
        }

        // Keep cell grid in sync with the pane frame (alt-screen resize for vim/less).
        terminal.needsLayout = true
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var session: TerminalSessionController
        var onPaneShortcut: ((WorkspacePane) -> Void)?
        weak var terminal: KeyPassthroughTerminalView?
        let processDelegate = TerminalProcessDelegate()
        var lastRestartToken: UInt = 0
        var hasStartedOnce = false

        init(session: TerminalSessionController, onPaneShortcut: ((WorkspacePane) -> Void)?) {
            self.session = session
            self.onPaneShortcut = onPaneShortcut
            processDelegate.controller = session
        }

        func attach(to terminal: KeyPassthroughTerminalView) {
            terminal.processDelegate = processDelegate
            terminal.onPaneShortcut = { [weak self] pane in
                self?.onPaneShortcut?(pane)
            }
            terminal.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            terminal.optionAsMetaKey = true
            // Avoid Metal packaging edge cases in ad-hoc personal builds.
            do {
                try terminal.setUseMetal(false)
            } catch {
                // Software renderer remains available.
            }
        }

        func applyAppearance(to terminal: KeyPassthroughTerminalView) {
            let background = Self.nsColor(named: "TerminalBackground") ?? NSColor.black
            let foreground = Self.nsColor(named: "TerminalText") ?? NSColor.textColor
            terminal.nativeBackgroundColor = background
            terminal.nativeForegroundColor = foreground
            terminal.layer?.backgroundColor = background.cgColor
            terminal.caretColor = Self.nsColor(named: "TerminalPrompt") ?? NSColor.systemGreen
        }

        func startShell(on terminal: KeyPassthroughTerminalView) {
            let shell = Self.userShell()
            let shellName = "-" + (shell as NSString).lastPathComponent
            let cwd = session.currentDirectory.flatMap { Self.pathFromOSC7($0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.path

            session.markRunning()
            hasStartedOnce = true
            lastRestartToken = session.restartToken

            terminal.startProcess(
                executable: shell,
                args: [],
                environment: nil,
                execName: shellName,
                currentDirectory: cwd
            )
            session.updateTitle((shell as NSString).lastPathComponent)
        }

        func restartShell(on terminal: KeyPassthroughTerminalView) {
            if terminal.process.running {
                terminal.terminate()
            }
            // Clear alt-screen / partial UI so Restart never leaves a frozen-looking buffer.
            terminal.getTerminal().resetToInitialState()
            terminal.setNeedsDisplay(terminal.bounds)
            startShell(on: terminal)
        }

        private static func userShell() -> String {
            if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
                return shell
            }
            // Fall back to the account shell via getpwuid.
            let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
            let capacity = bufsize > 0 ? bufsize : 4096
            var pwd = passwd()
            var result: UnsafeMutablePointer<passwd>?
            let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            if getpwuid_r(getuid(), &pwd, buffer, capacity, &result) == 0,
               result != nil {
                return String(cString: pwd.pw_shell)
            }
            return "/bin/zsh"
        }

        private static func pathFromOSC7(_ value: String) -> String? {
            if let url = URL(string: value), url.isFileURL { return url.path }
            if value.hasPrefix("/") { return value }
            return nil
        }

        private static func nsColor(named name: String) -> NSColor? {
            // Asset-catalog colors — same tokens as Theme, no raw hex.
            if let color = NSColor(named: name) {
                return color
            }
            // Bundle lookup for when the view is in a framework-like context.
            return NSColor(named: NSColor.Name(name), bundle: .main)
        }
    }
}
