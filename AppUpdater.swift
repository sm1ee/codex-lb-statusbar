import Cocoa
import CryptoKit
import Foundation

/// Self-updater backed by GitHub Releases (Sparkle-style: check -> prompt -> download -> verify -> replace -> relaunch).
///
/// Integrity checks before anything is replaced:
/// - the DMG's SHA-256 must match the `digest` GitHub publishes for the release asset,
/// - the app inside must have the same bundle identifier and the advertised version,
/// - `codesign --verify --deep --strict` must pass.
/// The app is ad-hoc signed, so this proves integrity of what the release published, not publisher identity.
@MainActor
final class AppUpdater {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let size: Int
            let digest: String?
        }

        let tagName: String
        let htmlUrl: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    struct Update {
        let version: String
        let release: Release
        let asset: Release.Asset
        let sha256: String
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case noAsset
        case missingDigest
        case checksumMismatch
        case notReplaceable(String)
        case invalidBundle(String)
        case command(String)

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return "GitHub returned HTTP \(code)."
            case .noAsset:
                return "The latest release has no CodexLBStatusBar DMG."
            case .missingDigest:
                return "The release asset has no published SHA-256 digest, so it can't be verified."
            case .checksumMismatch:
                return "The downloaded DMG doesn't match the published SHA-256 digest."
            case .notReplaceable(let reason):
                return reason
            case .invalidBundle(let reason):
                return "The downloaded app failed verification: \(reason)"
            case .command(let message):
                return message
            }
        }
    }

    static let releasesPage = URL(string: "https://github.com/sm1ee/codex-lb-statusbar/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/sm1ee/codex-lb-statusbar/releases/latest")!

    private let session: URLSession
    private let decoder: JSONDecoder

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// Returns the latest published release when it's newer than the running app.
    func checkForUpdate() async throws -> Update? {
        let release: Release = try await fetchJSON(Self.latestReleaseAPI)
        guard !release.draft, !release.prerelease, isNewerVersion(release.tagName, than: currentVersion) else {
            return nil
        }
        guard let asset = release.assets.first(where: { isAppUpdateAsset($0.name) }) else {
            throw UpdateError.noAsset
        }
        guard let sha256 = sha256FromDigest(asset.digest) else {
            throw UpdateError.missingDigest
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return Update(version: version, release: release, asset: asset, sha256: sha256)
    }

    /// Latest published (non-draft, non-prerelease) release tag of any public repo, e.g. "Soju06/codex-lb".
    func latestReleaseTag(repo: String) async throws -> (tag: String, url: URL) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.command("Invalid repository \(repo)")
        }
        let release: Release = try await fetchJSON(url)
        return (release.tagName, release.htmlUrl)
    }

    /// Reason the running copy can't be replaced in place, or nil when installing is possible.
    func installBlocker() -> String? {
        let bundlePath = Bundle.main.bundlePath
        guard canSelfUpdate(bundlePath: bundlePath) else {
            return "Move CodexLBStatusBar.app to the Applications folder and open it from there, then update."
        }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return "No write permission for \(parent). Download the update manually from GitHub."
        }
        return nil
    }

    /// Downloads, verifies, and stages the update, then hands off to a helper that swaps the bundle
    /// after this process exits and relaunches the new version. Terminates the app on success.
    func install(_ update: Update, progress: @escaping (String) -> Void) async throws {
        if let blocker = installBlocker() {
            throw UpdateError.notReplaceable(blocker)
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-lb-statusbar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        progress("Downloading \(update.asset.name)...")
        let (downloaded, response) = try await session.download(from: update.asset.browserDownloadUrl)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        let dmg = work.appendingPathComponent(update.asset.name)
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        progress("Verifying download...")
        let digest = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == update.sha256 else {
            throw UpdateError.checksumMismatch
        }

        progress("Preparing update...")
        let mountPoint = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        let staged = work.appendingPathComponent("CodexLBStatusBar.app", isDirectory: true)
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint.path)
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateError.invalidBundle("no app bundle in the DMG")
            }
            try await run("/usr/bin/ditto", [mountPoint.appendingPathComponent(appName).path, staged.path])
        } catch {
            try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            throw error
        }
        try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])

        try verifyBundle(at: staged, expectedVersion: update.version)
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        } catch {
            throw UpdateError.invalidBundle("code signature is invalid")
        }

        progress("Installing and relaunching...")
        try launchSwapHelper(staged: staged, workDir: work)
        NSApp.terminate(nil)
    }

    private func verifyBundle(at url: URL, expectedVersion: String) throws {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.invalidBundle("missing Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("bundle identifier differs from the installed app")
        }
        guard let version = info["CFBundleShortVersionString"] as? String,
              compareVersions(version, expectedVersion) == .orderedSame else {
            throw UpdateError.invalidBundle("version doesn't match the release tag")
        }
    }

    /// The helper waits for this PID to exit, swaps the bundle (keeping a backup until the copy succeeds),
    /// and reopens the app. All paths are passed as positional arguments, never interpolated into the script.
    private func launchSwapHelper(staged: URL, workDir: URL) throws {
        let script = """
        pid="$1"; target="$2"; staged="$3"; work="$4"
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        backup="$work/previous.app"
        if mv "$target" "$backup" && /usr/bin/ditto "$staged" "$target"; then
          /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
          rm -rf "$backup"
        else
          rm -rf "$target"; mv "$backup" "$target"
        fi
        /usr/bin/open "$target"
        rm -rf "$work"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "codex-lb-updater",
                             String(ProcessInfo.processInfo.processIdentifier),
                             Bundle.main.bundlePath, staged.path, workDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexLBStatusBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw UpdateError.command("\((executable as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }.value
    }
}

/// Small floating window that shows installer progress (the menu can't stay open during a download).
@MainActor
final class UpdateProgressWindow {
    private let window: NSPanel
    private let label: NSTextField

    init(title: String) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        label = NSTextField(labelWithString: "Starting...")
        label.translatesAutoresizingMaskIntoConstraints = false
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)
        let content = NSView()
        content.addSubview(label)
        content.addSubview(indicator)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            indicator.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])
        window.contentView = content
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ message: String) {
        label.stringValue = message
    }

    func close() {
        window.orderOut(nil)
    }
}
