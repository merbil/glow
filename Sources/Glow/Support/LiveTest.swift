import AppKit
import Foundation

/// End-to-end test against the real, paired bridge, through the same model code the UI uses.
/// It changes real lamps and restores every lamp to its previous state at the end.
///   open -W -n /Applications/Glow.app --stdout /tmp/glow-e2e.txt --args --e2e
/// Uses the saved bridge settings and key read-only; the test model uses throwaway settings
/// and the test Keychain, so it can't sign the app out or change its preferences.
@MainActor
enum LiveTest {
    private struct Saved { let on: Bool; let brightness: Double?; let xy: (Double, Double)?; let mirek: Int? }

    private static var passed = 0
    private static var failed: [String] = []
    private static func say(_ text: String) { print(text); fflush(stdout) }
    private static func check(_ ok: Bool, _ text: String) {
        if ok { passed += 1; say("  ✓ \(text)") } else { failed.append(text); say("  ✗ \(text)") }
    }
    private static func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    static func run() async -> Int32 {
        let prefs = Preferences()
        guard let host = prefs.bridgeHost, let key = KeyStore.standard.get("appKey") else {
            say("Not paired: no saved bridge or key."); return 2
        }
        say("Glow live test — bridge \(host)")
        let client = HueClient(host: host, appKey: key,
                               trust: BridgeTrust(host: host, pinnedFingerprint: prefs.certificateFingerprint))
        let model = AppModel(demo: false, preferences: .scratch(), keyStore: .selfTest)
        model.useForTesting(client)

        // 1. Load everything.
        say("\n1. Loading lamps and rooms")
        check(await model.refresh(), "lamps, rooms and reachability load")
        for section in model.sections {
            say("  \(section.title):")
            for lamp in section.lamps {
                say("    \(lamp.hueName) [\(lamp.id.prefix(8))] \(lamp.isOn ? "on" : "off")\(lamp.isReachable ? "" : ", UNREACHABLE")"
                    + ", \(lamp.isDimmable ? "dimmable" : "on/off only"), \(describe(lamp.capability))")
            }
        }

        // 2. Live events.
        say("\n2. Live event stream")
        var events: [(Date, String, Bool?)] = []
        let stream = Task { @MainActor in
            do {
                for try await batch in client.events() {
                    for item in batch.flatMap(\.data) where item.type == "light" {
                        events.append((Date(), item.id, item.on?.on))
                    }
                    model.apply(batch)
                }
            } catch { say("  (stream ended: \(Log.describe(error)))") }
        }
        await wait(1500)

        // Remember every lamp exactly as it is now.
        let raw = (try? await client.fetchLights()) ?? []
        var saved: [String: Saved] = [:]
        for light in raw {
            let white = light.color_temperature?.mirek_valid == true ? light.color_temperature?.mirek : nil
            saved[light.id] = Saved(on: light.on.on, brightness: light.dimming?.brightness,
                                    xy: white == nil ? light.color.map { ($0.xy.x, $0.xy.y) } : nil, mirek: white)
        }

        let candidates = model.lamps.values.filter { $0.isReachable && $0.isDimmable }
        guard let test = candidates.first(where: { if case .color = $0.capability { return true }; return false })
                ?? candidates.first else {
            say("No reachable dimmable lamp to test with."); stream.cancel(); return 2
        }
        say("  test lamp: \(test.hueName) [\(test.id.prefix(8))]")

        // 3. Toggle.
        say("\n3. Toggle")
        let startOn = model.lamps[test.id]!.isOn
        events.removeAll()
        model.toggle(model.lamps[test.id]!)
        await wait(1500)
        check(await bridgeState(client, test.id)?.on.on == !startOn, "bridge reports \(startOn ? "off" : "on") after a click")
        check(events.contains { $0.1 == test.id && $0.2 == !startOn }, "live event confirms it")
        model.toggle(model.lamps[test.id]!)
        await wait(1500)
        check(await bridgeState(client, test.id)?.on.on == startOn, "second click restores it")

        // 4. Brightness, including a quick drag.
        say("\n4. Brightness")
        model.setBrightness(model.lamps[test.id]!, to: 25)
        await wait(1500)
        let b25 = await bridgeState(client, test.id)?.dimming?.brightness ?? -1
        check(abs(b25 - 25) <= 2, "set 25% → bridge reports \(Int(b25))%")
        for v in stride(from: 30.0, through: 70.0, by: 4.0) {
            model.setBrightness(model.lamps[test.id]!, to: v)
            await wait(25)
        }
        await wait(1500)
        let bDrag = await bridgeState(client, test.id)?.dimming?.brightness ?? -1
        check(abs(bDrag - 70) <= 2, "drag ending at 70% → bridge reports \(Int(bDrag))%")
        check(abs((model.lamps[test.id]?.brightness ?? 0) - bDrag) <= 2, "tile matches the bridge after the drag")

        // 5. Colors and whites.
        say("\n5. Colors and whites")
        if case .color = test.capability {
            let red = ColorPalette.colors.first { $0.name == "Red" }!
            model.setColor(model.lamps[test.id]!, red)
            await wait(1500)
            if let xy = await bridgeState(client, test.id)?.color?.xy {
                let d = ((xy.x - red.xy.x) * (xy.x - red.xy.x) + (xy.y - red.xy.y) * (xy.y - red.xy.y)).squareRoot()
                check(d < 0.08, "Red → bridge xy (\(String(format: "%.3f, %.3f", xy.x, xy.y))), off by \(String(format: "%.3f", d))")
            } else { check(false, "Red → bridge reports a color") }
        }
        if test.capability != .single {
            let warm = ColorPalette.whites[0]
            model.setWhite(model.lamps[test.id]!, warm)
            await wait(1500)
            let ct = await bridgeState(client, test.id)?.color_temperature
            check(ct?.mirek_valid == true && abs((ct?.mirek ?? 0) - warm.mirek) <= 20,
                  "Warm white → bridge mirek \(ct?.mirek.map(String.init) ?? "none") (asked \(warm.mirek))")
        }
        await restore(client, [test.id: saved[test.id]!])

        // 5b. Room switch on the test lamp's room (one command to the room's grouped light).
        say("\n5b. Room switch")
        if let room = model.sections.first(where: { s in s.lamps.contains { $0.id == test.id } }), room.groupedLightID != nil {
            let roomIDs = room.lamps.filter(\.isReachable).map(\.id)
            model.setRoom(room, on: true)
            await wait(2000)
            let afterOn = (try? await client.fetchLights()) ?? []
            check(roomIDs.allSatisfy { id in afterOn.first { $0.id == id }?.on.on == true },
                  "\(room.title): switch on → every lamp in the room is on")
            model.setRoom(model.sections.first { $0.id == room.id }!, on: false)
            await wait(2000)
            let afterOff = (try? await client.fetchLights()) ?? []
            check(roomIDs.allSatisfy { id in afterOff.first { $0.id == id }?.on.on == false },
                  "\(room.title): switch off → every lamp in the room is off")
            let others = afterOff.filter { !roomIDs.contains($0.id) }
            check(others.allSatisfy { saved[$0.id]?.on == $0.on.on }, "lamps in other rooms untouched")
            await restore(client, saved.filter { roomIDs.contains($0.key) })
        } else {
            say("  (skipped: the test lamp isn't in a Hue room)")
        }

        // 6. Timer on the bridge (created and removed; never fires).
        say("\n6. Bridge timer")
        if let id = try? await client.scheduleAllOff(after: 600) {
            check(true, "timer created on the bridge (id \(id))")
            check((try? await client.scheduleExists(id: id)) == true, "bridge confirms the timer exists")
            try? await client.cancelSchedule(id: id)
            check((try? await client.scheduleExists(id: id)) == false, "timer removed again")
        } else { check(false, "timer created on the bridge") }

        // 7. All off — the reported bug: does any lamp turn back on?
        say("\n7. All off")
        let wasOn = saved.filter { $0.value.on }.map(\.key)
        say("  lamps on before: \(wasOn.compactMap { model.lamps[$0]?.hueName }.sorted().joined(separator: ", "))")
        events.removeAll()
        let sentBefore = Date()
        model.allOffNow()
        await wait(8000)
        let after = (try? await client.fetchLights()) ?? []
        let stillOn = after.filter(\.on.on).map(\.metadata.name)
        check(stillOn.isEmpty, stillOn.isEmpty ? "every lamp is off 8 s later" : "still on 8 s later: \(stillOn.joined(separator: ", "))")
        let turnedOn = events.filter { $0.2 == true && $0.0 > sentBefore }.map { model.lamps[$0.1]?.hueName ?? $0.1 }
        check(turnedOn.isEmpty, turnedOn.isEmpty ? "no lamp switched on during or after All off"
                                                : "lamps that switched ON: \(Set(turnedOn).sorted().joined(separator: ", "))")
        check(model.lamps.values.allSatisfy { !$0.isOn }, "tiles all show off")

        // 8. What a bridge timer does when it fires (v1 group 0, no fade).
        say("\n8. Timer command (v1, as the bridge runs it)")
        await restore(client, saved)
        await wait(2500)
        events.removeAll()
        let timerStart = Date()
        do { try await client.allOffV1(); check(true, "timer command accepted") }
        catch { check(false, "timer command accepted: \(Log.describe(error))") }
        await wait(8000)
        let afterTimer = (try? await client.fetchLights()) ?? []
        let onAfterTimer = afterTimer.filter(\.on.on).map(\.metadata.name)
        check(onAfterTimer.isEmpty, onAfterTimer.isEmpty ? "every lamp is off 8 s later" : "still on: \(onAfterTimer.joined(separator: ", "))")
        let timerOn = events.filter { $0.2 == true && $0.0 > timerStart }.map { model.lamps[$0.1]?.hueName ?? $0.1 }
        check(timerOn.isEmpty, timerOn.isEmpty ? "no lamp switched on" : "lamps that switched ON: \(Set(timerOn).sorted().joined(separator: ", "))")

        // Put everything back exactly as it was.
        say("\nRestoring every lamp to its previous state")
        await restore(client, saved)
        await wait(2000)
        let final = (try? await client.fetchLights()) ?? []
        let mismatched = final.filter { saved[$0.id]?.on != $0.on.on }.map(\.metadata.name)
        check(mismatched.isEmpty, mismatched.isEmpty ? "all lamps restored (on/off)" : "not restored: \(mismatched.joined(separator: ", "))")

        stream.cancel()
        client.invalidate()
        say("\nLIVE TEST: \(passed) passed, \(failed.count) failed")
        failed.forEach { say("  FAIL \($0)") }
        return failed.isEmpty ? 0 : 1
    }

    private static func describe(_ c: LampCapability) -> String {
        switch c {
        case .color: "color"
        case .whites: "white ambiance"
        case .single: "single color"
        }
    }

    private static func bridgeState(_ client: HueClient, _ id: String) async -> HueLightResource? {
        try? await client.fetchLights().first { $0.id == id }
    }

    private static func restore(_ client: HueClient, _ states: [String: Saved]) async {
        for (id, s) in states {
            if s.on {
                try? await client.setLight(id: id, on: true, brightness: s.brightness,
                                           xy: s.xy.map { (x: $0.0, y: $0.1) }, mirek: s.mirek)
            } else {
                try? await client.setLight(id: id, on: false)
            }
            await wait(120)      // stay well under the bridge's rate limit
        }
    }
}
