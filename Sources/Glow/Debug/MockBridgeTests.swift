#if DEBUG
import Foundation

/// A fake Hue Bridge served through URLProtocol, so the real HueClient and AppModel code
/// can be exercised without a bridge (smoke + regression tests).
final class MockBridge: URLProtocol {
    struct Call { let method: String; let path: String; let body: [String: Any]?; let key: String? }
    typealias Reply = (status: Int, body: String)

    nonisolated(unsafe) static var routes: [String: Reply] = [:]          // "METHOD /path" → reply
    nonisolated(unsafe) static var queued: [String: [Reply]] = [:]        // one-shot replies, used first
    nonisolated(unsafe) static var calls: [Call] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { routes = [:]; queued = [:]; calls = [] }
    }

    static func on(_ route: String, _ status: Int = 200, _ body: String) {
        lock.withLock { routes[route] = (status, body) }
    }

    static func once(_ route: String, _ status: Int = 200, _ body: String) {
        lock.withLock { queued[route, default: []].append((status, body)) }
    }

    static func calls(_ method: String, _ path: String) -> [Call] {
        lock.withLock { calls.filter { $0.method == method && $0.path == path } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = Self.readBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let key = request.value(forHTTPHeaderField: "hue-application-key")
        let route = "\(method) \(path)"

        let reply: Reply = Self.lock.withLock {
            Self.calls.append(Call(method: method, path: path, body: body, key: key))
            if var queue = Self.queued[route], !queue.isEmpty {
                let first = queue.removeFirst()
                Self.queued[route] = queue
                return first
            }
            return Self.routes[route] ?? (404, "{}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Answers every request with a redirect to another host, and records whether it was followed.
final class RedirectingProtocol: URLProtocol {
    nonisolated(unsafe) static var target = ""
    nonisolated(unsafe) static var followed = false
    override class func canInit(with request: URLRequest) -> Bool {
        if request.url?.host == "evil.example" { followed = true; return false }
        return request.url?.path == "/clip/v2/resource/zigbee_connectivity"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": Self.target])!
        var next = URLRequest(url: URL(string: Self.target)!)
        next.allHTTPHeaderFields = request.allHTTPHeaderFields
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

@MainActor
enum MockBridgeTests {
    private static func expect(_ c: Bool, _ m: String, line: Int = #line) { SelfTest.expect(c, m, line: line) }

    static let lightsJSON = """
    {"errors":[],"data":[
     {"id":"c1","type":"light","owner":{"rid":"d1","rtype":"device"},"metadata":{"name":"Corner"},
      "on":{"on":true},"dimming":{"brightness":40.0},
      "color_temperature":{"mirek":null,"mirek_valid":false,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}},
      "color":{"xy":{"x":0.22,"y":0.12}},"mode":"normal"},
     {"id":"a1","type":"light","owner":{"rid":"d2","rtype":"device"},"metadata":{"name":"Floor"},
      "on":{"on":false},"dimming":{"brightness":70.0},
      "color_temperature":{"mirek":370,"mirek_valid":true,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":454}},
      "mode":"normal"},
     {"id":"p1","type":"light","owner":{"rid":"d3","rtype":"device"},"metadata":{"name":"Plug"},
      "on":{"on":true},"mode":"normal"}
    ]}
    """
    static let roomsJSON = """
    {"errors":[],"data":[{"id":"r1","type":"room","metadata":{"name":"Living Room"},
      "children":[{"rid":"d1","rtype":"device"},{"rid":"d2","rtype":"device"}],
      "services":[{"rid":"gr1","rtype":"grouped_light"}]}]}
    """
    static let connectivityJSON = """
    {"errors":[],"data":[{"id":"z1","type":"zigbee_connectivity","owner":{"rid":"d1","rtype":"device"},"status":"connected"},
     {"id":"z2","type":"zigbee_connectivity","owner":{"rid":"d2","rtype":"device"},"status":"connected"},
     {"id":"z3","type":"zigbee_connectivity","owner":{"rid":"d3","rtype":"device"},"status":"connected"}]}
    """

    private static func makeClient(key: String? = "KEY") -> HueClient {
        HueClient(host: "10.0.0.2", appKey: key, trust: BridgeTrust(host: "10.0.0.2", pinnedFingerprint: nil),
                  protocolClasses: [MockBridge.self])
    }

    private static func serveHome() {
        MockBridge.on("GET /clip/v2/resource/light", 200, lightsJSON)
        MockBridge.on("GET /clip/v2/resource/room", 200, roomsJSON)
        MockBridge.on("GET /clip/v2/resource/zigbee_connectivity", 200, connectivityJSON)
        MockBridge.on("PUT /clip/v2/resource/light/c1", 200, #"{"data":[{"rid":"c1","rtype":"light"}],"errors":[]}"#)
        MockBridge.on("PUT /clip/v2/resource/light/a1", 200, #"{"data":[{"rid":"a1","rtype":"light"}],"errors":[]}"#)
        MockBridge.on("PUT /clip/v2/resource/light/p1", 200, #"{"data":[{"rid":"p1","rtype":"light"}],"errors":[]}"#)
        MockBridge.on("PUT /api/KEY/groups/0/action", 200, #"[{"success":{"/groups/0/action/on":false}}]"#)
        MockBridge.on("GET /clip/v2/resource/bridge_home", 200,
                      #"{"errors":[],"data":[{"id":"h1","type":"bridge_home","children":[],"services":[{"rid":"g0","rtype":"grouped_light"}]}]}"#)
        MockBridge.on("PUT /clip/v2/resource/grouped_light/g0", 200, #"{"errors":[],"data":[{"rid":"g0","rtype":"grouped_light"}]}"#)
    }

    private static func decodeEvents(_ json: String, line: Int = #line) -> [HueEvent] {
        do { return try JSONDecoder().decode([HueEvent].self, from: Data(json.utf8)) }
        catch { expect(false, "event batch failed to decode: \(error)", line: line); return [] }
    }

    /// Lets queued Tasks (fire-and-forget sends) run.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func run() async {
        await clientTests()
        await modelTests()
    }

    // MARK: HueClient against the fake bridge

    private static func clientTests() async {
        MockBridge.reset()
        let client = makeClient(key: nil)

        // Pairing: "press the button" first, then success.
        MockBridge.once("POST /api", 200, #"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#)
        MockBridge.once("POST /api", 200, #"[{"success":{"username":"NEWKEY","clientkey":"CK"}}]"#)
        do {
            _ = try await client.pair()
            expect(false, "pair should throw linkButtonNotPressed first")
        } catch HueError.linkButtonNotPressed {
            expect(true, "")
        } catch { expect(false, "unexpected pair error \(error)") }
        let creds = try? await client.pair()
        expect(creds?.username == "NEWKEY" && creds?.clientkey == "CK", "pairing returns the key")
        let pairBody = MockBridge.calls("POST", "/api").last?.body
        expect((pairBody?["devicetype"] as? String)?.hasPrefix("glow#") == true, "devicetype glow#…")
        expect(((pairBody?["devicetype"] as? String)?.count ?? 99) <= 40, "devicetype ≤ 40 chars")
        expect(MockBridge.calls("POST", "/api").last?.key == nil, "pairing sends no app key")

        // Reading + commands with a key.
        MockBridge.reset()
        serveHome()
        let keyed = makeClient()
        let lights = (try? await keyed.fetchLights()) ?? []
        expect(lights.count == 3, "fetchLights decodes 3 lights")
        try? await keyed.setLight(id: "c1", on: true, brightness: 140, xy: (0.3, 0.3), transitionMs: 100)
        let put = MockBridge.calls("PUT", "/clip/v2/resource/light/c1").last
        expect(put?.key == "KEY", "v2 commands send hue-application-key")
        expect((put?.body?["on"] as? [String: Any])?["on"] as? Bool == true, "on body")
        expect((put?.body?["dimming"] as? [String: Any])?["brightness"] as? Double == 100, "brightness clamped to 100")
        expect(((put?.body?["color"] as? [String: Any])?["xy"] as? [String: Any])?["x"] as? Double == 0.3, "xy body")
        expect((put?.body?["dynamics"] as? [String: Any])?["duration"] as? Int == 100, "transition body")

        // All off: v2 home group, plain "off", no fade.
        try? await keyed.allOff()
        let off = MockBridge.calls("PUT", "/clip/v2/resource/grouped_light/g0").last?.body
        expect((off?["on"] as? [String: Any])?["on"] as? Bool == false, "all off → home grouped_light on:false")
        expect(off?["dynamics"] == nil, "all off has no fade")

        // v1 errors arrive with HTTP 200 (review M1).
        MockBridge.on("PUT /api/KEY/groups/0/action", 200, #"[{"error":{"type":1,"description":"unauthorized user"}}]"#)
        do { try await keyed.allOffV1(); expect(false, "v1 group command should detect v1 unauthorized") }
        catch HueError.unauthorized { expect(true, "") }
        catch { expect(false, "allOff wrong error \(error)") }

        // Timer on the bridge.
        MockBridge.on("POST /api/KEY/schedules", 200, #"[{"success":{"id":"7"}}]"#)
        let timerID = try? await keyed.scheduleAllOff(after: 5 * 60)
        expect(timerID == "7", "timer id returned")
        let schedule = MockBridge.calls("POST", "/api/KEY/schedules").last?.body
        expect(schedule?["localtime"] as? String == "PT00:05:00", "timer format PT00:05:00")
        expect(schedule?["autodelete"] as? Bool == true, "timer autodeletes")
        let command = schedule?["command"] as? [String: Any]
        expect(command?["address"] as? String == "/api/KEY/groups/0/action", "timer targets all lights")
        expect(((command?["body"] as? [String: Any])?["on"] as? Bool) == false, "timer turns off")
        expect((command?["body"] as? [String: Any])?["transitiontime"] == nil, "timer has no fade")
        _ = try? await keyed.scheduleAllOff(after: 3600)
        expect(MockBridge.calls("POST", "/api/KEY/schedules").last?.body?["localtime"] as? String == "PT01:00:00",
               "1 hour timer format")

        MockBridge.on("GET /api/KEY/schedules/7", 200, #"{"name":"Glow all off","localtime":"PT00:05:00"}"#)
        expect((try? await keyed.scheduleExists(id: "7")) == true, "existing timer found")
        MockBridge.on("GET /api/KEY/schedules/7", 200, #"[{"error":{"type":3,"description":"resource not available"}}]"#)
        expect((try? await keyed.scheduleExists(id: "7")) == false, "missing timer reported as gone")
        MockBridge.on("GET /api/KEY/schedules/7", 200, #"[{"error":{"type":1,"description":"unauthorized user"}}]"#)
        do { _ = try await keyed.scheduleExists(id: "7"); expect(false, "unauthorized lookup must throw, not say 'gone'") }
        catch HueError.unauthorized { expect(true, "") }
        catch { expect(false, "lookup wrong error \(error)") }
        MockBridge.on("DELETE /api/KEY/schedules/7", 200, #"[{"error":{"type":3,"description":"resource not available"}}]"#)
        do { try await keyed.cancelSchedule(id: "7"); expect(true, "") }
        catch { expect(false, "cancelling an already-fired timer must not fail: \(error)") }

        // Redirects are never followed (they'd carry the key elsewhere).
        MockBridge.on("GET /clip/v2/resource/zigbee_connectivity", 302, "")
        RedirectingProtocol.target = "https://evil.example/steal"
        let redirecting = HueClient(host: "10.0.0.2", appKey: "KEY", trust: BridgeTrust(host: "10.0.0.2", pinnedFingerprint: nil),
                                    protocolClasses: [RedirectingProtocol.self, MockBridge.self])
        _ = try? await redirecting.fetchConnectivity()
        expect(!RedirectingProtocol.followed, "redirect to another host is blocked")
        redirecting.invalidate()

        // Invalid bridge addresses are rejected instead of crashing.
        for bad in ["192.168 .1.1", "a\"b", "%zz", "evil.com/@x", "1.2.3.4#", "",
                    "evil.com:443", "192.168.1.20:443", "user@192.168.1.20", "192.168.1.20/x", "[fe80::1]", "8.8.8.8",
                    "172.32.0.1", "evil.com", "a.b.c.example", "2130706433", "0x7f000001", "10.1", "010.0.0.1",
                    "::1", "2001:db8::1", "::ffff:10.0.0.1", "fe80::1%en0", "hue.local.", "-a.local", "a..local"] {
            expect(!AppModel.isValidHost(bad), "rejects bad address \(bad)")
        }
        for good in ["192.168.1.20", "10.0.0.2", "172.16.0.1", "172.31.255.254", "169.254.1.1", "hue-bridge.local", "Hue.LOCAL",
                     "bridge", "bridge.lan", "x.home", "x.home.arpa", "x.internal", "hue.fritz.box", "hue.localdomain", "fe80::1", "fd12:3456::1", "fc00::1"] {
            expect(AppModel.isValidHost(good), "accepts \(good)")
        }
        // Discovered hosts are stricter: private or link-local IP literals only, never names.
        for found in ["192.168.1.20", "10.1.2.3", "172.20.0.1", "169.254.9.9", "fe80::1", "fdab::1"] {
            expect(HostRules.isPrivateAddress(found), "discovery accepts \(found)")
        }
        for dropped in ["hue.local", "bridge", "1.2.3.4", "evil.com", "evil.com:443", "192.168.1.20:443", "[fe80::1]", "172.15.0.1", "192.169.0.1"] {
            expect(!HostRules.isPrivateAddress(dropped), "discovery drops \(dropped)")
        }
        // IPv6 literals are bracketed in the URL.
        let v6 = HueClient(host: "fe80::1", appKey: nil, trust: BridgeTrust(host: "fe80::1", pinnedFingerprint: nil),
                           protocolClasses: [MockBridge.self])
        _ = try? await v6.fetchConfig()
        expect(MockBridge.calls.last?.path == "/api/0/config", "IPv6 host builds a working URL")
        v6.invalidate()
        // Host names compare without case, brackets or a trailing dot.
        expect(BridgeTrust.normalized("[FE80::1]") == "fe80::1" && BridgeTrust.normalized("Hue.Local.") == "hue.local",
               "host comparison normalizes case, brackets and trailing dot")
        // A stored host that isn't valid reads as "not paired".
        let tampered = Preferences.scratch()
        tampered.bridgeHost = "evil.com:443"
        expect(tampered.bridgeHost == nil, "stored host with a port is ignored")
        tampered.bridgeHost = "192.168.1.20"
        expect(tampered.bridgeHost == "192.168.1.20", "stored private address is kept")
        // The bridge timer id goes into a URL: digits only.
        for bad in ["../lights/3", "", "1/2", "٣", "1 2", "7?x"] {
            tampered.pendingTimer = (bad, Date().addingTimeInterval(60))
            expect(tampered.pendingTimer == nil, "timer id \(bad.debugDescription) is ignored")
        }
        tampered.pendingTimer = ("12", Date().addingTimeInterval(60))
        expect(tampered.pendingTimer?.id == "12", "numeric timer id is kept")
        // Names can't carry invisible formatting tricks.
        expect(cleanName("Kitchen\u{202E}nehctik") == "Kitchennehctik", "bidi override stripped")
        expect(cleanName(String(repeating: "x", count: 500)).count == 64, "names capped")

        // HTTP 403 on v2 means the key was revoked.
        MockBridge.on("GET /clip/v2/resource/room", 403, #"{"errors":[{"description":"unauthorized user"}]}"#)
        do { _ = try await keyed.fetchRooms(); expect(false, "403 should throw") }
        catch HueError.unauthorized { expect(true, "") }
        catch { expect(false, "403 wrong error \(error)") }

        // Event stream: keep-alive comments, and a scene item whose `status` is an object (review H1).
        MockBridge.on("GET /eventstream/clip/v2", 200, """
        : hi

        id: 1:0
        data: [{"creationtime":"2026-10-19T10:00:00Z","data":[{"id":"s1","type":"scene","status":{"active":"static"}},{"id":"c1","type":"light","on":{"on":false}}],"id":"e1","type":"update"}]

        """)
        var batches: [[HueEvent]] = []
        do { for try await batch in keyed.events() { batches.append(batch) } }
        catch { expect(false, "event stream threw \(error)") }
        let items = batches.flatMap { $0.flatMap(\.data) }
        expect(items.contains { $0.id == "c1" && $0.on?.on == false },
               "light update survives a scene item with an object status")
        keyed.invalidate()
    }

    // MARK: The real reconnect loop

    private static func eventLoopTests() async {
        // 1) Bridge unreachable (HTTP 500 everywhere): failures count up and rediscovery runs every 3rd.
        await settle(); MockBridge.reset()
        MockBridge.on("GET /clip/v2/resource/light", 500, "{}")
        MockBridge.on("GET /clip/v2/resource/room", 500, "{}")
        MockBridge.on("GET /clip/v2/resource/zigbee_connectivity", 500, "{}")
        let prefs = Preferences.scratch()
        prefs.bridgeID = "001788fffe000000"
        KeyStore.selfTest.set("KEY", for: "appKey")
        let model = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        var searches = 0
        model.discover = { searches += 1; return [] }
        model.requireGenuineBridge = false          // the mock has no certificate (and no stored pin to skip the check)
        model.retryDelay = { _ in .milliseconds(20) }
        model.useForTesting(makeClient())
        let loop = Task { await model.runEventLoop() }
        try? await Task.sleep(for: .milliseconds(600))
        expect(model.consecutiveFailures >= 6, "unreachable bridge counts failures: \(model.consecutiveFailures)")
        expect(searches == 1, "rediscovery runs after 3 failures, then at most once per 15 minutes (searched \(searches)×)")
        if case .offline = model.connection { expect(true, "") } else { expect(false, "shows offline: \(model.connection)") }
        loop.cancel()
        await settle()

        // 1b) Still unreachable after the retry window: Glow stops, and Refresh starts a new round.
        let quitter = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        quitter.discover = { [] }
        quitter.requireGenuineBridge = false
        quitter.retryDelay = { _ in .milliseconds(20) }
        quitter.retryWindow = 0.15
        quitter.testProtocolClasses = [MockBridge.self]   // Refresh builds a fresh client; keep it on the mock
        quitter.useForTesting(makeClient())
        let quitLoop = Task { await quitter.runEventLoop() }
        try? await Task.sleep(for: .milliseconds(500))
        expect(quitter.retriesStopped, "stops retrying after the retry window")
        let stoppedAt = quitter.consecutiveFailures
        try? await Task.sleep(for: .milliseconds(200))
        expect(quitter.consecutiveFailures == stoppedAt, "no more attempts once stopped (\(stoppedAt) → \(quitter.consecutiveFailures))")
        if case .offline = quitter.connection { expect(true, "") } else { expect(false, "still shows offline when stopped") }
        quitter.retryNow()
        try? await Task.sleep(for: .milliseconds(60))
        expect(!quitter.retriesStopped, "Refresh starts a new round")
        try? await Task.sleep(for: .milliseconds(500))
        expect(quitter.retriesStopped, "…which also stops after the window")
        quitLoop.cancel()
        quitter.forgetBridge()
        expect(quitter.lastContact == nil && prefs.lastBridgeContact == nil, "forgetting the bridge clears last seen")
        prefs.bridgeID = "001788fffe000000"
        KeyStore.selfTest.set("KEY", for: "appKey")
        await settle()

        // 2) Refresh works but the stream closes at once: that's a failure too, not a quiet reconnect.
        MockBridge.reset(); serveHome()
        MockBridge.on("GET /eventstream/clip/v2", 200, "")
        let model2 = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        model2.discover = { [] }
        model2.requireGenuineBridge = false
        model2.retryDelay = { _ in .milliseconds(20) }
        model2.useForTesting(makeClient())
        let loop2 = Task { await model2.runEventLoop() }
        try? await Task.sleep(for: .milliseconds(400))
        expect(model2.consecutiveFailures >= 2, "stream that closes immediately counts as failing: \(model2.consecutiveFailures)")
        expect(model2.lamps.count == 3, "lamps still loaded meanwhile")
        expect(model2.lastContact != nil && prefs.lastBridgeContact != nil, "a good refresh is saved as last seen")
        loop2.cancel()

        // 2b) Rediscovery only accepts a bridge whose certificate proves its id, not one that merely says so in JSON.
        await settle(); MockBridge.reset()
        MockBridge.on("GET /clip/v2/resource/light", 500, "{}")
        MockBridge.on("GET /clip/v2/resource/room", 500, "{}")
        MockBridge.on("GET /clip/v2/resource/zigbee_connectivity", 500, "{}")
        MockBridge.on("GET /api/0/config", 200, #"{"name":"Fake","bridgeid":"001788FFFE000000"}"#)
        let moved = Preferences.scratch()
        moved.bridgeID = "001788fffe000000"
        moved.bridgeHost = "10.0.0.2"
        moved.certificateFingerprint = String(repeating: "ab", count: 32)
        KeyStore.selfTest.set("KEY", for: "appKey")
        var asked = 0
        func rediscoveryRun(genuine: Bool, found: [DiscoveredBridge]) async -> String? {
            moved.bridgeHost = "10.0.0.2"
            let m = AppModel(demo: false, preferences: moved, keyStore: .selfTest)
            m.testProtocolClasses = [MockBridge.self]
            m.requireGenuineBridge = genuine
            m.discover = { asked += 1; return found }
            m.retryDelay = { _ in .milliseconds(20) }
            m.useForTesting(makeClient())
            let task = Task { await m.runEventLoop() }
            try? await Task.sleep(for: .milliseconds(300))
            task.cancel()
            await settle()
            return moved.bridgeHost
        }
        let forged = await rediscoveryRun(genuine: true, found: [DiscoveredBridge(host: "10.0.0.9")])
        expect(asked == 1 && forged == "10.0.0.2", "a forged JSON bridge id doesn't move the bridge (host \(forged ?? "nil"))")
        let other = await rediscoveryRun(genuine: false, found: [DiscoveredBridge(host: "10.0.0.9", bridgeID: "001788FFFE111111")])
        expect(other == "10.0.0.2", "a Bonjour bridge advertising another id is skipped")
        let publicHost = await rediscoveryRun(genuine: false, found: [DiscoveredBridge(host: "8.8.8.8")])
        expect(publicHost == "10.0.0.2", "a public address is never probed")
        let moved1 = await rediscoveryRun(genuine: false, found: [DiscoveredBridge(host: "10.0.0.9", bridgeID: "001788fffe000000")])
        expect(moved1 == "10.0.0.9", "a matching bridge is followed (mock without TLS)")
        KeyStore.selfTest.delete("appKey")

        // 3) Revoked key during the loop: it stops and returns to onboarding.
        await settle(); MockBridge.reset()
        MockBridge.on("GET /clip/v2/resource/light", 403, "{}")
        MockBridge.on("GET /clip/v2/resource/room", 403, "{}")
        MockBridge.on("GET /clip/v2/resource/zigbee_connectivity", 403, "{}")
        let model3 = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        model3.requireGenuineBridge = false
        model3.useForTesting(makeClient())
        let loop3 = Task { await model3.runEventLoop() }
        try? await Task.sleep(for: .milliseconds(300))
        expect(!model3.isPaired, "loop stops on a revoked key")
        loop3.cancel()
        KeyStore.selfTest.delete("appKey")
        await settle()
    }

    // MARK: Shutting clients down (round-3 crash) and timer edge cases

    private static func shutdownTests() async {
        // A closed client fails politely instead of crashing.
        await settle(); MockBridge.reset(); serveHome()
        let closed = makeClient()
        closed.invalidate()
        do { _ = try await closed.fetchLights(); expect(false, "closed client should throw") }
        catch let error as URLError where error.code == .cancelled { expect(true, "") }
        catch { expect(false, "closed client wrong error \(error)") }
        var streamFailed = false
        do { for try await _ in closed.events() {} } catch { streamFailed = true }
        expect(streamFailed, "closed client's event stream fails instead of crashing")

        // Forget the bridge with a timer pending: no crash, and the timer is deleted from the bridge.
        let prefs = Preferences.scratch()
        let model = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        model.discover = { [] }
        model.useForTesting(makeClient())
        await model.refresh()
        MockBridge.on("POST /api/KEY/schedules", 200, #"[{"success":{"id":"11"}}]"#)
        MockBridge.on("DELETE /api/KEY/schedules/11", 200, #"[{"success":"/schedules/11 deleted"}]"#)
        model.scheduleAllOff(minutes: 30)
        await settle()
        expect(model.timerFireDate != nil, "timer running before forgetting")
        model.forgetBridge()
        await settle()
        expect(!MockBridge.calls("DELETE", "/api/KEY/schedules/11").isEmpty, "forgetting removes the bridge timer")
        expect(!model.isPaired && model.timerFireDate == nil && prefs.pendingTimer == nil, "forget clears everything")

        // Forget while the timer is still being created: no crash, no countdown.
        let model2 = AppModel(demo: false, preferences: .scratch(), keyStore: .selfTest)
        model2.discover = { [] }
        model2.useForTesting(makeClient())
        model2.scheduleAllOff(minutes: 5)
        model2.forgetBridge()
        await settle()
        expect(model2.timerFireDate == nil, "no countdown after forgetting mid-request")

        // Changing the timer fails on the bridge: the stale countdown disappears.
        await settle(); MockBridge.reset(); serveHome()
        let model3 = AppModel(demo: false, preferences: .scratch(), keyStore: .selfTest)
        model3.useForTesting(makeClient())
        MockBridge.on("POST /api/KEY/schedules", 200, #"[{"success":{"id":"21"}}]"#)
        model3.scheduleAllOff(minutes: 5)
        await settle()
        MockBridge.on("DELETE /api/KEY/schedules/21", 200, #"[{"success":"/schedules/21 deleted"}]"#)
        MockBridge.on("POST /api/KEY/schedules", 500, "{}")
        model3.scheduleAllOff(minutes: 60)
        await settle()
        expect(model3.timerFireDate == nil, "failed re-schedule doesn't leave a countdown that won't fire")
        expect(model3.notice != nil, "and says so")
    }

    // MARK: Pairing with an existing key

    private static func existingKeyTests() async {
        await settle(); MockBridge.reset(); serveHome()
        MockBridge.on("GET /api/0/config", 200, #"{"name":"Hue Bridge","bridgeid":"001788FFFE000000"}"#)
        MockBridge.on("GET /eventstream/clip/v2", 200, "")

        // Wrong key: the bridge answers 403, nothing is saved.
        MockBridge.on("GET /clip/v2/resource/light", 403, "{}")
        let prefs = Preferences.scratch()
        KeyStore.selfTest.delete("appKey")
        let model = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        model.testProtocolClasses = [MockBridge.self]

        // The fake bridge has no TLS certificate, so it can never prove it's genuine:
        // the key must not be sent. (The certificate check itself is covered by --pentest.)
        MockBridge.on("GET /clip/v2/resource/light", 200, lightsJSON)
        model.useExistingKey(host: "10.0.0.2", key: "KEY")
        try? await Task.sleep(for: .milliseconds(300))
        expect(MockBridge.calls("GET", "/clip/v2/resource/light").isEmpty, "key is NOT sent to a bridge that isn't proven genuine")
        // Friend's finding: the very first request must not carry the key either.
        let firstContact = MockBridge.calls("GET", "/api/0/config")
        expect(!firstContact.isEmpty && firstContact.allSatisfy { $0.key == nil }, "first contact carries no key")
        expect(MockBridge.calls.allSatisfy { $0.key != "KEY" }, "the pasted key went nowhere at all")
        if case .failed(let m) = model.onboarding { expect(m.contains("genuine"), "explains why: \(m)") }
        else { expect(false, "unverified bridge → failed state") }

        // Button pairing stops at an unverified bridge too (no key requested from it).
        MockBridge.on("POST /api", 200, #"[{"success":{"username":"LEAKED"}}]"#)
        model.pair(with: "10.0.0.2")
        try? await Task.sleep(for: .milliseconds(300))
        expect(MockBridge.calls("POST", "/api").isEmpty, "button pairing doesn't ask an unverified bridge for a key")
        if case .failed(let m) = model.onboarding { expect(m.contains("genuine"), "button pairing explains why") }
        else { expect(false, "unverified bridge → button pairing fails: \(model.onboarding)") }
        model.requireGenuineBridge = false
        MockBridge.on("GET /clip/v2/resource/light", 403, "{}")     // back to "this key is wrong"
        model.discover = { [] }
        model.retryDelay = { _ in .seconds(60) }
        model.useExistingKey(host: "10.0.0.2", key: "WRONG")
        try? await Task.sleep(for: .milliseconds(300))
        if case .failed(let message) = model.onboarding {
            expect(message.contains("doesn't accept"), "wrong key explained: \(message)")
        } else { expect(false, "wrong key → failed state, got \(model.onboarding)") }
        expect(!model.isPaired && KeyStore.selfTest.get("appKey") == nil && prefs.bridgeHost == nil,
               "wrong key saves nothing")
        let keyCheck = MockBridge.calls("GET", "/clip/v2/resource/light").last
        expect(keyCheck?.key == "WRONG", "the pasted key is what gets checked")

        // Right key: saved, paired, lamps load, no button involved.
        MockBridge.on("GET /clip/v2/resource/light", 200, lightsJSON)
        model.useExistingKey(host: " 10.0.0.2 ", key: "  KEY\n")
        try? await Task.sleep(for: .milliseconds(400))
        expect(model.isPaired, "right key pairs")
        expect(KeyStore.selfTest.get("appKey") == "KEY", "trimmed key saved to the (test) Keychain")
        expect(prefs.bridgeHost == "10.0.0.2" && prefs.bridgeID == "001788FFFE000000", "bridge remembered")
        expect(model.lamps.count == 3, "lamps load with the existing key")
        expect(MockBridge.calls("POST", "/api").isEmpty, "no button pairing request was made")
        expect(MockBridge.calls("GET", "/api/0/config").allSatisfy { $0.key == nil }, "config is always fetched without the key")
        model.forgetBridge()
        KeyStore.selfTest.delete("appKey")
        await settle()
    }

    // MARK: AppModel wired to the fake bridge

    private static func modelTests() async {
        MockBridge.reset()
        serveHome()
        let model = AppModel(demo: false, preferences: .scratch(), keyStore: .selfTest)
        model.useForTesting(makeClient())
        let ok = await model.refresh()
        expect(ok && model.lamps.count == 3, "refresh loads 3 lamps")
        expect(model.sections.map(\.title) == ["Living Room", "Other"], "rooms + Other: \(model.sections.map(\.title))")
        expect(model.lamps["c1"]?.capability == .color(whites: 153...500), "color capability from bridge")
        expect(model.lamps["c1"]?.mirek == nil, "mirek_valid false → color mode")
        expect(model.lamps["a1"]?.mirek == 370, "ambiance mirek")
        expect(model.lamps["p1"]?.isDimmable == false && model.lamps["p1"]?.capability == .single,
               "plug: not dimmable, single color")
        expect(model.connection == .live, "live after refresh")

        // Room switch: one command to the room's grouped light; "Other" goes lamp by lamp.
        MockBridge.on("PUT /clip/v2/resource/grouped_light/gr1", 200, #"{"errors":[],"data":[]}"#)
        let livingRoom = model.sections.first { $0.id == "r1" }!
        expect(livingRoom.groupedLightID == "gr1", "room knows its grouped light")
        model.setRoom(livingRoom, on: false)
        await settle()
        let roomCall = MockBridge.calls("PUT", "/clip/v2/resource/grouped_light/gr1").last?.body
        expect((roomCall?["on"] as? [String: Any])?["on"] as? Bool == false, "room switch → grouped light on:false")
        expect(model.sections.first { $0.id == "r1" }!.lamps.allSatisfy { !$0.isOn }, "room tiles show off")
        let otherSection = model.sections.first { $0.id == "other" }!
        model.setRoom(otherSection, on: false)
        await settle()
        expect(!MockBridge.calls("PUT", "/clip/v2/resource/light/p1").isEmpty, "\"Other\" switches lamp by lamp")
        // A switch briefly ignores echoes from those lamps (so tiles don't flicker); let that pass.
        try? await Task.sleep(for: .milliseconds(1600))
        await model.refresh()

        // Toggle sends the right command.
        model.toggle(model.lamps["a1"]!)
        await settle()
        expect(model.lamps["a1"]?.isOn == true, "toggle on (optimistic)")
        let toggle = MockBridge.calls("PUT", "/clip/v2/resource/light/a1").last?.body
        expect((toggle?["on"] as? [String: Any])?["on"] as? Bool == true, "toggle PUT on:true")

        // Review H2: a refresh with stale data right after a click must not flip the tile back.
        await model.refresh()                         // bridge still says a1 is off
        expect(model.lamps["a1"]?.isOn == true, "stale refresh doesn't undo a fresh click")
        // …and a stale echo inside the window is ignored too.
        let staleEcho = decodeEvents(#"[{"type":"update","data":[{"id":"a1","type":"light","on":{"on":false}}]}]"#)
        model.apply(staleEcho)
        expect(model.lamps["a1"]?.isOn == true, "stale echo ignored")

        // Events update other lamps immediately; reachability follows zigbee_connectivity.
        let events = decodeEvents(#"""
        [{"type":"update","data":[
          {"id":"c1","type":"light","dimming":{"brightness":12.0}},
          {"id":"c1","type":"light","color_temperature":{"mirek":250,"mirek_valid":true}},
          {"id":"z3","type":"zigbee_connectivity","owner":{"rid":"d3","rtype":"device"},"status":"connectivity_issue"},
          {"id":"s1","type":"scene","status":{"active":"static"}}]}]
        """#)
        model.apply(events)
        expect(model.lamps["c1"]?.brightness == 12, "event brightness applied")
        expect(model.lamps["c1"]?.mirek == 250, "event switches lamp to white")
        expect(model.lamps["p1"]?.isReachable == false, "connectivity issue → unreachable")

        // Non-dimmable lamps never get a dimming command (review M5).
        let plug = Lamp(id: "p1", deviceID: "d3", hueName: "Plug", isOn: true, brightness: 100, xy: nil, mirek: nil,
                        isReachable: true, capability: .single, isDimmable: false)
        let model2 = AppModel(demo: false, preferences: .scratch(), keyStore: .selfTest)
        model2.useForTesting(makeClient())
        await model2.refresh()
        MockBridge.reset(); serveHome()
        model2.setBrightness(plug, to: 40)
        model2.setBrightness(model2.lamps["p1"]!, to: 0)
        await settle()
        let plugCalls = MockBridge.calls("PUT", "/clip/v2/resource/light/p1")
        expect(!plugCalls.isEmpty && plugCalls.allSatisfy { $0.body?["dimming"] == nil },
               "plug only gets on/off: \(plugCalls.map { $0.body ?? [:] })")
        expect(model2.lamps["p1"]?.isOn == false, "plug dragged to 0 turns off")

        // Brightness drag over time (a move every 20 ms for ~340 ms): throttled, and the last value wins.
        await settle(); MockBridge.reset(); serveHome()
        for value in stride(from: 10.0, through: 90.0, by: 5.0) {
            model2.setBrightness(model2.lamps["c1"]!, to: value)
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let dims = MockBridge.calls("PUT", "/clip/v2/resource/light/c1")
            .compactMap { ($0.body?["dimming"] as? [String: Any])?["brightness"] as? Double }
        expect(dims.count >= 2 && dims.count <= 8, "drag is throttled: \(dims.count) commands for 17 moves (\(dims))")
        expect(dims.last == 90, "last drag value wins: \(dims)")

        // Whites on a color lamp without color-temperature support go out as xy (review M6).
        MockBridge.reset(); serveHome()
        let noCT = Lamp(id: "c1", deviceID: "d1", hueName: "Corner", isOn: true, brightness: 40, xy: (0.2, 0.2),
                        mirek: nil, isReachable: true, capability: .color(whites: nil))
        model2.setWhite(noCT, ColorPalette.whites[0])
        await settle()
        let whiteBody = MockBridge.calls("PUT", "/clip/v2/resource/light/c1").last?.body
        expect(whiteBody?["color"] != nil && whiteBody?["color_temperature"] == nil, "white sent as xy")

        // All off uses group 0; a failed command shows a notice and resyncs.
        MockBridge.reset(); serveHome()
        model2.allOffNow()
        await settle()
        expect(!MockBridge.calls("PUT", "/clip/v2/resource/grouped_light/g0").isEmpty, "all off hits the home group")
        expect(!model2.anyOn, "all off is reflected immediately")

        MockBridge.on("PUT /clip/v2/resource/light/a1", 400, #"{"errors":[{"description":"invalid"}]}"#)
        model2.toggle(model2.lamps["a1"]!)
        await settle()
        expect(model2.notice != nil, "failed command shows a notice")
        expect(!MockBridge.calls("GET", "/clip/v2/resource/light").isEmpty, "failed command triggers a resync")

        // Timer cancelled while the bridge is still creating it: no countdown, and the new timer is removed.
        await settle(); MockBridge.reset(); serveHome()
        MockBridge.on("POST /api/KEY/schedules", 200, #"[{"success":{"id":"9"}}]"#)
        MockBridge.on("DELETE /api/KEY/schedules/9", 200, #"[{"success":"/schedules/9 deleted"}]"#)
        model2.scheduleAllOff(minutes: 15)
        model2.cancelTimer()
        await settle()
        expect(model2.timerFireDate == nil, "cancelled-while-creating timer doesn't come back")
        expect(!MockBridge.calls("DELETE", "/api/KEY/schedules/9").isEmpty, "orphan timer removed from the bridge")

        // Revoked key → back to onboarding, state cleared, and only the test Keychain is touched.
        KeyStore.selfTest.set("TESTKEY", for: "appKey")
        // Only check existence: reading the real secret from a test build would show a Keychain prompt.
        let realKeyBefore = KeyStore.standard.exists("appKey")
        await settle(); MockBridge.reset(); serveHome()
        MockBridge.on("GET /clip/v2/resource/light", 403, "{}")
        await model2.refresh()
        expect(!model2.isPaired && model2.lamps.isEmpty, "revoked key returns to onboarding and clears lamps")
        if case .failed = model2.onboarding { expect(true, "") } else { expect(false, "onboarding shows the reason") }
        expect(KeyStore.selfTest.get("appKey") == nil, "revoked key deleted from the (test) Keychain")
        expect(KeyStore.standard.exists("appKey") == realKeyBefore, "the real Keychain item is never touched by tests")

        await eventLoopTests()
        await shutdownTests()
        await existingKeyTests()

        // Demo/test models never touch the real settings (review M8).
        await settle()
        let real = Preferences()
        let before = real.pendingTimer?.id
        let demo = AppModel(demo: true)
        demo.scheduleAllOff(minutes: 5); demo.cancelTimer(); demo.allOffNow()
        expect(real.pendingTimer?.id == before, "demo mode leaves the real timer record alone")
    }
}
#endif
