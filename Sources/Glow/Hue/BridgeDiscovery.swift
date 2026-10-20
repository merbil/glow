import Foundation
import Network

struct DiscoveredBridge: Identifiable, Hashable {
    var id: String { host }
    let host: String
    /// The bridge id from the Bonjour TXT record, when there was one (not proof: only the certificate is).
    var bridgeID: String? = nil
}

/// Which addresses Glow will talk to. A bridge lives on the home network, so a public address,
/// a host with a port, or anything that could change the URL is never a bridge.
enum HostRules {
    /// A private or link-local IP literal: IPv4 10/8, 172.16/12, 192.168/16, 169.254/16, or IPv6 fe80::/10, fc00::/7.
    /// Nothing else is accepted: no ports, brackets, zones, leading zeros (some parsers read "010" as octal) or short forms.
    static func isPrivateAddress(_ host: String) -> Bool {
        guard host.utf8.count <= 45, host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 58) || ($0 >= 97 && $0 <= 102)
                                                            || ($0 >= 65 && $0 <= 70) || $0 == 46 }),
              !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.count > 1 && $0.hasPrefix("0") })
                  || host.contains(":") else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            return (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b[0] & 0xfe == 0xfc
        }
        return false
    }

    /// What the user types, or what is stored: a private IP literal, or a local-style name
    /// (one label, or ending in .local, .lan, .home, .home.arpa, .internal, .localdomain or .fritz.box).
    static func isValidHost(_ host: String) -> Bool {
        if isPrivateAddress(host) { return true }
        guard host.utf8.count <= 253, !host.isEmpty else { return false }
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let valid = labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
        }
        guard valid else { return false }
        if labels.count == 1 {
            // Must start with a letter: "2130706433" and "0x7f000001" are numeric ways to write an IP address.
            return labels[0].utf8.first.map { $0 >= 97 && $0 <= 122 } ?? false
        }
        return ["local", "lan", "home", "internal", "localdomain"].contains(String(labels.last!))
            || [".home.arpa", ".fritz.box"].contains { host.lowercased().hasSuffix($0) }
    }
}

/// Finds Hue Bridges on the local network.
/// Uses Bonjour (`_hue._tcp`) first, and Philips' discovery service as a fallback.
enum BridgeDiscovery {
    static func discover(timeout: TimeInterval = 5) async -> [DiscoveredBridge] {
        async let local = bonjour(timeout: timeout)
        async let cloud = philipsDiscovery()
        let found = await local + cloud.map { DiscoveredBridge(host: $0) }
        // Anything that isn't a private IP address is dropped silently.
        var seen = Set<String>()
        return found.filter { HostRules.isPrivateAddress($0.host) && seen.insert($0.host).inserted }
    }

    // MARK: Philips discovery service

    private struct CloudEntry: Decodable { let internalipaddress: String }

    private static func philipsDiscovery() async -> [String] {
        guard let url = URL(string: "https://discovery.meethue.com/") else { return [] }
        // Short timeout: without internet this must not hold up local discovery.
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Glow/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        // Ephemeral, like the update check: no cookies, no cache on disk, no CFNetwork user agent.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, _) = try? await session.data(for: request),
              let entries = try? JSONDecoder().decode([CloudEntry].self, from: data)
        else { return [] }
        return entries.map(\.internalipaddress)
    }

    // MARK: Bonjour

    private static func bonjour(timeout: TimeInterval) async -> [DiscoveredBridge] {
        let browser = NWBrowser(for: .bonjour(type: "_hue._tcp", domain: nil), using: .tcp)
        let results = await withCheckedContinuation { (cont: CheckedContinuation<[NWBrowser.Result], Never>) in
            let box = OnceBox(cont)
            browser.browseResultsChangedHandler = { results, _ in
                box.latest = Array(results)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { box.finish() }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.finish() }
        }
        browser.cancel()

        var bridges: [DiscoveredBridge] = []
        for result in results {
            guard let host = await resolve(result.endpoint) else { continue }
            var txtID: String?
            if case .bonjour(let txt) = result.metadata { txtID = txt["bridgeid"] }
            bridges.append(DiscoveredBridge(host: host, bridgeID: txtID))
        }
        return bridges
    }

    /// Turns a Bonjour service into an IPv4 address by briefly connecting to it.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        let host = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let box = OnceBox<String?>(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        box.latest = "\(host)".components(separatedBy: "%").first
                    }
                    box.finish()
                case .failed, .cancelled:
                    box.finish()
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { box.finish() }
        }
        connection.cancel()
        return host
    }
}

/// Resumes a continuation exactly once with the latest value it was given.
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var _latest: T

    init(_ continuation: CheckedContinuation<T, Never>) where T == [NWBrowser.Result] {
        self.continuation = continuation
        _latest = []
    }

    init(_ continuation: CheckedContinuation<T, Never>) where T == String? {
        self.continuation = continuation
        _latest = nil
    }

    var latest: T {
        get { lock.withLock { _latest } }
        set { lock.withLock { _latest = newValue } }
    }

    func finish() {
        let (cont, value) = lock.withLock { () -> (CheckedContinuation<T, Never>?, T) in
            defer { continuation = nil }
            return (continuation, _latest)
        }
        cont?.resume(returning: value)
    }
}
