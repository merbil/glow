import Foundation
import os

/// Diagnostic logging. Read it with:
///   log show --last 10m --predicate 'subsystem == "com.merterbil.glow"' --info --debug
/// The Hue key is never logged: v1 paths have it replaced with "<key>".
enum Log {
    static let bridge = Logger(subsystem: "com.merterbil.glow", category: "bridge")
    static let model = Logger(subsystem: "com.merterbil.glow", category: "model")

    /// "/api/<the real key>/groups/0" → "/api/<key>/groups/0"
    static func redact(_ path: String) -> String {
        guard path.hasPrefix("/api/") else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2, parts[2] != "0", !parts[2].isEmpty else { return path }
        var copy = parts.map(String.init)
        copy[2] = "<key>"
        return copy.joined(separator: "/")
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(code(error)): \(ns.localizedDescription)"
    }

    /// Error domain and code only, safe to log as public. The localized text can name the bridge's IP
    /// or carry text from the bridge, so log it separately as `.private`.
    static func code(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " | underlying \(underlying.domain) \(underlying.code)"
        }
        // Network path details (IPs, interfaces) are deliberately not logged.
        return text
    }
}
