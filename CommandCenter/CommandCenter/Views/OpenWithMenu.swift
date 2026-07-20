import AppKit
import SwiftUI

/// sc8-style “open with” menu: launch external apps or open in-app surfaces.
struct OpenWithMenuContent: View {
    let workspacePath: String
    var onOpenSafari: () -> Void
    var onOpenMail: () -> Void = {}
    var onOpenCalendar: () -> Void = {}

    var body: some View {
        Button {
            openInFinder(path: workspacePath)
        } label: {
            Label("Finder", systemImage: "folder.fill")
        }

        Button {
            if !openWithApp(name: "Visual Studio Code", path: workspacePath) {
                if !openWithApp(name: "Code", path: workspacePath) {
                    _ = openBundle("com.microsoft.VSCode", path: workspacePath)
                }
            }
        } label: {
            Label("VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        Button {
            _ = openBundle("com.apple.dt.Xcode", path: workspacePath)
        } label: {
            Label("Xcode", systemImage: "hammer.fill")
        }

        Button {
            if !openWithApp(name: "iTerm", path: workspacePath) {
                _ = openBundle("com.googlecode.iterm2", path: workspacePath)
            }
        } label: {
            Label("iTerm", systemImage: "terminal")
        }

        Button {
            _ = openBundle("com.apple.Terminal", path: workspacePath)
        } label: {
            Label("Terminal", systemImage: "terminal.fill")
        }

        Button {
            if !openBundle("com.github.GitHubClient", path: workspacePath) {
                _ = openWithApp(name: "GitHub Desktop", path: workspacePath)
            }
        } label: {
            Label("GitHub Desktop", systemImage: "arrow.triangle.branch")
        }

        Divider()

        Button {
            onOpenSafari()
        } label: {
            Label("Safari", systemImage: "safari")
        }

        Button {
            onOpenMail()
        } label: {
            Label("Mail", systemImage: "envelope.fill")
        }

        Button {
            onOpenCalendar()
        } label: {
            Label("Calendar", systemImage: "calendar")
        }

        Divider()

        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(workspacePath, forType: .string)
        } label: {
            Label("Copy path", systemImage: "doc.on.doc")
        }
    }

    private func openInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @discardableResult
    private func openBundle(_ bundleID: String, path: String?) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        return launch(appURL: appURL, path: path)
    }

    @discardableResult
    private func openWithApp(name: String, path: String?) -> Bool {
        let candidates = [
            "/Applications/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return launch(appURL: URL(fileURLWithPath: c), path: path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-a", name]
        if let path { args.append(path) }
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func launch(appURL: URL, path: String?) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        if let path {
            let item = URL(fileURLWithPath: path, isDirectory: true)
            NSWorkspace.shared.open([item], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
        return true
    }
}
