import AppKit
import Foundation

/// `Glow --diagnose <bridge-ip>`: checks the connection pieces without needing the Hue key.
/// Run it through the app bundle so it has Glow's Local Network permission:
///   open -W -n /Applications/Glow.app --stdout /tmp/glow-diag.txt --args --diagnose 192.168.x.x
@MainActor
enum Diagnostics {
    static func run(host: String) async -> Int32 {
        var ok = true
        func line(_ text: String) { print(text); fflush(stdout) }

        line("Glow diagnostics for \(host)")
        let trust = BridgeTrust(host: host, pinnedFingerprint: nil)
        let client = HueClient(host: host, appKey: nil, trust: trust)

        // 1) Plain REST request (TLS through the session delegate).
        do {
            let config = try await client.fetchConfig()
            line("✓ REST: bridge \"\(config.name)\" id \(config.bridgeid)")
        } catch {
            ok = false
            line("✗ REST failed: \(Log.describe(error))")
        }
        line("  TLS check ran: \(trust.observedFingerprint != nil ? "yes, cert \(trust.observedFingerprint!.prefix(12))…" : "NO")")
        if let proven = trust.verifiedBridgeID {
            line("✓ genuine Philips Hue Bridge (certificate signed by the Hue root, issued to \(proven))")
        } else {
            ok = false
            line("✗ not verified as a genuine Hue Bridge (impostor, or a very old bridge firmware)")
        }

        // 2) Event stream. Without a key the bridge must answer 403; -1202 means TLS was rejected.
        let streamTrust = BridgeTrust(host: host, pinnedFingerprint: nil)
        let streamClient = HueClient(host: host, appKey: nil, trust: streamTrust)
        do {
            for try await _ in streamClient.events() { break }
            line("? stream: opened without a key (unexpected, but TLS works)")
        } catch HueError.unauthorized {
            line("✓ stream: TLS accepted, bridge answered 403 (expected without a key)")
        } catch {
            ok = false
            line("✗ stream failed: \(Log.describe(error))")
        }
        line("  TLS check ran for stream: \(streamTrust.observedFingerprint != nil ? "yes" : "NO")")

        // 3) Same certificate on both paths (pinning would otherwise fail).
        if let a = trust.observedFingerprint, let b = streamTrust.observedFingerprint {
            line(a == b ? "✓ same certificate on REST and stream" : "✗ different certificates: \(a.prefix(12))… vs \(b.prefix(12))…")
            if a != b { ok = false }
        }
        client.invalidate(); streamClient.invalidate()
        line(ok ? "RESULT: OK" : "RESULT: PROBLEMS FOUND")
        return ok ? 0 : 1
    }
}
