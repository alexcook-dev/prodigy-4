import AppKit
import Foundation

/// Checks GitHub Releases for a newer production Prodigy build and can install
/// the DMG in-place.
///
/// **Private repo:** uses `gh auth token` or `GH_TOKEN` so release API/asset
/// downloads work. Without auth the GitHub API returns 404 and no toast appears.
///
/// Only the production app (`dev.alexcook.Prodigy`) auto-checks and shows the
/// update toast. Dev builds skip auto-check (Settings → Check still works).
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    static let productionBundleID = "dev.alexcook.Prodigy"
    static let repoOwner = "alexcook-dev"
    static let repoName = "prodigy-4"
    static let repoSlug = "\(repoOwner)/\(repoName)"

    struct AvailableUpdate: Equatable {
        let version: String
        let tag: String
        let notes: String
        /// API asset URL (needs auth for private repos) or public browser URL.
        let dmgDownloadURL: URL
        /// When true, download must send Authorization + Accept: octet-stream.
        let requiresAuthDownload: Bool
        let dmgName: String
        let htmlURL: URL?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(fraction: Double?)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var bannerDismissedForVersion: String?

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "prodigy.update.lastCheck"
    private let dismissedKey = "prodigy.update.dismissedVersion"
    private let minAutoCheckInterval: TimeInterval = 6 * 3600

    var isProductionBuild: Bool {
        Bundle.main.bundleIdentifier == Self.productionBundleID
    }

    var currentVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return Self.normalizeVersion(short ?? "0")
    }

    var availableUpdate: AvailableUpdate? {
        if case .available(let u) = phase { return u }
        return nil
    }

    var shouldShowBanner: Bool {
        // Toast only on production app so Xcode Dev doesn't nag.
        guard isProductionBuild else { return false }
        if case .available(let u) = phase {
            if bannerDismissedForVersion == u.version { return false }
            return true
        }
        // Surface private-repo auth failures so silence isn't mistaken for "up to date".
        if case .failed(let message) = phase {
            let lower = message.lowercased()
            return lower.contains("auth") || lower.contains("gh auth") || lower.contains("401") || lower.contains("403") || lower.contains("private")
        }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private init() {
        bannerDismissedForVersion = defaults.string(forKey: dismissedKey)
        if let t = defaults.object(forKey: lastCheckKey) as? Date {
            lastCheckedAt = t
        }
    }

    // MARK: - Public API

    /// Launch-time quiet check (production only, rate-limited).
    func checkOnLaunchIfNeeded() async {
        guard isProductionBuild else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < minAutoCheckInterval {
            return
        }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        if case .downloading = phase { return }
        if case .installing = phase { return }

        phase = .checking
        do {
            let token = try await resolveGitHubToken()
            let release = try await fetchLatestRelease(token: token)
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt, forKey: lastCheckKey)

            let remote = Self.normalizeVersion(release.version)
            let local = currentVersion
            if Self.isVersion(remote, greaterThan: local) {
                phase = .available(release)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dismissBanner() {
        guard case .available(let u) = phase else { return }
        bannerDismissedForVersion = u.version
        defaults.set(u.version, forKey: dismissedKey)
    }

    /// Clear a failed check toast (e.g. missing gh auth).
    func dismissFailureToast() {
        if case .failed = phase {
            phase = .idle
        }
    }

    /// Download the release DMG into Applications, install Prodigy.app from it, offer relaunch.
    func installAvailableUpdate() async {
        guard case .available(let update) = phase else { return }
        do {
            let token = try await resolveGitHubToken()
            phase = .downloading(fraction: nil)
            let dmgURL = try await downloadDMG(update: update, token: token) { [weak self] fraction in
                Task { @MainActor in
                    self?.phase = .downloading(fraction: fraction)
                }
            }
            phase = .installing
            let installedApp = try installDMG(at: dmgURL, releaseFileName: update.dmgName)
            // Temp download can go; permanent copies live in Applications.
            if dmgURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: dmgURL)
            }
            defaults.removeObject(forKey: dismissedKey)
            bannerDismissedForVersion = nil
            phase = .upToDate
            offerRelaunch(installedVersion: update.version, appURL: installedApp)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func openReleasePage() {
        guard case .available(let u) = phase, let html = u.htmlURL else {
            if let url = URL(string: "https://github.com/\(Self.repoSlug)/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(html)
    }

    // MARK: - GitHub

    private struct GHReleaseDTO: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String?
        let assets: [GHAssetDTO]
    }

    private struct GHAssetDTO: Decodable {
        let id: Int?
        let name: String
        let url: String
        let browser_download_url: String?
    }

    private func fetchLatestRelease(token: String?) async throws -> AvailableUpdate {
        let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("Invalid response from GitHub")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UpdateError.auth(
                "Private repo needs GitHub login. Run `gh auth login` in Terminal, then Check for Updates again."
            )
        }
        if http.statusCode == 404 {
            // Private repos return 404 without a valid token (not "no releases").
            if token == nil || token?.isEmpty == true {
                throw UpdateError.auth(
                    "Private repo: no GitHub token. Run `gh auth login` (or set GH_TOKEN), then retry."
                )
            }
            throw UpdateError.network("No releases found for \(Self.repoSlug).")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UpdateError.network("GitHub HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let dto = try JSONDecoder().decode(GHReleaseDTO.self, from: data)
        let version = Self.normalizeVersion(dto.tag_name)
        guard let asset = dto.assets.first(where: {
            $0.name.hasPrefix("Prodigy-") && $0.name.hasSuffix(".dmg")
        }) else {
            throw UpdateError.network("Release \(dto.tag_name) has no Prodigy-*.dmg asset.")
        }

        // Private: API asset URL + auth. Public: browser_download_url is fine.
        let hasToken = !(token ?? "").isEmpty
        let downloadString: String
        let requiresAuth: Bool
        if hasToken {
            downloadString = asset.url
            requiresAuth = true
        } else if let browser = asset.browser_download_url, !browser.isEmpty {
            downloadString = browser
            requiresAuth = false
        } else {
            downloadString = asset.url
            requiresAuth = true
        }
        guard let downloadURL = URL(string: downloadString) else {
            throw UpdateError.network("Invalid asset URL")
        }
        return AvailableUpdate(
            version: version,
            tag: dto.tag_name,
            notes: (dto.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            dmgDownloadURL: downloadURL,
            requiresAuthDownload: requiresAuth,
            dmgName: asset.name,
            htmlURL: dto.html_url.flatMap(URL.init(string:))
        )
    }

    private func downloadDMG(
        update: AvailableUpdate,
        token: String?,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: update.dmgDownloadURL)
        if update.requiresAuthDownload {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            guard let token, !token.isEmpty else {
                throw UpdateError.auth(
                    "Download needs GitHub auth. Run `gh auth login`, then retry Update."
                )
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        }

        onProgress(nil)
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 || code == 404 {
                throw UpdateError.auth(
                    "Could not download release (HTTP \(code)). Run `gh auth login` and retry."
                )
            }
            throw UpdateError.network("Download failed (HTTP \(code))")
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(update.dmgName, isDirectory: false)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        onProgress(1)
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = attrs[.size] as? NSNumber
        guard (size?.int64Value ?? 0) > 0 else {
            throw UpdateError.network("Downloaded empty DMG")
        }
        return dest
    }

    // MARK: - Auth (private repo)

    private func resolveGitHubToken() async throws -> String? {
        if let env = ProcessInfo.processInfo.environment["GH_TOKEN"]
            ?? ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
           !env.isEmpty {
            return env
        }
        if let fromGh = try? await runGhAuthToken(), !fromGh.isEmpty {
            return fromGh
        }
        return nil
    }

    private func runGhAuthToken() async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let gh = AppUpdateService.whichGh()
            let result = try AppUpdateService.runProcess(gh, arguments: ["auth", "token"])
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    nonisolated private static func whichGh() -> String {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "gh"
    }

    /// Prefer `/Applications`, fall back to `~/Applications`.
    private func applicationsDirectory() throws -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) {
            return system
        }
        // isWritableFile can lie for directories; probe with a temp file.
        let probe = system.appendingPathComponent(".prodigy-write-test")
        if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
            try? FileManager.default.removeItem(at: probe)
            return system
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Copies the DMG into Applications, mounts it, installs Prodigy.app next to it.
    /// Returns the installed `.app` URL.
    private func installDMG(at dmgURL: URL, releaseFileName: String) throws -> URL {
        let apps = try applicationsDirectory()
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

        // Permanent DMG in Applications (versioned + stable Prodigy.dmg).
        let versionedDMG = apps.appendingPathComponent(releaseFileName)
        let stableDMG = apps.appendingPathComponent("Prodigy.dmg")
        if FileManager.default.fileExists(atPath: versionedDMG.path) {
            try FileManager.default.removeItem(at: versionedDMG)
        }
        try FileManager.default.copyItem(at: dmgURL, to: versionedDMG)
        _ = try? run("/usr/bin/xattr", arguments: ["-cr", versionedDMG.path])

        if versionedDMG.path != stableDMG.path {
            if FileManager.default.fileExists(atPath: stableDMG.path) {
                try? FileManager.default.removeItem(at: stableDMG)
            }
            try FileManager.default.copyItem(at: versionedDMG, to: stableDMG)
            _ = try? run("/usr/bin/xattr", arguments: ["-cr", stableDMG.path])
        }

        let attach = try run(
            "/usr/bin/hdiutil",
            arguments: ["attach", versionedDMG.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard let mount = parseMountPoint(fromPlistXML: attach.stdout) else {
            throw UpdateError.install("Could not mount DMG")
        }
        defer {
            _ = try? run("/usr/bin/hdiutil", arguments: ["detach", mount, "-quiet"])
        }

        let src = URL(fileURLWithPath: mount).appendingPathComponent("Prodigy.app")
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw UpdateError.install("Prodigy.app not found inside DMG")
        }

        let dest = apps.appendingPathComponent("Prodigy.app")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        _ = try run("/usr/bin/ditto", arguments: [src.path, dest.path])
        _ = try? run("/usr/bin/xattr", arguments: ["-cr", dest.path])
        _ = try? run("/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", dest.path])
        return dest
    }

    private func offerRelaunch(installedVersion: String, appURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Prodigy \(installedVersion) installed"
        alert.informativeText = "The DMG is in Applications. Restart Prodigy to use the new version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Process helpers

    nonisolated private struct ProcResult: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    nonisolated private static func runProcess(_ launchPath: String, arguments: [String]) throws -> ProcResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath.hasPrefix("/") ? launchPath : "/usr/bin/env")
        if launchPath.hasPrefix("/") {
            process.arguments = arguments
        } else {
            process.arguments = [launchPath] + arguments
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw UpdateError.install("\(launchPath) failed: \(stderr.isEmpty ? stdout : stderr)")
        }
        return ProcResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    private func run(_ launchPath: String, arguments: [String]) throws -> ProcResult {
        try Self.runProcess(launchPath, arguments: arguments)
    }

    private func parseMountPoint(fromPlistXML xml: String) -> String? {
        // hdiutil -plist lists system-entities with mount-points.
        guard let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]]
        else {
            // Fallback: look for /Volumes/... in text
            if let range = xml.range(of: #"/Volumes/[^\s<"]+"#, options: .regularExpression) {
                return String(xml[range])
            }
            return nil
        }
        for entity in entities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                return mp
            }
        }
        return nil
    }

    // MARK: - Version compare

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        // Strip pre-release / build metadata for simple compare
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        return s
    }

    /// True if `lhs` is strictly greater than `rhs` (semver-ish dotted ints).
    static func isVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(a.count, b.count)
        for i in 0 ..< n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum UpdateError: LocalizedError, Sendable {
    case auth(String)
    case network(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .auth(let s), .network(let s), .install(let s): return s
        }
    }
}
