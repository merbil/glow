import AppKit
import Observation

/// Tells you when a newer Glow is out. It asks GitHub for the latest release (one request, no
/// personal data), at most once a day. The user starts the update: `install()` downloads the DMG,
/// checks that the app inside is signed by the same certificate as this one (see `UpdateInstaller`),
/// swaps it in and relaunches. Where that can't work, Download opens the DMG in the browser.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let downloadURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(Release)
        case downloading, verifying, installing
        /// The in-place update went wrong; the browser download is offered instead.
        case installFailed
        /// Glow can't replace itself where it is now (checked before downloading anything).
        case needsManualDownload

        var progressText: String? {
            switch self {
            case .downloading: "Downloading…"
            case .verifying: "Checking the update…"
            case .installing: "Installing…"
            default: nil
            }
        }

        /// Shown above the Download button when the one-click update isn't happening.
        var notice: String? {
            switch self {
            case .installFailed: Updater.failureText
            case .needsManualDownload: Updater.fallbackText
            default: nil
            }
        }
    }

    nonisolated static let failureText = "Couldn't update automatically, but you can download it instead."
    nonisolated static let fallbackText = "Glow can't replace itself where it is now. Move Glow to the Applications folder in your home folder for one-click updates, or download it instead."

    private(set) var state = State.idle
    private(set) var isRunning = false
    /// The newest release found so far. Kept across relaunches, failed checks and running checks.
    private(set) var latest: Release?

    /// "Check for updates automatically" in Settings. Off: the timer never goes online (Check Now still works).
    var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: Self.autoKey)
            if automaticChecks { checkIfDue() }
        }
    }

    var available: Release? { latest }

    /// Downloading, checking or installing an update: nothing else may start.
    var isWorking: Bool { state.progressText != nil }

    /// The Update button (not the plain Download one) is offered: Glow can replace itself here
    /// and the last try didn't fail. While it works, the button stays and is disabled.
    var offersInstall: Bool {
        guard available != nil else { return false }
        if isWorking { return true }
        return state != .installFailed && state != .needsManualDownload && UpdateInstaller.canInstall(at: Bundle.main.bundleURL)
    }

    /// Why the Download button is shown instead of Update, if it is.
    var notice: String? {
        if let text = state.notice { return text }
        return available != nil && !offersInstall ? Self.fallbackText : nil
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Found by repository ID, not by name: a renamed or re-registered `merbil/glow` can't take over.
    static let repositoryID = 1425700868
    static let latestReleaseURL = URL(string: "https://api.github.com/repositories/\(repositoryID)/releases/latest")!
    static let autoKey = "autoUpdateCheck"
    nonisolated private static let interval: TimeInterval = 24 * 60 * 60
    /// Larger answers are refused; a release answer is a few KB.
    private static let maxAnswerBytes = 1_000_000
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticChecks = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        // Remembered from the last good check, checked again in case the user has updated since.
        latest = Self.persisted(in: defaults, newerThan: currentVersion)
        if let latest { state = .available(latest) }
        else if defaults.object(forKey: "lastUpdateCheck") != nil { state = .upToDate }
    }

    /// Only for the real app bundle: demo, snapshot and test runs never go online.
    func start() {
        guard !isRunning, Bundle.main.bundleURL.pathExtension == "app" else { return }
        isRunning = true
        // Whatever the last update left next to the app (the old copy) goes now that it has quit.
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        Task.detached(priority: .utility) { UpdateInstaller.removeLeftovers(in: folder) }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        // Not right at launch: give the bridge connection the first seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.checkIfDue() }
    }

    private func checkIfDue() {
        guard automaticChecks,
              Self.isDue(last: defaults.object(forKey: "lastUpdateCheck") as? Date, now: Date()) else { return }
        Task { await check() }
    }

    /// A last check in the future (a changed clock, or an edited setting) counts as due.
    nonisolated static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age > interval - 60
    }

    func check() async {
        guard isRunning, !isWorking, state != .checking else { return }
        state = .checking
        var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Glow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url?.host == Self.latestReleaseURL.host,
                  response.expectedContentLength <= Int64(Self.maxAnswerBytes) else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxAnswerBytes { throw URLError(.dataLengthExceedsMaximum) }
            }
            finish(with: data)
        } catch {
            Log.model.error("update check failed: \(Log.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            state = .failed
        }
    }

    /// What a good HTTP answer means. An answer Glow can't use (no DMG, a strange tag, a download
    /// outside Glow's releases) is a failed check, not "up to date": it's tried again within the hour.
    func finish(with data: Data) {
        guard let release = Self.parse(data) else {
            Log.model.error("update check: the answer has no usable release")
            state = .failed
            return
        }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        if Self.isNewer(release.version, than: currentVersion) {
            latest = release
            defaults.set(release.version, forKey: "latestReleaseVersion")
            defaults.set(release.downloadURL.absoluteString, forKey: "latestReleaseURL")
            state = .available(release)
        } else {
            latest = nil
            defaults.removeObject(forKey: "latestReleaseVersion")
            defaults.removeObject(forKey: "latestReleaseURL")
            state = .upToDate
        }
    }

    func download() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.downloadURL)
    }

    /// One-click update, started by the user. Every step before the swap leaves the installed app alone.
    func install() async {
        guard let release = available, !isWorking, state != .checking else { return }
        let bundleURL = Bundle.main.bundleURL
        guard UpdateInstaller.canInstall(at: bundleURL) else { state = .needsManualDownload; return }
        let (current, bundleID) = (currentVersion, Bundle.main.bundleIdentifier)
        var workFolder: URL?
        defer { if let workFolder { try? FileManager.default.removeItem(at: workFolder) } }
        do {
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: bundleURL, create: true)
            workFolder = work
            state = .downloading
            let dmg = work.appendingPathComponent("Glow.dmg")
            try await UpdateInstaller.download(release, currentVersion: current, to: dmg)
            state = .verifying
            let staged = try await Task.detached {
                try UpdateInstaller.stageAndVerify(dmg: dmg, workFolder: work, bundleURL: bundleURL,
                                                   bundleID: bundleID, version: release.version, currentVersion: current)
            }.value
            state = .installing
            try await Task.detached { try UpdateInstaller.replace(bundleURL: bundleURL, with: staged) }.value
            try UpdateInstaller.relaunch(app: bundleURL)
            NSApp.terminate(nil)
        } catch {
            Log.model.error("update install failed: \(Log.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            state = .installFailed
        }
    }

    // MARK: Parsing (pure, tested in the self-test)

    /// The release remembered by `finish(with:)`, if it still passes the checks and is newer than this version.
    nonisolated static func persisted(in defaults: UserDefaults, newerThan current: String) -> Release? {
        guard let version = defaults.string(forKey: "latestReleaseVersion"),
              let text = defaults.string(forKey: "latestReleaseURL"), let url = URL(string: text),
              isValidVersion(version), isAllowedDownload(url, version: version),
              isNewer(version, than: current) else { return nil }
        return Release(version: version, downloadURL: url)
    }

    /// The newest public release from GitHub's "latest release" answer, with its DMG.
    nonisolated static func parse(_ data: Data) -> Release? {
        struct Answer: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              answer.draft != true, answer.prerelease != true,
              let dmg = answer.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }
        let version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        guard isValidVersion(version), isAllowedDownload(dmg.browser_download_url, version: version) else { return nil }
        return Release(version: version, downloadURL: dmg.browser_download_url)
    }

    /// "0.3.4": one to four numbers made of ASCII digits, separated by dots, at most 32 characters.
    nonisolated static func isValidVersion(_ version: String) -> Bool {
        guard version.utf8.count <= 32 else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    }

    /// Only this version's DMG in Glow's own releases on GitHub, over HTTPS:
    /// `https://github.com/merbil/glow/releases/download/v<version>/<name>.dmg`, nothing else.
    nonisolated static func isAllowedDownload(_ url: URL, version: String) -> Bool {
        guard let parts = URLComponents(string: url.absoluteString), parts.scheme == "https", parts.host == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return false }
        // The path as written, not decoded: dot segments, encoded slashes and backslashes could point elsewhere.
        let path = parts.percentEncodedPath
        let lower = path.lowercased()
        guard !path.contains(".."), !path.contains("\\"), !lower.contains("%2e"), !lower.contains("%2f"),
              !lower.contains("%5c") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return segments.count == 7
            && Array(segments[0..<5]) == ["", "merbil", "glow", "releases", "download"]
            && segments[5] == "v" + version && segments[6].count > 4 && segments[6].hasSuffix(".dmg")
    }

    /// "0.3.10" is newer than "0.3.9".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }
}
