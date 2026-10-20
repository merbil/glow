import AppKit
import Observation

/// Tells you when a newer Glow is out. It asks GitHub for the latest release (one request, no
/// personal data), at most once a day. Installing stays manual: Download opens the new DMG in the
/// browser, so macOS checks it like any other download.
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
    }

    private(set) var state = State.idle
    private(set) var isRunning = false

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/merbil/glow/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60
    @ObservationIgnored private var timer: Timer?

    /// Only for the real app bundle: demo, snapshot and test runs never go online.
    func start() {
        guard !isRunning, Bundle.main.bundleURL.pathExtension == "app" else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        // Not right at launch: give the bridge connection the first seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.checkIfDue() }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.interval - 60 else { return }
        Task { await check() }
    }

    func check() async {
        guard isRunning, state != .checking else { return }
        state = .checking
        var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Glow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url?.host == Self.latestReleaseURL.host else { throw URLError(.badServerResponse) }
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            if let release = Self.parse(data), Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            Log.model.error("update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed
        }
    }

    func download() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.downloadURL)
    }

    // MARK: Parsing (pure, tested in the self-test)

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
              let dmg = answer.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              isAllowedDownload(dmg.browser_download_url) else { return nil }
        let version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Release(version: version, downloadURL: dmg.browser_download_url)
    }

    /// Only Glow's own release files on GitHub, over HTTPS.
    nonisolated static func isAllowedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/merbil/glow/releases/download/")
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
