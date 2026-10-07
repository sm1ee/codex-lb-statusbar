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

    /// One line of installer progress: the message, the download fraction while bytes are moving
    /// (nil for phases without byte counts), and the received/total detail line.
    struct Progress {
        let message: String
        let fraction: Double?
        let detail: String?
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case noAsset
        case missingDigest
        case checksumMismatch
        case noRelease(String)
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
            case .noRelease(let repo):
                return "No releases found for \(repo)."
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

    /// Newest release tag for `repo`. `includePrereleases` scans the release list instead of
    /// `/releases/latest`, which never returns a prerelease.
    func latestReleaseTag(repo: String, includePrereleases: Bool = false) async throws -> (tag: String, url: URL) {
        guard includePrereleases else {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
                throw UpdateError.command("Invalid repository \(repo)")
            }
            let release: Release = try await fetchJSON(url)
            return (release.tagName, release.htmlUrl)
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30") else {
            throw UpdateError.command("Invalid repository \(repo)")
        }
        let releases: [Release] = try await fetchJSON(url)
        let published = releases.filter { !$0.draft }
        guard let tag = newestVersionTag(published.map(\.tagName)),
              let release = published.first(where: { $0.tagName == tag }) else {
            throw UpdateError.noRelease(repo)
        }
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
    func install(_ update: Update, progress: @escaping (Progress) -> Void) async throws {
        if let blocker = installBlocker() {
            throw UpdateError.notReplaceable(blocker)
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-lb-statusbar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Failed installs used to leave the DMG and the staged app behind; the swap helper takes
        // ownership of the folder once it is launched, so only clean up before that.
        var handedOffToHelper = false
        defer {
            if !handedOffToHelper {
                try? FileManager.default.removeItem(at: work)
            }
        }

        let assetName = update.asset.name
        let totalBytes = Int64(update.asset.size)
        progress(Progress(message: "Downloading \(assetName)...", fraction: totalBytes > 0 ? 0 : nil, detail: nil))
        let downloaded = try await downloadAsset(from: update.asset.browserDownloadUrl, expectedBytes: totalBytes, into: work) { fraction in
            let received = Int64(Double(totalBytes) * fraction)
            let detail = totalBytes > 0
                ? "\(Int(fraction * 100))% · \(Self.byteText(received)) of \(Self.byteText(totalBytes))"
                : nil
            progress(Progress(message: "Downloading \(assetName)...", fraction: fraction, detail: detail))
        }
        let dmg = work.appendingPathComponent(assetName)
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        progress(Progress(message: "Verifying download...", fraction: nil, detail: nil))
        let digest = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == update.sha256 else {
            throw UpdateError.checksumMismatch
        }

        progress(Progress(message: "Preparing update...", fraction: nil, detail: nil))
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

        progress(Progress(message: "Installing and relaunching...", fraction: nil, detail: nil))
        try launchSwapHelper(staged: staged, workDir: work)
        handedOffToHelper = true
        NSApp.terminate(nil)
    }

    /// Streams one asset into `directory` and reports byte progress (0...1). `download(from:)` hides
    /// progress, so the transfer runs through a task with a delegate that counts bytes.
    private func downloadAsset(from url: URL, expectedBytes: Int64, into directory: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = AssetDownloadDelegate(expectedBytes: expectedBytes, destination: directory) { fraction in
            Task { @MainActor in
                onProgress(fraction)
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { result in
                switch result {
                case .success(let staged):
                    continuation.resume(returning: staged)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            session.downloadTask(with: url).resume()
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(bytes, 0))
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
        # Roll back only once the backup exists: if moving the installed app failed (cross-volume
        # copy), deleting "$target" would remove the only copy of the app.
        if mv "$target" "$backup"; then
          if /usr/bin/ditto "$staged" "$target"; then
            /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
            rm -rf "$backup"
          else
            rm -rf "$target"; mv "$backup" "$target"
          fi
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

/// Byte progress for one asset download. The temporary file handed to `didFinishDownloadingTo` is
/// only valid inside that callback, so it moves into the update's work directory right away.
private final class AssetDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var completion: ((Result<URL, Error>) -> Void)?

    private let expectedBytes: Int64
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var staged: URL?
    private var finished = false
    private var lastReported = Date.distantPast

    init(expectedBytes: Int64, destination: URL, onProgress: @escaping (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // GitHub serves a Content-Length; the release metadata covers a response that doesn't.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else {
            return
        }
        let fraction = min(Double(totalBytesWritten) / Double(total), 1)
        let now = Date()
        guard fraction >= 1 || now.timeIntervalSince(lastReported) >= 0.2 else {
            return
        }
        lastReported = now
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let target = destination.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            staged = target
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let staged {
                try? FileManager.default.removeItem(at: staged)
            }
            finish(.failure(AppUpdater.UpdateError.http(http.statusCode)))
            return
        }
        guard let staged else {
            finish(.failure(AppUpdater.UpdateError.command("The download finished without a file.")))
            return
        }
        finish(.success(staged))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else {
            return
        }
        finished = true
        completion?(result)
    }
}

/// Small floating window that shows installer progress (the menu can't stay open during a download).
/// The bar is determinate while bytes are arriving and reverts to the spinning bar for the phases
/// that have nothing to measure.
@MainActor
final class UpdateProgressWindow {
    private let window: NSPanel
    private let label: NSTextField
    private let detail: NSTextField
    private let indicator: NSProgressIndicator

    init(title: String) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        label = NSTextField(labelWithString: "Starting...")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.lineBreakMode = .byTruncatingTail
        indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.usesThreadedAnimation = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)
        let content = NSView()
        content.addSubview(label)
        content.addSubview(detail)
        content.addSubview(indicator)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            indicator.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            indicator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ message: String, fraction: Double?, detail detailText: String?) {
        label.stringValue = message
        detail.stringValue = detailText ?? ""
        if let fraction {
            if indicator.isIndeterminate {
                indicator.stopAnimation(nil)
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = 1
            }
            indicator.doubleValue = min(max(fraction, 0), 1)
        } else if !indicator.isIndeterminate {
            indicator.isIndeterminate = true
            indicator.doubleValue = 0
            indicator.startAnimation(nil)
        }
    }

    func close() {
        window.orderOut(nil)
    }
}
