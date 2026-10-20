import Foundation
import Security

/// The steps of a one-click update, started by `Updater.install()`. Nothing here touches the installed
/// app until the new one has passed `verify`: it must be signed so that it satisfies this app's own
/// designated requirement (for Glow's releases that pins the "Glow Local Signing" certificate), carry
/// the same bundle ID, and be exactly the announced version, newer than the running one.
enum UpdateInstaller {
    enum InstallError: Error {
        case notAllowed, badAnswer, tooLarge, mountFailed, notADirectory
        case signatureInvalid, wrongIdentifier, wrongVersion, notNewer
        case replaceFailed, rollbackFailed
    }

    /// The new app, copied next to the installed one (same volume, so the swap is a rename).
    struct Staged {
        let folder: URL
        let app: URL
    }

    static let maxDownloadBytes: Int64 = 60 * 1024 * 1024
    static let stagingPrefix = ".Glow-update-"
    /// GitHub serves a release download from github.com, then redirects to one of these.
    static let allowedHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    // MARK: Checks (pure, tested in the self-test)

    /// Only https on GitHub's own download hosts, with no port or login.
    static func isAllowedHost(_ url: URL) -> Bool {
        guard let parts = URLComponents(string: url.absoluteString), parts.scheme == "https",
              parts.port == nil, parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    /// A size announced by the server (-1 when unknown) or counted while streaming is over the limit.
    static func exceedsCap(expected: Int64, received: Int64) -> Bool {
        expected > maxDownloadBytes || received > maxDownloadBytes
    }

    /// Not an app, run from the DMG or translocated by Gatekeeper: Glow can't replace itself there.
    static func pathBlocksInstall(_ path: String) -> Bool {
        !path.hasSuffix(".app") || path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// Glow can swap itself for a new copy: a real location, a writable folder, a bundle that can be moved.
    static func canInstall(at bundleURL: URL) -> Bool {
        guard !pathBlocksInstall(bundleURL.path) else { return false }
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && fileManager.isDeletableFile(atPath: bundleURL.path)
    }

    /// Only a real folder (not a link) named `.Glow-update-…` is something an update left behind.
    static func isLeftover(name: String, isDirectory: Bool, isSymlink: Bool) -> Bool {
        name.hasPrefix(stagingPrefix) && name.count > stagingPrefix.count && isDirectory && !isSymlink
    }

    /// Deletes what earlier updates left in `folder` (the one holding the app), nothing deeper.
    static func removeLeftovers(in folder: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if isLeftover(name: item.lastPathComponent, isDirectory: values?.isDirectory == true,
                          isSymlink: values?.isSymbolicLink == true) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    // MARK: Signature

    /// What a new Glow must satisfy: this running copy's designated requirement.
    static func runningRequirement() throws -> SecRequirement {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement
        else { throw InstallError.signatureInvalid }
        return requirement
    }

    /// The signature is intact in every part (all architectures, nested code) and meets `requirement`.
    static func checkSignature(of app: URL, requirement: SecRequirement) throws {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
        else { throw InstallError.signatureInvalid }
    }

    /// Signature, bundle ID, announced version, and "newer than what runs now".
    static func verify(app: URL, requirement: SecRequirement, bundleID: String?, version: String, currentVersion: String) throws {
        try checkSignature(of: app, requirement: requirement)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let bundleID, info?["CFBundleIdentifier"] as? String == bundleID else { throw InstallError.wrongIdentifier }
        guard Updater.isValidVersion(version), info?["CFBundleShortVersionString"] as? String == version else { throw InstallError.wrongVersion }
        guard Updater.isNewer(version, than: currentVersion) else { throw InstallError.notNewer }
    }

    // MARK: Steps

    /// Stops a redirect that leaves GitHub's download hosts before it is followed.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(UpdateInstaller.isAllowedHost) == true ? request : nil)
        }
    }

    /// Downloads the release's DMG to `file`: no cache, no cookies, at most `maxDownloadBytes`.
    static func download(_ release: Updater.Release, currentVersion: String, to file: URL) async throws {
        guard Updater.isAllowedDownload(release.downloadURL, version: release.version) else { throw InstallError.notAllowed }
        var request = URLRequest(url: release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Glow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
        guard (response as? HTTPURLResponse)?.statusCode == 200, let final = response.url, isAllowedHost(final)
        else { throw InstallError.badAnswer }
        guard !exceedsCap(expected: response.expectedContentLength, received: 0) else { throw InstallError.tooLarge }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw InstallError.badAnswer }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var chunk = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            received += 1
            if exceedsCap(expected: -1, received: received) { throw InstallError.tooLarge }
            if chunk.count >= 64 * 1024 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: chunk)
        guard received > 0 else { throw InstallError.badAnswer }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Mounts the DMG hidden and read-only inside `workFolder`, copies `Glow.app` next to the installed
    /// app, and detaches again. `Glow.app` must be a real folder, not a link to somewhere else.
    static func stage(dmg: URL, workFolder: URL, bundleURL: URL) throws -> Staged {
        let fileManager = FileManager.default
        let mountPoint = workFolder.appendingPathComponent("mnt")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path]) }
        guard try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                           "-mountpoint", mountPoint.path, dmg.path]) == 0 else { throw InstallError.mountFailed }
        let source = mountPoint.appendingPathComponent("Glow.app")
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw InstallError.notADirectory }
        let folder = bundleURL.deletingLastPathComponent().appendingPathComponent(stagingPrefix + UUID().uuidString)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let app = folder.appendingPathComponent("Glow.app")
        do {
            try fileManager.copyItem(at: source, to: app)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return Staged(folder: folder, app: app)
    }

    /// `stage`, then `verify` against the running app. A refused app is deleted again.
    static func stageAndVerify(dmg: URL, workFolder: URL, bundleURL: URL, bundleID: String?,
                               version: String, currentVersion: String) throws -> Staged {
        let requirement = try runningRequirement()
        let staged = try stage(dmg: dmg, workFolder: workFolder, bundleURL: bundleURL)
        do {
            try verify(app: staged.app, requirement: requirement, bundleID: bundleID, version: version, currentVersion: currentVersion)
        } catch {
            try? FileManager.default.removeItem(at: staged.folder)
            throw error
        }
        return staged
    }

    /// The old app moves into the staging folder, the new one takes its place. If the second move
    /// fails the old one goes back. Only when even that fails the staging folder is kept, as it holds the old app.
    static func replace(bundleURL: URL, with staged: Staged) throws {
        let old = staged.folder.appendingPathComponent("Glow-old.app")
        do {
            guard rename(bundleURL.path, old.path) == 0 else { throw InstallError.replaceFailed }
            guard rename(staged.app.path, bundleURL.path) == 0 else {
                guard rename(old.path, bundleURL.path) == 0 else { throw InstallError.rollbackFailed }
                throw InstallError.replaceFailed
            }
        } catch {
            if case InstallError.rollbackFailed = error {} else { try? FileManager.default.removeItem(at: staged.folder) }
            throw error
        }
    }

    /// Opens the app at `path` once this process has quit. The pid and path are arguments, not part of the script.
    /// `printVersionTo` (tests) runs the new binary with `--print-version` instead, with no UI.
    static func relaunch(app: URL, printVersionTo file: URL? = nil) throws {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let wait = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; "#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        if let file {
            process.arguments = ["-c", wait + #""$2/Contents/MacOS/Glow" --print-version "$3""#, "sh", pid, app.path, file.path]
        } else {
            process.arguments = ["-c", wait + #"/usr/bin/open "$2""#, "sh", pid, app.path]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    #if DEBUG
    /// `--install-update <dmg> <version>`: verify, stage and replace against the running bundle with a
    /// local DMG. No download, no UI, no preferences. The new app is run with `--print-version`, writing
    /// `printed-version.txt` next to this bundle. Exit: 0 replaced, 1 refused, 3 can't replace itself here.
    static func testInstall(dmg: URL, version: String) async -> Int32 {
        let bundleURL = Bundle.main.bundleURL
        guard canInstall(at: bundleURL) else { print("FALLBACK"); return 3 }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var workFolder: URL?
        defer { if let workFolder { try? FileManager.default.removeItem(at: workFolder) } }
        do {
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: bundleURL, create: true)
            workFolder = work
            let staged = try stageAndVerify(dmg: dmg, workFolder: work, bundleURL: bundleURL,
                                            bundleID: Bundle.main.bundleIdentifier, version: version, currentVersion: current)
            try replace(bundleURL: bundleURL, with: staged)
            try relaunch(app: bundleURL, printVersionTo: bundleURL.deletingLastPathComponent().appendingPathComponent("printed-version.txt"))
            print("REPLACED")
            return 0
        } catch {
            print("REFUSED \(Log.code(error)) \(error)")
            return 1
        }
    }
    #endif
}
