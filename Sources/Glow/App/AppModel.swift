import AppKit
import Foundation
import Observation
import SwiftUI

struct LampSection: Identifiable {
    let id: String              // room id, or "other"
    let title: String
    let lamps: [Lamp]
    var groupedLightID: String? = nil
    var isHidden = false
    /// Every lamp of the room, including ones hidden in Glow (the switch acts on the real room).
    var roomLamps: [Lamp] = []

    private var switchLamps: [Lamp] { roomLamps.isEmpty ? lamps : roomLamps }
    /// The room switch shows "on" when any reachable lamp in the room is on.
    var anyOn: Bool { switchLamps.contains { $0.isOn && $0.isReachable } }
    /// Whether the room switch can do anything.
    var anyReachable: Bool { switchLamps.contains(where: \.isReachable) }
}

/// Which screen the popover shows.
enum Page: Equatable {
    case lights
    case arrange
    case rename(String)          // lamp id
    case confirmForget
}

/// Tabs of the Settings window.
enum SettingsTab: String, Hashable {
    case general, about
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static var display: String { "Version \(version) (\(build))" }
}

enum ConnectionState: Equatable {
    case connecting
    case live
    case offline(String)
}

enum OnboardingState: Equatable {
    case searching
    case choose([DiscoveredBridge])
    case waitingForButton(host: String, until: Date)
    case checkingKey(host: String)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    // Lamps & rooms
    private(set) var lamps: [String: Lamp] = [:]
    private(set) var rooms: [Room] = []
    private(set) var connection: ConnectionState = .connecting
    /// A short-lived message for the footer (e.g. "Couldn't set the timer").
    private(set) var notice: String?

    // Setup
    private(set) var isPaired = false
    private(set) var onboarding: OnboardingState = .searching

    // All-off timer
    private(set) var timerFireDate: Date?

    // Local-only customization
    private(set) var customNames: [String: String]
    private(set) var hiddenLampIDs: Set<String>
    private(set) var hiddenRoomIDs: Set<String>
    private(set) var roomOrder: [String]
    private(set) var lampOrder: [String]
    private(set) var appearance: AppearanceSetting

    // Navigation inside the popover, and the Settings window
    var page: Page = .lights
    var settingsTab: SettingsTab = .general
    /// Set by a view that has SwiftUI's `openWindow`; opens the Settings window.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    /// True after an update until the user has seen what's new.
    private(set) var hasUnseenUpdate = false

    let isDemo: Bool

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let keyStore: KeyStore
    /// Swappable for tests: bridge discovery and the retry delay.
    @ObservationIgnored var discover: @MainActor () async -> [DiscoveredBridge] = { await BridgeDiscovery.discover() }
    @ObservationIgnored var retryDelay: (Int) -> Duration = { failures in .seconds(min(30, 2 * failures)) }
    /// Number of failed connection attempts in a row (for status and tests).
    @ObservationIgnored private(set) var consecutiveFailures = 0
    @ObservationIgnored private var timerGeneration = 0
    @ObservationIgnored private var client: HueClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var lastDiscovered: [DiscoveredBridge] = []
    // Brightness drags send at most one command at a time per lamp; the latest value wins.
    @ObservationIgnored private var pendingBrightness: [String: Double] = [:]
    @ObservationIgnored private var brightnessSenders: Set<String> = []
    // After a local change, echoes and refreshes older than the change would make the tile jump back.
    @ObservationIgnored private var suppressEventsUntil: [String: Date] = [:]

    init(demo: Bool = false, preferences: Preferences? = nil, keyStore: KeyStore = .standard) {
        isDemo = demo
        prefs = preferences ?? (demo ? .scratch() : Preferences())
        self.keyStore = demo ? .selfTest : keyStore
        customNames = prefs.customNames
        hiddenLampIDs = prefs.hiddenLampIDs
        hiddenRoomIDs = prefs.hiddenRoomIDs
        roomOrder = prefs.roomOrder
        lampOrder = prefs.lampOrder
        appearance = AppearanceSetting(rawValue: prefs.appearance) ?? .system
        if demo { loadDemoData() }
        if let seen = prefs.lastSeenVersion {
            hasUnseenUpdate = seen != AppInfo.version
        } else if !demo, prefs.bridgeHost != nil {
            hasUnseenUpdate = true                     // upgraded from a version before the banner existed
        } else {
            prefs.lastSeenVersion = AppInfo.version    // first install: nothing "new" to show
        }
    }

    // MARK: - Derived state

    /// What the lights page shows: visible rooms with their visible lamps, in the user's order.
    var sections: [LampSection] { sections(includeHidden: false) }

    /// Every room and lamp, hidden ones included (for the Arrange & Hide page).
    func sections(includeHidden: Bool) -> [LampSection] {
        let candidates = lamps.values.filter { includeHidden || !hiddenLampIDs.contains($0.id) }
        var assigned = Set<String>()
        var result: [LampSection] = []
        // Assign lamps to rooms in a stable (name) order, so a lamp in two rooms always lands in the same one.
        for room in rooms.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let all = lamps.values.filter { room.deviceIDs.contains($0.deviceID) && !assigned.contains($0.id) }
            all.forEach { assigned.insert($0.id) }
            let shown = all.filter { lamp in candidates.contains { $0.id == lamp.id } }
            if !shown.isEmpty {
                result.append(LampSection(id: room.id, title: room.name, lamps: ordered(shown),
                                          groupedLightID: room.groupedLightID,
                                          isHidden: hiddenRoomIDs.contains(room.id),
                                          roomLamps: all))
            }
        }
        let others = candidates.filter { !assigned.contains($0.id) }
        if !others.isEmpty {
            let allOthers = lamps.values.filter { !assigned.contains($0.id) }
            result.append(LampSection(id: "other", title: "Other", lamps: ordered(others),
                                      isHidden: hiddenRoomIDs.contains("other"),
                                      roomLamps: Array(allOthers)))
        }
        if !includeHidden { result.removeAll { $0.isHidden } }
        return orderedSections(result)
    }

    var visibleLampCount: Int { sections.reduce(0) { $0 + $1.lamps.count } }
    var onCount: Int { sections.reduce(0) { $0 + $1.lamps.filter { $0.isOn && $0.isReachable }.count } }
    /// Hidden lamps and rooms that still exist on the bridge.
    var hiddenCount: Int {
        let roomIDs = Set(rooms.map(\.id) + ["other"])
        return hiddenLampIDs.filter { lamps[$0] != nil }.count + hiddenRoomIDs.filter { roomIDs.contains($0) }.count
    }
    /// Drives the menu bar icon: any lamp in the home that's on, hidden or not.
    var anyOn: Bool { lamps.values.contains { $0.isOn && $0.isReachable } }

    func displayName(_ lamp: Lamp) -> String { customNames[lamp.id] ?? lamp.hueName }

    /// The connected bridge's address (for the Settings window).
    var bridgeHost: String? { isDemo ? "Demo" : prefs.bridgeHost }

    /// User order first; lamps the user never moved follow, by name.
    private func ordered(_ lamps: [Lamp]) -> [Lamp] {
        lamps.sorted { a, b in
            let (ia, ib) = (lampOrder.firstIndex(of: a.id), lampOrder.firstIndex(of: b.id))
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
            }
        }
    }

    private func orderedSections(_ sections: [LampSection]) -> [LampSection] {
        sections.sorted { a, b in
            let (ia, ib) = (roomOrder.firstIndex(of: a.id), roomOrder.firstIndex(of: b.id))
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.id == "other" { return false }      // "Other" goes last unless moved
                if b.id == "other" { return true }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    // MARK: - Arranging

    /// Moves a room so it sits where `target` is now.
    func moveRoom(_ id: String, to target: String) {
        guard id != target else { return }
        var order = sections(includeHidden: true).map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        // Keep the place of rooms that have no lamps right now.
        order += roomOrder.filter { !order.contains($0) }
        roomOrder = order
        prefs.roomOrder = order
    }

    /// Moves a lamp within its room so it sits where `target` is now.
    func moveLamp(_ id: String, to target: String) {
        guard id != target,
              let section = sections(includeHidden: true).first(where: { s in s.lamps.contains { $0.id == id } }),
              section.lamps.contains(where: { $0.id == target }) else { return }
        var inRoom = section.lamps.map(\.id)
        guard let from = inRoom.firstIndex(of: id), let to = inRoom.firstIndex(of: target) else { return }
        inRoom.remove(at: from)
        inRoom.insert(id, at: to)
        // Rebuild the global order: every room's lamps in display order, with this room's new order.
        var order: [String] = []
        for s in sections(includeHidden: true) {
            order += s.id == section.id ? inRoom : s.lamps.map(\.id)
        }
        lampOrder = order
        prefs.lampOrder = order
    }

    /// Opens the Settings window on a tab and brings Glow to the front.
    func openSettings(_ tab: SettingsTab = .general) {
        settingsTab = tab
        openSettingsWindow?()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first { $0.identifier?.rawValue.contains("settings") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    /// Moves a room up (-1) or down (+1).
    func moveRoom(_ id: String, by offset: Int) {
        let ids = sections(includeHidden: true).map(\.id)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + offset) else { return }
        moveRoom(id, to: ids[i + offset])
    }

    /// List-style move of lamps inside one room (for drag-to-reorder in Settings).
    func moveLamps(in sectionID: String, from source: IndexSet, to destination: Int) {
        guard let section = sections(includeHidden: true).first(where: { $0.id == sectionID }) else { return }
        var inRoom = section.lamps.map(\.id)
        inRoom.move(fromOffsets: source, toOffset: destination)
        var order: [String] = []
        for s in sections(includeHidden: true) {
            order += s.id == sectionID ? inRoom : s.lamps.map(\.id)
        }
        lampOrder = order
        prefs.lampOrder = order
    }

    func setRoomHidden(_ id: String, _ hidden: Bool) {
        if hidden { hiddenRoomIDs.insert(id) } else { hiddenRoomIDs.remove(id) }
        prefs.hiddenRoomIDs = hiddenRoomIDs
    }

    func setLampHidden(_ lamp: Lamp, _ hidden: Bool) {
        if hidden { hiddenLampIDs.insert(lamp.id) } else { hiddenLampIDs.remove(lamp.id) }
        prefs.hiddenLampIDs = hiddenLampIDs
    }

    func resetArrangement() {
        roomOrder = []; lampOrder = []
        prefs.roomOrder = []; prefs.lampOrder = []
    }

    // MARK: - Appearance & version

    func setAppearance(_ value: AppearanceSetting) {
        appearance = value
        prefs.appearance = value.rawValue
        applyAppearance()
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func markUpdateSeen() {
        hasUnseenUpdate = false
        prefs.lastSeenVersion = AppInfo.version
    }

    private func isSuppressed(_ id: String) -> Bool { (suppressEventsUntil[id] ?? .distantPast) > Date() }

    // MARK: - Startup

    func start() {
        applyAppearance()
        guard !isDemo else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { if self.client != nil { self.reconnect() } }
        }

        if let host = prefs.bridgeHost, let key = keyStore.get("appKey") {
            isPaired = true
            connect(host: host, appKey: key)
            restorePendingTimer()
        } else {
            beginOnboarding()
        }
    }

    /// Called when the popover opens; cheap safety net in case an event was missed.
    func popoverDidAppear() {
        guard !isDemo, isPaired, client != nil, Date().timeIntervalSince(lastRefresh) > 30 else { return }
        Task { await refresh() }
    }

    // MARK: - Connection

    private func connect(host: String, appKey: String) {
        client?.invalidate()
        let trust = BridgeTrust(host: host, pinnedFingerprint: prefs.certificateFingerprint)
        client = HueClient(host: host, appKey: appKey, trust: trust, protocolClasses: self.testProtocolClasses)
        reconnect()
    }

    private func reconnect() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in await self?.runEventLoop() }
    }

    func runEventLoop() async {
        consecutiveFailures = 0
        while !Task.isCancelled {
            guard let client else { return }
            // Show "Connecting…" only on a first attempt; while retrying keep "offline" (no flicker).
            if consecutiveFailures == 0, connection != .live { connection = .connecting }
            var quietReconnect = false

            // Can't load the state: that's a failure; don't sit on a stream that can't work.
            let refreshed = await refresh()
            Log.model.info("loop: refresh \(refreshed ? "ok" : "FAILED", privacy: .public), failures so far \(self.consecutiveFailures)")
            if refreshed {
                let streamStart = Date()
                do {
                    for try await batch in client.events() {
                        connection = .live
                        consecutiveFailures = 0
                        apply(batch)
                    }
                    // Closed cleanly. Fine after a while; a bridge that closes at once is failing.
                    quietReconnect = Date().timeIntervalSince(streamStart) > 5
                } catch HueError.unauthorized {
                    handleUnauthorized()
                    return
                } catch let error as URLError where error.code == .timedOut {
                    // No events for a long while (quiet night) right after a good refresh: not an outage.
                    quietReconnect = Date().timeIntervalSince(streamStart) > 5
                } catch {}
            } else if !isPaired {
                return      // refresh hit "unauthorized" and tore the connection down
            }
            if Task.isCancelled { return }

            if quietReconnect {
                consecutiveFailures = 0
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            consecutiveFailures += 1
            let failures = consecutiveFailures
            Log.model.error("loop: failure #\(failures) → offline, retry in \(String(describing: self.retryDelay(failures)), privacy: .public)")
            if case .offline = connection {} else { connection = .offline(offlineReason(nil, client)) }
            // Its old address may now belong to another device (which would also look like a
            // certificate change), so look for the bridge by its id every third failure either way.
            if failures % 3 == 0 { await rediscoverBridge() }
            try? await Task.sleep(for: retryDelay(failures))
        }
    }

    /// Reloads everything from the bridge. Returns false if the bridge couldn't be reached.
    @discardableResult
    func refresh() async -> Bool {
        guard let client else { return false }
        do {
            async let lightsCall = client.fetchLights()
            async let roomsCall = client.fetchRooms()
            async let connectivityCall = client.fetchConnectivity()
            let (lights, rooms, connectivity) = try await (lightsCall, roomsCall, connectivityCall)
            // Forgotten or replaced while we waited: drop the stale result.
            guard self.client === client else { return false }

            let unreachableDevices = Set(connectivity.filter { $0.status != "connected" }.map(\.owner.rid))
            var next: [String: Lamp] = [:]
            for light in lights {
                var lamp = Lamp(
                    id: light.id,
                    deviceID: light.owner.rid,
                    hueName: light.metadata.name,
                    isOn: light.on.on,
                    brightness: light.dimming?.brightness ?? 100,
                    xy: light.color.map { ($0.xy.x, $0.xy.y) },
                    mirek: Self.activeMirek(light.color_temperature),
                    isReachable: !unreachableDevices.contains(light.owner.rid),
                    capability: Self.capability(of: light),
                    isDimmable: light.dimming != nil
                )
                // A local change newer than this snapshot wins.
                if isSuppressed(light.id), let current = lamps[light.id] {
                    lamp.isOn = current.isOn
                    lamp.brightness = current.brightness
                    lamp.xy = current.xy
                    lamp.mirek = current.mirek
                }
                next[light.id] = lamp
            }
            lamps = next
            self.rooms = rooms.map {
                Room(id: $0.id, name: $0.metadata.name,
                     deviceIDs: Set($0.children.filter { $0.rtype == "device" }.map(\.rid)),
                     groupedLightID: $0.groupedLightID)
            }
            lastRefresh = Date()
            // While retrying, the event stream (not a lone refresh) decides when we're live again.
            if connection != .live, consecutiveFailures == 0 { connection = .live }
            pinCertificateIfNeeded(client)
            return true
        } catch HueError.unauthorized {
            if self.client === client, isPaired { handleUnauthorized() }
            return false
        } catch {
            Log.model.error("refresh failed: \(Log.describe(error), privacy: .public)")
            if self.client === client, !Task.isCancelled {
                connection = .offline(offlineReason(error, client))
            }
            return false
        }
    }

    private func offlineReason(_ error: Error?, _ client: HueClient) -> String {
        if case HueError.localNetworkDenied? = error { return HueError.localNetworkDenied.localizedDescription }
        return client.trust.pinMismatch ? HueError.certificateChanged.localizedDescription : "Can't reach the Hue Bridge"
    }

    /// Older setups may have no stored pin; pin the certificate seen on the first good connection.
    private func pinCertificateIfNeeded(_ client: HueClient) {
        guard prefs.certificateFingerprint == nil, let seen = client.trust.observedFingerprint else { return }
        prefs.certificateFingerprint = seen
        client.trust.pinnedFingerprint = seen
    }

    static func capability(of light: HueLightResource) -> LampCapability {
        let whites = light.color_temperature?.mirek_schema.map { $0.mirek_minimum...$0.mirek_maximum }
        if light.color != nil { return .color(whites: whites) }
        if let whites { return .whites(whites) }
        if light.color_temperature != nil { return .whites(153...454) }
        return .single
    }

    /// The lamp is in white mode when the bridge says its mirek is valid.
    private static func activeMirek(_ ct: HueLightResource.ColorTemperature?) -> Int? {
        guard let ct, ct.mirek_valid ?? true else { return nil }
        return ct.mirek
    }

    func apply(_ batch: [HueEvent]) {
        var needsRefresh = false
        for event in batch {
            if event.type == "add" || event.type == "delete" { needsRefresh = true; continue }
            guard event.type == "update" else { continue }
            for item in event.data {
                switch item.type {
                case "light":
                    guard var lamp = lamps[item.id] else { needsRefresh = true; continue }
                    let suppressed = isSuppressed(item.id)
                    if let on = item.on, !suppressed { lamp.isOn = on.on }
                    if let dimming = item.dimming, !suppressed { lamp.brightness = dimming.brightness }
                    if !suppressed {
                        if let ct = item.color_temperature {
                            // mirek_valid false means the lamp switched to a color.
                            lamp.mirek = (ct.mirek_valid ?? true) ? (ct.mirek ?? lamp.mirek) : nil
                        }
                        if let color = item.color { lamp.xy = (color.xy.x, color.xy.y) }
                    }
                    lamps[item.id] = lamp
                case "zigbee_connectivity":
                    if let device = item.owner?.rid, let status = item.status {
                        for (id, lamp) in lamps where lamp.deviceID == device {
                            lamps[id]?.isReachable = status == "connected"
                        }
                    }
                case "room", "device":
                    needsRefresh = true
                default:
                    break
                }
            }
        }
        if needsRefresh { Task { await refresh() } }
    }

    /// The bridge may get a new IP address from the router. Find it again by its id.
    private func rediscoverBridge() async {
        guard let bridgeID = prefs.bridgeID, let key = keyStore.get("appKey"), let original = client else { return }
        let candidates = await discover()
        for candidate in candidates where candidate.host != original.host {
            // The user may have forgotten the bridge (or been signed out) while we searched.
            guard !Task.isCancelled, client === original else { return }
            let probe = HueClient(host: candidate.host, appKey: nil,
                                  trust: BridgeTrust(host: candidate.host, pinnedFingerprint: prefs.certificateFingerprint))
            defer { probe.invalidate() }
            if let config = try? await probe.fetchConfig(),
               config.bridgeid.lowercased() == bridgeID.lowercased() {
                guard !Task.isCancelled, client === original else { return }
                prefs.bridgeHost = candidate.host
                original.finishAndInvalidate()      // let commands already on their way finish
                client = HueClient(host: candidate.host, appKey: key,
                                   trust: BridgeTrust(host: candidate.host, pinnedFingerprint: prefs.certificateFingerprint))
                return
            }
        }
    }

    private func handleUnauthorized() {
        keyStore.delete("appKey")
        tearDownConnection()
        onboarding = .failed(HueError.unauthorized.localizedDescription)
    }

    private func tearDownConnection() {
        eventTask?.cancel()
        timerTask?.cancel()
        timerGeneration += 1
        client?.invalidate()
        client = nil
        lamps = [:]
        rooms = []
        timerFireDate = nil
        prefs.pendingTimer = nil
        suppressEventsUntil = [:]
        pendingBrightness = [:]
        connection = .connecting
        isPaired = false
    }

    // MARK: - Lamp actions

    func toggle(_ lamp: Lamp) {
        guard lamp.isReachable, var current = lamps[lamp.id] else { return }
        current.isOn.toggle()
        Log.model.info("action: toggle \(lamp.hueName, privacy: .private) [\(lamp.id.prefix(8), privacy: .public)] → \(current.isOn ? "on" : "off", privacy: .public)")
        lamps[lamp.id] = current
        suppressEventsUntil[lamp.id] = Date().addingTimeInterval(1.5)
        send { try await $0.setLight(id: lamp.id, on: current.isOn) }
    }

    /// `value` is 0...100. Dragging to 0 turns the lamp off.
    /// On/off-only devices just switch: any value above 0 means on.
    func setBrightness(_ lamp: Lamp, to value: Double) {
        guard lamp.isReachable, var current = lamps[lamp.id] else { return }
        let value = min(100, max(0, value))

        guard current.isDimmable else {
            let on = value >= 1
            guard on != current.isOn else { return }
            current.isOn = on
            lamps[lamp.id] = current
            suppressEventsUntil[lamp.id] = Date().addingTimeInterval(1.5)
            send { try await $0.setLight(id: lamp.id, on: on) }
            return
        }

        if value < 1 {
            current.isOn = false
        } else {
            current.isOn = true
            current.brightness = value
        }
        lamps[lamp.id] = current
        suppressEventsUntil[lamp.id] = Date().addingTimeInterval(1.5)

        guard !isDemo else { return }
        if brightnessSenders.isEmpty || pendingBrightness[lamp.id] == nil {
            Log.model.info("action: brightness \(Int(value)) on [\(lamp.id.prefix(8), privacy: .public)]")
        }
        pendingBrightness[lamp.id] = value
        guard !brightnessSenders.contains(lamp.id) else { return }
        brightnessSenders.insert(lamp.id)
        Task {
            var failed = false
            while let next = pendingBrightness.removeValue(forKey: lamp.id) {
                do {
                    if next < 1 {
                        try await client?.setLight(id: lamp.id, on: false)
                    } else {
                        try await client?.setLight(id: lamp.id, on: true, brightness: next, transitionMs: 100)
                    }
                } catch {
                    failed = true
                }
                suppressEventsUntil[lamp.id] = Date().addingTimeInterval(1.5)
                try? await Task.sleep(for: .milliseconds(90))
            }
            brightnessSenders.remove(lamp.id)
            if failed {
                suppressEventsUntil[lamp.id] = nil
                await refresh()
            }
        }
    }

    func setColor(_ lamp: Lamp, _ swatch: ColorPalette.Swatch) {
        guard lamp.isReachable, case .color = lamp.capability else { return }
        Log.model.info("action: color \(swatch.name, privacy: .public) on [\(lamp.id.prefix(8), privacy: .public)]")
        lamps[lamp.id]?.isOn = true
        lamps[lamp.id]?.xy = swatch.xy
        lamps[lamp.id]?.mirek = nil
        suppressEventsUntil[lamp.id] = Date().addingTimeInterval(1.5)
        send { try await $0.setLight(id: lamp.id, on: true, xy: swatch.xy, transitionMs: 300) }
    }

    func setWhite(_ lamp: Lamp, _ white: ColorPalette.White) {
        guard lamp.isReachable else { return }
        Log.model.info("action: white \(white.name, privacy: .public) on [\(lamp.id.prefix(8), privacy: .public)]")
        suppressEventsUntil[lamp.id] = Date().addingTimeInterval(1.5)
        switch lamp.capability {
        case .single:
            return
        case .color(whites: nil):
            // A color lamp without color-temperature support: approximate the white with xy.
            let xy = HueColor.xy(from: white.rgb)
            lamps[lamp.id]?.isOn = true
            lamps[lamp.id]?.xy = xy
            lamps[lamp.id]?.mirek = nil
            send { try await $0.setLight(id: lamp.id, on: true, xy: xy, transitionMs: 300) }
        default:
            lamps[lamp.id]?.isOn = true
            lamps[lamp.id]?.mirek = white.mirek
            send { try await $0.setLight(id: lamp.id, on: true, mirek: white.mirek, transitionMs: 300) }
        }
    }

    /// The room switch: turns every reachable lamp in the room on or off.
    /// Hue rooms switch with one command (their grouped light); "Other" switches lamp by lamp.
    func setRoom(_ section: LampSection, on: Bool) {
        Log.model.info("action: room [\(section.id.prefix(8), privacy: .public)] → \(on ? "on" : "off", privacy: .public)")
        // Every lamp of the room, including ones hidden in Glow: the switch acts on the real room.
        let ids = (section.roomLamps.isEmpty ? section.lamps : section.roomLamps).map(\.id)
        for id in ids where lamps[id]?.isReachable == true {
            lamps[id]?.isOn = on
            suppressEventsUntil[id] = Date().addingTimeInterval(1.5)
        }
        if let group = section.groupedLightID {
            send { try await $0.setGroupedLight(id: group, on: on) }
        } else {
            let targets = ids.filter { lamps[$0]?.isReachable == true }
            // Keep going if one lamp fails; report once at the end.
            send { client in
                var failed = false
                for id in targets {
                    do { try await client.setLight(id: id, on: on) } catch { failed = true }
                }
                if failed { throw HueError.badResponse("room switch") }
            }
        }
    }

    func allOffNow() {
        Log.model.info("action: all off now")
        for id in lamps.keys {
            lamps[id]?.isOn = false
            suppressEventsUntil[id] = Date().addingTimeInterval(1.5)
        }
        cancelTimer()
        send { try await $0.allOff() }
    }

    func scheduleAllOff(minutes: Int) {
        let fireDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if isDemo {
            setTimer(fireDate: fireDate)
            return
        }
        timerGeneration += 1
        let generation = timerGeneration
        let old = prefs.pendingTimer
        prefs.pendingTimer = nil
        Task {
            guard let client else { return }
            var oldRemoved = true
            if let old {
                do { try await client.cancelSchedule(id: old.id) } catch { oldRemoved = false }
            }
            do {
                let id = try await client.scheduleAllOff(after: minutes * 60)
                // Cancelled, or replaced by a newer choice, while the bridge was answering:
                // remove the timer we just created instead of showing it.
                guard generation == timerGeneration, self.client === client else {
                    if self.client === client { try? await client.cancelSchedule(id: id) }
                    return
                }
                prefs.pendingTimer = (id, fireDate)
                setTimer(fireDate: fireDate)
            } catch HueError.unauthorized {
                if self.client === client { handleUnauthorized() }
            } catch {
                guard generation == timerGeneration, self.client === client else { return }
                if let old, !oldRemoved {
                    prefs.pendingTimer = old          // the previous timer is still on the bridge
                    setTimer(fireDate: old.fireDate)
                } else {
                    timerTask?.cancel()
                    timerFireDate = nil               // don't show a countdown nothing will act on
                }
                showNotice("Couldn't set the timer on the bridge")
            }
        }
    }

    func cancelTimer() {
        timerGeneration += 1
        timerTask?.cancel()
        timerFireDate = nil
        guard let pending = prefs.pendingTimer else { return }
        prefs.pendingTimer = nil
        send { try await $0.cancelSchedule(id: pending.id) }
    }

    private func setTimer(fireDate: Date) {
        timerFireDate = fireDate
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, fireDate.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.timerFireDate = nil
            self.prefs.pendingTimer = nil
            if self.isDemo {
                for id in self.lamps.keys { self.lamps[id]?.isOn = false }
            }
            // With a real bridge, the lamps report "off" through the event stream.
        }
    }

    private func restorePendingTimer() {
        guard let pending = prefs.pendingTimer else { return }
        guard pending.fireDate > Date() else { prefs.pendingTimer = nil; return }
        setTimer(fireDate: pending.fireDate)
        Task {
            // Only a definite "doesn't exist" clears it; network errors keep the countdown.
            if let exists = try? await client?.scheduleExists(id: pending.id), !exists {
                timerTask?.cancel()
                timerFireDate = nil
                prefs.pendingTimer = nil
            }
        }
    }

    private func send(_ action: @escaping (HueClient) async throws -> Void) {
        guard !isDemo, let client else { return }
        Task {
            do { try await action(client) }
            catch HueError.unauthorized { if self.client === client { handleUnauthorized() } }
            catch {
                // Put the UI back in sync with reality.
                showNotice("The bridge didn't accept that change")
                await refresh()
            }
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Local customization

    func rename(_ lamp: Lamp, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customNames[lamp.id] = trimmed.isEmpty || trimmed == lamp.hueName ? nil : trimmed
        prefs.customNames = customNames
    }

    func hide(_ lamp: Lamp) {
        hiddenLampIDs.insert(lamp.id)
        prefs.hiddenLampIDs = hiddenLampIDs
    }

    func unhideAll() {
        hiddenLampIDs = []
        hiddenRoomIDs = []
        prefs.hiddenLampIDs = []
        prefs.hiddenRoomIDs = []
    }

    // MARK: - Onboarding

    /// Searches for bridges. With exactly one found it pairs straight away, unless `autoPair` is off
    /// (after the user cancelled), in which case it just lists it.
    func beginOnboarding(autoPair: Bool = true) {
        pairingTask?.cancel()
        discoveryTask?.cancel()
        onboarding = .searching
        discoveryTask = Task {
            let bridges = await discover()
            guard !Task.isCancelled, case .searching = onboarding else { return }
            lastDiscovered = bridges
            if autoPair, bridges.count == 1 {
                pair(with: bridges[0].host)
            } else {
                onboarding = .choose(bridges)
            }
        }
    }

    /// How long Glow keeps asking the bridge while the user walks over to press the button.
    static let pairingWindow: TimeInterval = 180
    @ObservationIgnored private var lastPairingHost: String?

    /// "Try Again": pair with the bridge we already know about, or search if there's none.
    func retryPairing() {
        if let host = lastPairingHost ?? lastDiscovered.first?.host {
            pair(with: host)
        } else {
            beginOnboarding()
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        onboarding = .choose(lastDiscovered)
    }

    func pair(with host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard Self.isValidHost(host) else {
            onboarding = .failed("\"\(host)\" isn't a valid bridge address. Use something like 192.168.1.20.")
            return
        }
        pairingTask?.cancel()
        discoveryTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.pairingWindow)
        onboarding = .waitingForButton(host: host, until: deadline)
        lastPairingHost = host

        pairingTask = Task {
            let trust = BridgeTrust(host: host, pinnedFingerprint: nil)
            let probe = HueClient(host: host, appKey: nil, trust: trust, protocolClasses: self.testProtocolClasses)
            defer { probe.invalidate() }
            let config: BridgeConfig
            do {
                config = try await probe.fetchConfig()
            } catch {
                if !Task.isCancelled { onboarding = .failed(Self.pairingFailure(error, host: host)) }
                return
            }
            // A key handed out by the real bridge must not travel through an impostor in between.
            guard verifyGenuine(trust, config, host: host) else {
                if !Task.isCancelled { onboarding = .failed(Self.notGenuineMessage) }
                return
            }
            // Keep asking while the user walks to the bridge.
            while Date() < deadline {
                if Task.isCancelled { return }
                do {
                    let credentials = try await probe.pair()
                    guard !Task.isCancelled else { return }
                    keyStore.set(credentials.username, for: "appKey")
                    prefs.bridgeHost = host
                    prefs.bridgeID = config.bridgeid
                    prefs.certificateFingerprint = trust.observedFingerprint
                    isPaired = true
                    connect(host: host, appKey: credentials.username)
                    return
                } catch HueError.linkButtonNotPressed {
                    try? await Task.sleep(for: .seconds(2))
                } catch {
                    if !Task.isCancelled { onboarding = .failed(error.localizedDescription) }
                    return
                }
            }
            if !Task.isCancelled { onboarding = .failed("The bridge button wasn't pressed in time.") }
        }
    }

    /// Pairs with a key another app already has (e.g. Home Assistant's `api_key`),
    /// skipping the bridge button. The key is checked against the bridge before it's saved.
    func useExistingKey(host: String, key: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !key.isEmpty else { return }
        guard Self.isValidHost(host) else {
            onboarding = .failed("\"\(host)\" isn't a valid bridge address. Use something like 192.168.1.20.")
            return
        }
        pairingTask?.cancel()
        discoveryTask?.cancel()
        onboarding = .checkingKey(host: host)

        pairingTask = Task {
            // First contact WITHOUT the key: the bridge proves who it is before the key goes anywhere.
            let trust = BridgeTrust(host: host, pinnedFingerprint: nil)
            let probe = HueClient(host: host, appKey: nil, trust: trust, protocolClasses: self.testProtocolClasses)
            defer { probe.invalidate() }
            let config: BridgeConfig
            do {
                config = try await probe.fetchConfig()
            } catch {
                if !Task.isCancelled { onboarding = .failed(Self.pairingFailure(error, host: host)) }
                return
            }
            guard verifyGenuine(trust, config, host: host) else {
                if !Task.isCancelled { onboarding = .failed(Self.notGenuineMessage) }
                return
            }
            // Only now is the key used, on a connection pinned to the verified certificate.
            let keyed = HueClient(host: host, appKey: key, trust: trust, protocolClasses: self.testProtocolClasses)
            defer { keyed.invalidate() }
            do {
                _ = try await keyed.fetchLights()       // 403 if the bridge doesn't know this key
            } catch HueError.unauthorized {
                if !Task.isCancelled { onboarding = .failed("This bridge doesn't accept that key. Check it, or pair with the button instead.") }
                return
            } catch {
                if !Task.isCancelled { onboarding = .failed("Couldn't check the key: \(error.localizedDescription)") }
                return
            }
            guard !Task.isCancelled else { return }
            keyStore.set(key, for: "appKey")
            prefs.bridgeHost = host
            prefs.bridgeID = config.bridgeid
            prefs.certificateFingerprint = trust.observedFingerprint
            isPaired = true
            connect(host: host, appKey: key)
        }
    }

    /// An IPv4/IPv6 address or a simple host name, and nothing that could change the URL.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return URL(string: "https://\(host.contains(":") ? "[\(host)]" : host)/") != nil
    }

    private static func pairingFailure(_ error: Error, host: String) -> String {
        if case HueError.localNetworkDenied = error { return HueError.localNetworkDenied.localizedDescription }
        return "No Hue Bridge answered at \(host)."
    }

    /// True when the current problem is macOS's Local Network permission (the UI offers a shortcut).
    var isBlockedByLocalNetworkPrivacy: Bool {
        let blocked = HueError.localNetworkDenied.localizedDescription
        if case .failed(blocked) = onboarding, !isPaired { return true }
        if case .offline(blocked) = connection, isPaired { return true }
        return false
    }

    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The bridge must prove it's a genuine Philips Hue Bridge before Glow pairs with it or sends it a key:
    /// its certificate is signed by Philips' Hue root and issued to the bridge id it reports.
    /// On success the certificate is pinned for the rest of setup, so it can't be swapped mid-way.
    /// (Every bridge that can run Glow, i.e. that has Hue API v2, has such a certificate.)
    private func verifyGenuine(_ trust: BridgeTrust, _ config: BridgeConfig, host: String) -> Bool {
        guard requireGenuineBridge else { return true }
        guard let proven = trust.verifiedBridgeID, proven == config.bridgeid.lowercased(),
              let seen = trust.observedFingerprint else {
            Log.model.error("setup: \(host, privacy: .private) is not a verified Hue Bridge; stopped")
            return false
        }
        trust.pinnedFingerprint = seen
        return true
    }

    private static let notGenuineMessage =
        "This device didn't prove it's a genuine Philips Hue Bridge, so Glow stopped before pairing or sending any key. Check the address, or make sure you're on your home network."

    /// Hosts to suggest in the key form: whatever discovery found.
    var suggestedHost: String { lastDiscovered.first?.host ?? "" }

    func forgetBridge() {
        // The key still works now: remove a pending timer from the bridge before forgetting it.
        // Detach the client first so the teardown below doesn't close it under the request.
        if let pending = prefs.pendingTimer, let old = client {
            client = nil
            Task {
                try? await old.cancelSchedule(id: pending.id)
                old.invalidate()
            }
        }
        keyStore.delete("appKey")
        tearDownConnection()
        prefs.forgetBridge()
        beginOnboarding()
    }

    // MARK: - Testing

    /// Lets tests route the key check through the fake bridge.
    @ObservationIgnored var testProtocolClasses: [AnyClass]?
    /// Tests over the plain-HTTP fake bridge can't present a certificate; real use always checks.
    @ObservationIgnored var requireGenuineBridge = true

    /// Connects to a given client without discovery, Keychain or the event loop
    /// (self-test and the live `--e2e` test).
    func useForTesting(_ client: HueClient) {
        self.client = client
        isPaired = true
    }

    #if DEBUG

    func setOnboardingForPreview(_ state: OnboardingState) {
        isPaired = false
        onboarding = state
    }

    func setConnectionForPreview(_ state: ConnectionState) {
        connection = state
    }
    #endif

    // MARK: - Demo data (for `--demo` and `--snapshot`)

    private func loadDemoData() {
        isPaired = true
        connection = .live
        func lamp(_ id: String, _ room: String, _ name: String, on: Bool, _ bri: Double,
                  xy: (Double, Double)? = nil, mirek: Int? = nil, reachable: Bool = true,
                  _ capability: LampCapability = .color(whites: 153...500)) -> Lamp {
            Lamp(id: id, deviceID: "\(room)-\(id)", hueName: name, isOn: on, brightness: bri,
                 xy: xy, mirek: mirek, isReachable: reachable, capability: capability)
        }
        let ambiance = LampCapability.whites(153...454)
        let all = [
            lamp("1", "living", "Floor", on: true, 70, mirek: 370, ambiance),
            lamp("2", "living", "Ceiling", on: false, 100, mirek: 300, ambiance),
            lamp("3", "living", "Corner", on: true, 40, xy: (0.22, 0.12)),
            lamp("4", "living", "TV Strip", on: true, 55, xy: (0.16, 0.22)),
            lamp("5", "office", "Desk", on: true, 85, mirek: 233),
            lamp("6", "office", "Shelf", on: false, 60, mirek: 450),
            lamp("7", "office", "Monitor Bar", on: false, 50, mirek: 200),
            lamp("8", "bedroom", "Bedside L", on: false, 30, mirek: 454, ambiance),
            lamp("9", "bedroom", "Bedside R", on: false, 30, mirek: 454, ambiance),
            lamp("10", "bedroom", "Ceiling", on: false, 100, .single),
            lamp("11", "none", "Hallway", on: true, 25, .single),
            lamp("12", "none", "Kitchen", on: false, 100, mirek: 250),
            lamp("13", "none", "Balcony", on: false, 0, reachable: false, .single),
        ]
        lamps = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        rooms = [
            Room(id: "living", name: "Living Room", deviceIDs: Set(all.filter { $0.deviceID.hasPrefix("living") }.map(\.deviceID))),
            Room(id: "office", name: "Office", deviceIDs: Set(all.filter { $0.deviceID.hasPrefix("office") }.map(\.deviceID))),
            Room(id: "bedroom", name: "Bedroom", deviceIDs: Set(all.filter { $0.deviceID.hasPrefix("bedroom") }.map(\.deviceID))),
        ]
    }
}
