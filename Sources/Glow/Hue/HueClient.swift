import Foundation

enum HueError: LocalizedError {
    case linkButtonNotPressed
    case badResponse(String)
    case unauthorized
    case certificateChanged
    case localNetworkDenied

    var errorDescription: String? {
        switch self {
        case .linkButtonNotPressed: "Press the round button on your Hue Bridge, then try again."
        case .badResponse(let detail): "The Hue Bridge sent an unexpected reply (\(detail))."
        case .unauthorized: "The Hue Bridge no longer accepts Glow's key. Please pair again."
        case .localNetworkDenied:
            "macOS is blocking Glow from your home network. Turn Glow on in System Settings → Privacy & Security → Local Network."
        case .certificateChanged:
            "Bridge certificate changed. Forget the bridge in Settings, then pair again."
        }
    }
}

/// Talks to one Hue Bridge on the local network.
/// v2 (CLIP) is used for lamps, rooms, commands and live events.
/// v1 is used only where v2 has no equivalent: pairing and one-shot timers.
final class HueClient: @unchecked Sendable {
    let host: String
    let appKey: String?
    let trust: BridgeTrust
    private let session: URLSession
    private let streamSession: URLSession
    // Creating a task on an invalidated URLSession raises an Objective-C exception (a crash that
    // `try` can't catch). So "invalidating" a client only marks it closed and cancels its work;
    // the sessions themselves are invalidated in deinit, when nothing can use them any more.
    private let stateLock = NSLock()
    private var closed = false

    /// `protocolClasses` lets tests swap the network for a fake bridge.
    /// `port` is only for tests against a local TLS server.
    let port: Int?

    init(host: String, appKey: String?, trust: BridgeTrust, protocolClasses: [AnyClass]? = nil, port: Int? = nil) {
        self.host = host
        self.port = port
        self.appKey = appKey
        self.trust = trust
        trust.host = host

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)

        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.timeoutIntervalForRequest = 15 * 60     // idle time before we reconnect
        streamConfig.timeoutIntervalForResource = .infinity
        if let protocolClasses { streamConfig.protocolClasses = protocolClasses }
        streamSession = URLSession(configuration: streamConfig, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    /// Closes the client: new requests fail with `URLError(.cancelled)` and running ones are cancelled.
    func invalidate() {
        stateLock.withLock { closed = true }
        session.getAllTasks { $0.forEach { $0.cancel() } }
        streamSession.getAllTasks { $0.forEach { $0.cancel() } }
    }

    /// Like `invalidate()`, but lets commands already in flight complete.
    func finishAndInvalidate() {
        stateLock.withLock { closed = true }
        streamSession.getAllTasks { $0.forEach { $0.cancel() } }
    }

    var isClosed: Bool { stateLock.withLock { closed } }

    private func ensureOpen() throws {
        if isClosed { throw URLError(.cancelled) }
    }

    /// All REST traffic goes through here.
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try ensureOpen()
        let label = "\(request.httpMethod ?? "GET") \(Log.redact(request.url?.path ?? ""))"
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count < 20_000_000 else { throw HueError.badResponse("oversized response") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Log.bridge.info("\(label, privacy: .public) → HTTP \(status) (\(data.count) bytes, \(Int(Date().timeIntervalSince(start) * 1000)) ms)")
            return (data, response)
        } catch {
            Log.bridge.error("\(label, privacy: .public) failed after \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(Log.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            throw Self.translate(error)
        }
    }

    /// macOS's Local Network privacy setting shows up as a generic "offline" error.
    /// Turn it into something the user can act on.
    static func translate(_ error: Error) -> Error {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let details = "\(ns.userInfo) \(underlying?.userInfo ?? [:])"
        return details.contains("Local network prohibited") ? HueError.localNetworkDenied : error
    }

    // MARK: Bridge info & pairing

    /// What the bridge lists Glow as. Deliberately not the computer name: it stays on the
    /// bridge and is visible to every app with access to it.
    private static let deviceType = "glow#mac"

    func fetchConfig() async throws -> BridgeConfig {
        let (data, _) = try await data(for: request("/api/0/config"))
        return try JSONDecoder().decode(BridgeConfig.self, from: data)
    }

    func pair() async throws -> PairingCredentials {
        let body: [String: Any] = ["devicetype": Self.deviceType, "generateclientkey": true]
        let data = try await send("/api", method: "POST", json: body, authenticated: false)

        guard let first = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first else {
            throw HueError.badResponse("pairing")
        }
        if let error = first["error"] as? [String: Any] {
            if error["type"] as? Int == 101 { throw HueError.linkButtonNotPressed }
            throw HueError.badResponse(error["description"] as? String ?? "pairing error")
        }
        guard let success = first["success"] as? [String: Any],
              let username = success["username"] as? String else {
            throw HueError.badResponse("pairing")
        }
        return PairingCredentials(username: username, clientkey: success["clientkey"] as? String)
    }

    // MARK: Reading state

    func fetchLights() async throws -> [HueLightResource] {
        try await get("/clip/v2/resource/light")
    }

    func fetchRooms() async throws -> [HueRoomResource] {
        try await get("/clip/v2/resource/room")
    }

    func fetchConnectivity() async throws -> [HueConnectivityResource] {
        try await get("/clip/v2/resource/zigbee_connectivity")
    }

    // MARK: Commands

    /// Changes one lamp. `brightness` is 0...100; Hue treats values below ~1 as its minimum.
    func setLight(id: String, on: Bool? = nil, brightness: Double? = nil,
                  xy: (x: Double, y: Double)? = nil, mirek: Int? = nil,
                  transitionMs: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let on { body["on"] = ["on": on] }
        if let brightness { body["dimming"] = ["brightness": max(1, min(100, brightness))] }
        if let xy { body["color"] = ["xy": ["x": xy.x, "y": xy.y]] }
        if let mirek { body["color_temperature"] = ["mirek": mirek] }
        if let transitionMs { body["dynamics"] = ["duration": transitionMs] }
        _ = try await send("/clip/v2/resource/light/\(id)", method: "PUT", json: body)
    }

    /// Turns every lamp on the bridge off, immediately (no fade).
    ///
    /// Uses the v2 "bridge_home" grouped light. The old v1 group 0 command with a fade
    /// (`transitiontime`) made lamps that were already off light up on some setups, and
    /// fading to 0 made lamps come back at 0% next time.
    func allOff() async throws {
        let id = try await homeGroupedLightID()
        _ = try await send("/clip/v2/resource/grouped_light/\(id)", method: "PUT", json: ["on": ["on": false]])
    }

    /// Switches every lamp in a room (its grouped light) on or off.
    func setGroupedLight(id: String, on: Bool) async throws {
        _ = try await send("/clip/v2/resource/grouped_light/\(id)", method: "PUT", json: ["on": ["on": on]])
    }

    /// The v1 equivalent, exactly what a bridge timer runs when it fires (used by the live test).
    func allOffV1() async throws {
        let data = try await send(v1Path("/groups/0/action"), method: "PUT", json: ["on": false])
        try checkV1(data)
    }

    /// What one of the per-target bridge timers runs when it fires (used by the live test).
    func offV1(address: String) async throws {
        let data = try await send(v1Path(address), method: "PUT", json: ["on": false])
        try checkV1(data)
    }

    private var cachedHomeGroup: String?

    /// The grouped light that covers every lamp on the bridge.
    func homeGroupedLightID() async throws -> String {
        if let cached = stateLock.withLock({ cachedHomeGroup }) { return cached }
        struct Home: Decodable { let services: [ResourceRef] }
        let homes: [Home] = try await get("/clip/v2/resource/bridge_home")
        guard let id = homes.first?.services.first(where: { $0.rtype == "grouped_light" })?.rid else {
            throw HueError.badResponse("no home group")
        }
        stateLock.withLock { cachedHomeGroup = id }
        return id
    }

    /// Creates a timer *on the bridge* so lamps go off even if the Mac sleeps.
    /// Returns the bridge's schedule id, used to cancel it.
    func scheduleAllOff(after seconds: Int) async throws -> String {
        try await scheduleOff(address: "/groups/0/action", after: seconds)
    }

    /// The same timer for a chosen set of v1 targets ("/groups/2/action", "/lights/3/state"),
    /// one bridge schedule each. If one fails, the ones already made are removed again.
    func scheduleOff(addresses: [String], after seconds: Int) async throws -> [String] {
        var ids: [String] = []
        do {
            for address in addresses { ids.append(try await scheduleOff(address: address, after: seconds)) }
            return ids
        } catch {
            for id in ids { try? await cancelSchedule(id: id) }
            throw error
        }
    }

    private func scheduleOff(address: String, after seconds: Int) async throws -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        let body: [String: Any] = [
            "name": "Glow all off",
            "description": "Created by Glow",
            "command": [
                "address": "/api/\(appKey ?? "")\(address)",
                "method": "PUT",
                "body": ["on": false],          // no fade: see allOff()
            ],
            "localtime": String(format: "PT%02d:%02d:%02d", h, m, s),
            "autodelete": true,
        ]
        let data = try await send(v1Path("/schedules"), method: "POST", json: body)
        try checkV1(data)
        guard let first = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
              let success = first["success"] as? [String: Any],
              let id = success["id"] as? String else {
            throw HueError.badResponse("timer")
        }
        return id
    }

    func cancelSchedule(id: String) async throws {
        let data = try await send(v1Path("/schedules/\(id)"), method: "DELETE")
        do { try checkV1(data) } catch HueError.badResponse where Self.v1ErrorType(data) == 3 {
            // Already gone (fired or deleted elsewhere): that's what we wanted.
        }
    }

    func scheduleExists(id: String) async throws -> Bool {
        let (data, response) = try await data(for: request(v1Path("/schedules/\(id)")))
        try check(response)
        // An existing schedule is an object; errors come back as an array.
        if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return true }
        if Self.v1ErrorType(data) == 3 { return false }      // resource not available
        try checkV1(data)
        throw HueError.badResponse("timer lookup")
    }

    // MARK: Live events

    /// Server-sent events from the bridge. Each element is one batch of events.
    func events() -> AsyncThrowingStream<[HueEvent], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request("/eventstream/clip/v2")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    try ensureOpen()
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    let start = Date()
                    // Pass the trust delegate per task too: bytes(for:) doesn't consult the session's.
                    do { (bytes, response) = try await streamSession.bytes(for: req, delegate: trust) }
                    catch {
                        Log.bridge.error("event stream: open failed: \(Log.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                        throw HueClient.translate(error)
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Log.bridge.info("event stream: opened, HTTP \(status)")
                    try check(response)
                    var lines = 0, batches = 0
                    defer {
                        Log.bridge.info("event stream: ended after \(Int(Date().timeIntervalSince(start)))s, \(lines) lines, \(batches) batches")
                    }
                    for try await line in bytes.lines {
                        lines += 1
                        // A bridge never sends anything near this; protects memory from a bad device.
                        guard line.utf8.count < 1_000_000 else { throw HueError.badResponse("oversized event") }
                        guard line.hasPrefix("data:") else { continue }
                        batches += 1
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        // Each event decodes on its own; one odd event doesn't drop the others.
                        if let batch = try? JSONDecoder().decode([Lossy<HueEvent>].self, from: Data(json.utf8)) {
                            continuation.yield(batch.compactMap(\.value))
                        }
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        Log.bridge.error("event stream: error: \(Log.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    /// v1 reports errors with HTTP 200 and a body like `[{"error":{"type":1,...}}]`.
    private func checkV1(_ data: Data) throws {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for item in items {
            guard let error = item["error"] as? [String: Any] else { continue }
            if error["type"] as? Int == 1 { throw HueError.unauthorized }
            throw HueError.badResponse(error["description"] as? String ?? "error")
        }
    }

    static func v1ErrorType(_ data: Data) -> Int? {
        let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return (items?.first?["error"] as? [String: Any])?["type"] as? Int
    }

    private func v1Path(_ path: String) -> String { "/api/\(appKey ?? "")\(path)" }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        // Hosts are validated before a client is created; fall back to an unroutable URL rather than crash.
        let url = URL(string: "https://\(host.contains(":") ? "[\(host)]" : host)\(port.map { ":\($0)" } ?? "")\(path)") ?? URL(string: "https://invalid.invalid/")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let appKey { req.setValue(appKey, forHTTPHeaderField: "hue-application-key") }
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> [T] {
        let (data, response) = try await data(for: request(path))
        try check(response)
        return try JSONDecoder().decode(HueResponse<T>.self, from: data).data
    }

    @discardableResult
    private func send(_ path: String, method: String, json: [String: Any]? = nil,
                      authenticated: Bool = true) async throws -> Data {
        var req = request(path, method: method)
        if !authenticated { req.setValue(nil, forHTTPHeaderField: "hue-application-key") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await data(for: req)
        try check(response)
        return data
    }

    func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 403 || http.statusCode == 401 { throw HueError.unauthorized }
        if http.statusCode >= 400 { throw HueError.badResponse("HTTP \(http.statusCode)") }
    }
}
