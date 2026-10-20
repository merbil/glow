import CryptoKit
import Foundation

/// The Hue bridge serves HTTPS with a certificate the system doesn't trust.
/// Glow trusts the bridge's certificate the first time it pairs, then pins it:
/// later connections must present the exact same certificate.
final class BridgeTrust: NSObject, URLSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _host: String?
    private var _pinnedFingerprint: String?
    private var _observedFingerprint: String?
    private var _pinMismatch = false
    private var _verifiedBridgeID: String?

    init(host: String?, pinnedFingerprint: String?) {
        _host = host
        _pinnedFingerprint = pinnedFingerprint
    }

    var host: String? {
        get { lock.withLock { _host } }
        set { lock.withLock { _host = newValue } }
    }

    var pinnedFingerprint: String? {
        get { lock.withLock { _pinnedFingerprint } }
        set { lock.withLock { _pinnedFingerprint = newValue } }
    }

    /// Fingerprint of the last certificate seen, so it can be pinned after pairing.
    var observedFingerprint: String? { lock.withLock { _observedFingerprint } }

    /// True once the bridge presented a certificate different from the pinned one.
    /// (Firmware updates can replace the certificate; the user then needs to pair again.)
    var pinMismatch: Bool { lock.withLock { _pinMismatch } }

    /// Set when the bridge's certificate is signed by Philips' Hue root: the bridge id it proves.
    /// Nil for impostors (and for very old bridges with self-signed certificates).
    var verifiedBridgeID: String? { lock.withLock { _verifiedBridgeID } }

    /// Host names compared without case, IPv6 brackets or a trailing dot.
    static func normalized(_ host: String) -> String {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Never follow redirects: the bridge doesn't use them, and a redirect would carry the
    /// hue-application-key header (and v1 keys in the path) to another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        Log.bridge.error("blocked a redirect from the bridge (HTTP \(response.statusCode))")
        completionHandler(nil)
    }

    /// Task-level challenges. `URLSession.bytes(for:)` (the event stream) delivers server-trust
    /// challenges here and NOT to the session-level method below; without this the stream fails
    /// with -1202 "certificate untrusted" while normal requests work.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Bridge sessions never use the system's trust: a challenge for any other host (or of any
        // other kind) is cancelled, so a certificate from a public CA can't stand in for the bridge.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let expected = host, Self.normalized(challenge.protectionSpace.host) == Self.normalized(expected),
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let data = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let genuine = HueRootCA.verifiedBridgeID(leaf: leaf)
        lock.withLock {
            _observedFingerprint = fingerprint
            _verifiedBridgeID = genuine
        }

        if let pinned = pinnedFingerprint, pinned != fingerprint {
            Log.bridge.error("TLS: certificate \(fingerprint.prefix(12), privacy: .public)… does not match pinned \(pinned.prefix(12), privacy: .public)… (chain length \(chain.count))")
            lock.withLock { _pinMismatch = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        Log.bridge.debug("TLS: accepted certificate \(fingerprint.prefix(12), privacy: .public)… (pinned: \(self.pinnedFingerprint != nil))")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
