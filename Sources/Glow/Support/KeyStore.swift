import Foundation

/// Where Glow keeps the Hue app key: a private file (permissions 600, folder 700) in
/// ~/Library/Application Support/Glow.
///
/// Why not the Keychain: for apps without a paid Apple developer certificate, macOS ties a
/// Keychain "Always Allow" to one specific build, so every update asked for the login password
/// again. The key can only control lamps on the home network; a user-only file is the same
/// approach Home Assistant and most Hue tools use.
struct KeyStore {
    let directory: URL

    static let standard = KeyStore(directory: appSupport.appendingPathComponent("Glow", isDirectory: true))
    static let selfTest = KeyStore(directory: appSupport.appendingPathComponent("Glow-selftest", isDirectory: true))

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func file(_ account: String) -> URL { directory.appendingPathComponent(account) }

    func get(_ account: String) -> String? {
        if let data = try? Data(contentsOf: file(account)),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return migrateFromKeychain(account)
    }

    /// Writes the key into a file that is 600 from the moment it exists (no temp file with
    /// default permissions). Returns false, and logs, if it couldn't be saved.
    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            Log.model.error("key store: can't prepare folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let path = file(account).path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            Log.model.error("key store: can't open key file (errno \(errno))")
            return false
        }
        defer { close(fd) }
        fchmod(fd, 0o600)                 // in case the file already existed with other permissions
        let bytes = Array(value.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            Log.model.error("key store: short write (errno \(errno))")
            return false
        }
        fsync(fd)
        return true
    }

    func exists(_ account: String) -> Bool {
        FileManager.default.fileExists(atPath: file(account).path)
    }

    func delete(_ account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }

    /// One-time move from the Keychain used by earlier versions (0.1.x). This read may show
    /// one last Keychain prompt; once it succeeds (or there is nothing to move) it never runs again.
    private func migrateFromKeychain(_ account: String) -> String? {
        guard self.directory == KeyStore.standard.directory else { return nil }
        let flag = "keychainMigrationAttempted.\(account)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return nil }
        // Nothing in the Keychain: definitely done.
        guard Keychain.standard.exists(account) else {
            UserDefaults.standard.set(true, forKey: flag)
            return nil
        }
        // A failed read (locked Keychain at login, prompt dismissed) is retried on the next launch.
        guard let value = Keychain.standard.get(account), set(value, for: account) else { return nil }
        UserDefaults.standard.set(true, forKey: flag)
        return value
    }
}
