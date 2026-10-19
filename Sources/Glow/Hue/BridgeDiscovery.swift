import Foundation
import Network

struct DiscoveredBridge: Identifiable, Hashable {
    var id: String { host }
    let host: String
}

/// Finds Hue Bridges on the local network.
/// Uses Bonjour (`_hue._tcp`) first, and Philips' discovery service as a fallback.
enum BridgeDiscovery {
    static func discover(timeout: TimeInterval = 5) async -> [DiscoveredBridge] {
        async let local = bonjour(timeout: timeout)
        async let cloud = philipsDiscovery()
        let hosts = await local + cloud
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }.map(DiscoveredBridge.init)
    }

    // MARK: Philips discovery service

    private struct CloudEntry: Decodable { let internalipaddress: String }

    private static func philipsDiscovery() async -> [String] {
        guard let url = URL(string: "https://discovery.meethue.com/") else { return [] }
        // Short timeout: without internet this must not hold up local discovery.
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let entries = try? JSONDecoder().decode([CloudEntry].self, from: data)
        else { return [] }
        return entries.map(\.internalipaddress)
    }

    // MARK: Bonjour

    private static func bonjour(timeout: TimeInterval) async -> [String] {
        let browser = NWBrowser(for: .bonjour(type: "_hue._tcp", domain: nil), using: .tcp)
        let endpoints = await withCheckedContinuation { (cont: CheckedContinuation<[NWEndpoint], Never>) in
            let box = OnceBox(cont)
            browser.browseResultsChangedHandler = { results, _ in
                box.latest = results.map(\.endpoint)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { box.finish() }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.finish() }
        }
        browser.cancel()

        var hosts: [String] = []
        for endpoint in endpoints {
            if let host = await resolve(endpoint) { hosts.append(host) }
        }
        return hosts
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

    init(_ continuation: CheckedContinuation<T, Never>) where T == [NWEndpoint] {
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
