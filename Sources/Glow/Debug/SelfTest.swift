#if DEBUG
import AppKit
import Foundation

/// Lightweight test runner (XCTest isn't available without Xcode).
///   swift build && .build/debug/Glow --selftest
@MainActor
enum SelfTest {
    private static var passed = 0
    private static var failures: [String] = []

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                              line: Int = #line) {
        if condition() { passed += 1 } else { failures.append("line \(line): \(message)") }
    }

    static func run() async -> Int32 {
        colorTests()
        paletteTests()
        decodingTests()
        demoModelTests()
        menuTests()
        formatTests()
        keyStoreTests()
        arrangeTests()
        releaseNotesTests()
        updaterTests()
        trustTests()
        await MockBridgeTests.run()

        print("Self-test: \(passed) passed, \(failures.count) failed")
        failures.forEach { print("  FAIL \($0)") }
        return failures.isEmpty ? 0 : 1
    }

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        check(condition, message, line: line)
    }

    // MARK: Colors & contrast

    private static func colorTests() {
        let ink = HueColor.RGB.ink
        var tints: [(String, HueColor.RGB)] = ColorPalette.colors.map { ($0.name, $0.rgb) }
        tints += [153, 200, 250, 300, 370, 454, 500].map { ("mirek \($0)", HueColor.fromMirek($0)) }
        tints.append(("default warm", HueColor.defaultWarm))

        for (name, tint) in tints {
            let start = tint.readableBehindInk()
            let end = tint.mixed(with: .white, 0.45).readableBehindInk()
            let unlit = end.mixed(with: .slate, 0.38).readableBehindInk()
            for (part, bg) in [("fill start", start), ("fill end", end), ("unlit", unlit)] {
                check(ink.contrast(with: bg) >= 4.5, "\(name) \(part): name contrast \(ink.contrast(with: bg))")
                let secondary = bg.mixed(with: ink, 0.72)
                check(secondary.contrast(with: bg) >= 4.5,
                      "\(name) \(part): % contrast \(secondary.contrast(with: bg))")
            }
        }

        // xy round trip keeps the color (compared after normalizing to peak 1).
        for swatch in ColorPalette.colors {
            let back = HueColor.fromXY(x: swatch.xy.x, y: swatch.xy.y)
            let peak = max(swatch.rgb.r, swatch.rgb.g, swatch.rgb.b)
            let diff = max(abs(back.r - swatch.rgb.r / peak), abs(back.g - swatch.rgb.g / peak),
                           abs(back.b - swatch.rgb.b / peak))
            check(diff < 0.08, "\(swatch.name) xy round trip off by \(diff)")
        }

        let cool = HueColor.fromMirek(153)
        check(cool.r > 0.95 && cool.g > 0.95 && cool.b > 0.95, "6500K should be near white: \(cool)")
        let candle = HueColor.fromMirek(500)
        check(candle.r == 1 && candle.b < 0.45, "2000K should be orange: \(candle)")
        check(HueColor.fromXY(x: 0.3, y: 0) == HueColor.defaultWarm, "y=0 must not crash / divide by zero")
    }

    // MARK: Palette

    private static func paletteTests() {
        check(ColorPalette.colors.count == 16, "16 colors")
        check(Set(ColorPalette.colors.map(\.id)).count == 16, "color ids unique")

        for swatch in ColorPalette.colors {
            var lamp = demoLamp(capability: .color(whites: 153...500))
            lamp.xy = swatch.xy
            check(ColorPalette.selectedColor(for: lamp) == swatch,
                  "\(swatch.name) should select itself, got \(ColorPalette.selectedColor(for: lamp)?.name ?? "nil")")
        }
        var whiteLamp = demoLamp(capability: .whites(153...454))
        for white in ColorPalette.whites {
            whiteLamp.mirek = white.mirek
            check(ColorPalette.selectedWhite(for: whiteLamp)?.id == white.id, "\(white.name) should select itself")
        }
        whiteLamp.mirek = nil
        check(ColorPalette.selectedWhite(for: whiteLamp) == nil, "no mirek → no white selected")

        let clamped = ColorPalette.whites(for: 200...400)
        check(clamped.allSatisfy { (200...400).contains($0.mirek) || abs($0.mirek - 200) <= 1 || abs($0.mirek - 400) <= 1 },
              "whites clamp to lamp range: \(clamped.map(\.mirek))")
    }

    // MARK: Decoding real bridge payloads

    private static func decodingTests() {
        let lights = """
        {"errors":[],"data":[
         {"id":"c1","type":"light","owner":{"rid":"d1","rtype":"device"},"metadata":{"name":"Corner","archetype":"sultan_bulb"},
          "on":{"on":true},"dimming":{"brightness":40.5,"min_dim_level":0.2},
          "color_temperature":{"mirek":null,"mirek_valid":false,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}},
          "color":{"xy":{"x":0.22,"y":0.12},"gamut":{"red":{"x":0.68,"y":0.31},"green":{"x":0.17,"y":0.7},"blue":{"x":0.15,"y":0.06}},"gamut_type":"C"},
          "mode":"normal"},
         {"id":"a1","type":"light","owner":{"rid":"d2","rtype":"device"},"metadata":{"name":"Floor","archetype":"floor_shade"},
          "on":{"on":false},"dimming":{"brightness":70.0},
          "color_temperature":{"mirek":370,"mirek_valid":true,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":454}},
          "mode":"normal"},
         {"id":"w1","type":"light","owner":{"rid":"d3","rtype":"device"},"metadata":{"name":"Hallway","archetype":"classic_bulb"},
          "on":{"on":true},"dimming":{"brightness":25.0},"mode":"normal"}
        ]}
        """
        do {
            let decoded = try JSONDecoder().decode(HueResponse<HueLightResource>.self, from: Data(lights.utf8)).data
            check(decoded.count == 3, "3 lights decoded")
            let caps = decoded.map(AppModel.capability(of:))
            check(caps[0] == .color(whites: 153...500), "color lamp capability: \(caps[0])")
            check(caps[1] == .whites(153...454), "ambiance capability: \(caps[1])")
            check(caps[2] == .single, "white-only capability: \(caps[2])")
            check(decoded[0].dimming?.brightness == 40.5, "brightness decoded")
        } catch {
            check(false, "light decoding threw \(error)")
        }

        let rooms = """
        {"errors":[],"data":[{"id":"r1","type":"room","metadata":{"name":"Living Room","archetype":"living_room"},
          "children":[{"rid":"d1","rtype":"device"},{"rid":"d2","rtype":"device"}],
          "services":[{"rid":"g1","rtype":"grouped_light"}]}]}
        """
        let decodedRooms = try? JSONDecoder().decode(HueResponse<HueRoomResource>.self, from: Data(rooms.utf8)).data
        check(decodedRooms?.first?.children.count == 2, "room children decoded")

        let events = """
        [{"creationtime":"2026-10-19T10:00:00Z","data":[
          {"id":"c1","id_v1":"/lights/3","on":{"on":false},"owner":{"rid":"d1","rtype":"device"},"type":"light"},
          {"id":"z1","owner":{"rid":"d3","rtype":"device"},"status":"connectivity_issue","type":"zigbee_connectivity"},
          {"id":"c1","dimming":{"brightness":12.0},"type":"light"}],
          "id":"e1","type":"update"}]
        """
        do {
            let batch = try JSONDecoder().decode([HueEvent].self, from: Data(events.utf8))
            check(batch.first?.data.count == 3, "event items decoded")
            check(batch.first?.data[1].status == "connectivity_issue", "connectivity status decoded")
        } catch {
            check(false, "event decoding threw \(error)")
        }
    }

    // MARK: Demo model behaviour

    private static func demoModelTests() {
        let model = AppModel(demo: true)
        check(model.isPaired && model.connection == .live, "demo is paired and live")
        check(model.visibleLampCount == 13, "13 demo lamps, got \(model.visibleLampCount)")
        check(model.onCount == 5, "5 lamps on, got \(model.onCount)")
        check(model.sections.map(\.title) == ["Bedroom", "Living Room", "Office", "Other"],
              "sections: \(model.sections.map(\.title))")
        check(model.sections.last?.lamps.map(\.hueName) == ["Balcony", "Hallway", "Kitchen"], "Other sorted")

        let ceiling = model.lamps["2"]!          // living room, off, ambiance
        model.toggle(ceiling)
        check(model.lamps["2"]!.isOn, "toggle turns on")
        model.toggle(model.lamps["2"]!)
        check(!model.lamps["2"]!.isOn, "toggle turns off")

        model.setBrightness(ceiling, to: 55)
        check(model.lamps["2"]!.isOn && model.lamps["2"]!.brightness == 55, "drag sets 55% and turns on")
        model.setBrightness(model.lamps["2"]!, to: 0)
        check(!model.lamps["2"]!.isOn, "drag to 0 turns off")
        check(model.lamps["2"]!.brightness == 55, "off keeps last brightness")
        model.setBrightness(model.lamps["2"]!, to: 140)
        check(model.lamps["2"]!.brightness == 100, "brightness clamps at 100")

        let balcony = model.lamps["13"]!         // unreachable
        model.toggle(balcony)
        model.setBrightness(balcony, to: 50)
        check(!model.lamps["13"]!.isOn, "unreachable lamp ignores commands")

        let blue = ColorPalette.colors.first { $0.name == "Blue" }!
        model.setColor(model.lamps["1"]!, blue)    // Floor is ambiance
        check(model.lamps["1"]!.mirek == 370, "ambiance lamp ignores colors")
        model.setColor(model.lamps["3"]!, blue)    // Corner is color
        check(model.lamps["3"]!.mirek == nil && ColorPalette.selectedColor(for: model.lamps["3"]!) == blue,
              "color lamp takes the color")
        let warm = ColorPalette.whites[0]
        model.setWhite(model.lamps["3"]!, warm)
        check(model.lamps["3"]!.mirek == warm.mirek, "color lamp takes a white")
        model.setWhite(model.lamps["11"]!, warm)   // Hallway is single
        check(model.lamps["11"]!.mirek == nil, "single-color lamp ignores whites")
        model.setColor(model.lamps["6"]!, blue)    // Shelf: off color lamp
        check(model.lamps["6"]!.isOn, "picking a color turns the lamp on")

        let desk = model.lamps["5"]!
        model.rename(desk, to: "  Work Lamp ")
        check(model.displayName(desk) == "Work Lamp", "rename trims")
        model.rename(desk, to: "")
        check(model.displayName(desk) == "Desk", "empty rename restores Hue name")

        model.hide(desk)
        check(model.visibleLampCount == 12 && !model.sections.flatMap(\.lamps).contains { $0.id == "5" },
              "hidden lamp leaves the list")
        model.unhideAll()
        check(model.visibleLampCount == 13, "unhide brings it back")

        model.scheduleAllOff(minutes: 5)
        if let date = model.timerFireDate {
            check(abs(date.timeIntervalSinceNow - 300) < 2, "timer ~5 min")
        } else {
            check(false, "timer set")
        }
        model.cancelTimer()
        check(model.timerFireDate == nil, "timer cancelled")

        model.allOffNow()
        check(!model.anyOn && model.onCount == 0, "all off")
    }

    // MARK: Right-click menu

    private static func menuTests() {
        var fired: [String] = []
        func menu(_ cap: LampCapability) -> NSMenu {
            LampMenu.make(lamp: demoLamp(capability: cap), onColor: { fired.append($0.name) },
                          onWhite: { fired.append($0.name) },
                          onRename: { fired.append("rename") }, onHide: { fired.append("hide") })
        }
        let color = menu(.color(whites: 153...500))
        check(color.items.count == 4 && color.items[0].view != nil && color.items[1].isSeparatorItem,
              "color lamp menu: colors, separator, rename, hide")
        check(menu(.whites(153...454)).items.count == 4, "ambiance lamp menu has the whites section")
        let single = menu(.single)
        check(single.items.count == 4 && single.items[0].title == LampMenu.singleColorNote
              && !single.items[0].isEnabled && single.items[1].isSeparatorItem
              && single.items.suffix(2).map(\.title) == ["Rename in Glow…", "Hide from Glow"],
              "single lamp: a disabled one-color note, separator, rename, hide")

        for item in single.items where item.action != nil { _ = (item.target as AnyObject?)?.perform(item.action) }
        check(fired == ["rename", "hide"], "menu items run their actions: \(fired)")

        let height = color.items[0].view?.frame.height ?? 0
        check(height > 60 && height < 160, "color section has a sensible height: \(height)")
    }

    // MARK: Arrange & hide, room switch, appearance (0.2.0)

    private static func arrangeTests() {
        let model = AppModel(demo: true)
        let titles = { model.sections.map(\.title) }
        check(titles() == ["Bedroom", "Living Room", "Office", "Other"], "default room order: \(titles())")

        model.moveRoom("office", to: "bedroom")
        check(titles() == ["Office", "Bedroom", "Living Room", "Other"], "room moved to the top: \(titles())")
        model.moveRoom("other", to: "bedroom")
        check(titles() == ["Office", "Other", "Bedroom", "Living Room"], "Other can move too: \(titles())")

        let living = { model.sections.first { $0.id == "living" }!.lamps.map(\.hueName) }
        check(living() == ["Ceiling", "Corner", "Floor", "TV Strip"], "default lamp order by name")
        model.moveLamp("4", to: "2")          // TV Strip to the front
        check(living() == ["TV Strip", "Ceiling", "Corner", "Floor"], "lamp moved to the front: \(living())")
        model.moveLamp("4", to: "8")          // across rooms: ignored
        check(living().first == "TV Strip", "a lamp can't be moved into another room")
        check(model.sections.first { $0.id == "office" }!.lamps.count == 3, "other rooms unchanged")

        model.setRoomHidden("bedroom", true)
        check(!titles().contains("Bedroom"), "hidden room leaves the lights page")
        check(model.sections(includeHidden: true).contains { $0.id == "bedroom" && $0.isHidden }, "…but shows in Arrange & Hide")
        check(model.visibleLampCount == 10, "counts skip the hidden room: \(model.visibleLampCount)")
        let lamp = model.lamps["3"]!
        model.setLampHidden(lamp, true)
        check(!living().contains("Corner") && model.hiddenCount == 2, "hidden lamp + room counted")
        model.setLampHidden(lamp, false)
        check(living().contains("Corner"), "lamp shown again")
        model.unhideAll()
        check(titles().contains("Bedroom") && model.hiddenCount == 0, "Show All brings everything back")

        model.resetArrangement()
        check(titles() == ["Bedroom", "Living Room", "Office", "Other"], "reset order")

        // Settings window: list-style drag of lamps, ↑/↓ for rooms.
        model.moveLamps(in: "living", from: IndexSet(integer: 3), to: 0)   // TV Strip to the top
        check(living() == ["TV Strip", "Ceiling", "Corner", "Floor"], "drag lamp to the top: \(living())")
        model.moveLamps(in: "living", from: IndexSet(integer: 0), to: 4)   // and to the bottom
        check(living() == ["Ceiling", "Corner", "Floor", "TV Strip"], "drag lamp to the bottom: \(living())")
        model.moveRoom("office", by: -1)
        check(titles() == ["Bedroom", "Office", "Living Room", "Other"], "room ↑: \(titles())")
        model.moveRoom("bedroom", by: -1)
        check(titles().first == "Bedroom", "first room can't go further up")
        model.moveRoom("other", by: 1)
        check(titles().last == "Other", "last room can't go further down")
        model.resetArrangement()

        // Room switch: the whole room, reachable lamps only.
        let office = model.sections.first { $0.id == "office" }!
        model.setRoom(office, on: true)
        check(model.sections.first { $0.id == "office" }!.lamps.allSatisfy(\.isOn), "room switch turns the room on")
        check(model.sections.first { $0.id == "living" }!.lamps.contains { !$0.isOn }, "other rooms untouched")
        model.setRoom(model.sections.first { $0.id == "office" }!, on: false)
        check(!model.sections.first { $0.id == "office" }!.anyOn, "room switch turns the room off")
        let other = model.sections.first { $0.id == "other" }!
        model.setRoom(other, on: true)
        check(model.lamps["13"]?.isOn == false, "unreachable lamp isn't switched")

        // Review fixes: the room switch reflects the whole room, hidden lamps included.
        let livingSection = model.sections.first { $0.id == "living" }!
        model.setRoom(livingSection, on: false)
        model.setLampHidden(model.lamps["3"]!, true)            // hide Corner…
        model.toggle(model.lamps["3"]!)                         // …and turn it on
        check(model.sections.first { $0.id == "living" }!.anyOn, "switch shows on while a hidden lamp is on")
        model.setRoom(model.sections.first { $0.id == "living" }!, on: false)
        check(model.lamps["3"]?.isOn == false, "switching the room off also turns off the hidden lamp")
        model.setLampHidden(model.lamps["3"]!, false)
        // Hidden ids of things no longer on the bridge aren't counted.
        let stalePrefs = Preferences.scratch()
        stalePrefs.hiddenLampIDs = ["gone-lamp"]
        stalePrefs.hiddenRoomIDs = ["gone-room"]
        check(AppModel(demo: true, preferences: stalePrefs).hiddenCount == 0, "deleted lamps/rooms aren't counted as hidden")
        // Upgrading from 0.1.x (paired, but no "last seen version" yet) shows the banner.
        let upgrader = Preferences.scratch()
        upgrader.bridgeHost = "10.0.0.2"
        check(AppModel(demo: false, preferences: upgrader, keyStore: .selfTest).hasUnseenUpdate, "banner for 0.1.x upgraders")

        // Appearance is remembered.
        let prefs = Preferences.scratch()
        let a = AppModel(demo: false, preferences: prefs, keyStore: .selfTest)
        a.setAppearance(.dark)
        check(AppModel(demo: false, preferences: prefs, keyStore: .selfTest).appearance == .dark, "appearance persists")
        a.setAppearance(.system)

        // Update banner: new install → none; version change → shown once.
        let fresh = Preferences.scratch()
        check(!AppModel(demo: false, preferences: fresh, keyStore: .selfTest).hasUnseenUpdate, "no banner on first install")
        fresh.lastSeenVersion = "0.0.1"
        let updated = AppModel(demo: false, preferences: fresh, keyStore: .selfTest)
        check(updated.hasUnseenUpdate, "banner after an update")
        updated.markUpdateSeen()
        check(!AppModel(demo: false, preferences: fresh, keyStore: .selfTest).hasUnseenUpdate, "banner gone once seen")
    }

    private static func releaseNotesTests() {
        let notes = ReleaseNotes.load()
        check(notes.count >= 3, "release notes found: \(notes.count) versions")
        check(notes.first?.version.first?.isNumber == true, "newest version first: \(notes.first?.version ?? "-")")
        check(notes.allSatisfy { !$0.lines.isEmpty }, "every version has notes")
        let parsed = ReleaseNotes.parse("# T\n\n## 9.9 (build 1): x\n### Fixed\n- **a** b\nplain\n")
        check(parsed.count == 1 && parsed[0].version == "9.9" && parsed[0].lines.count == 3, "parser handles headings, bullets, text")
    }

    // MARK: Auto-update (0.3.3)

    private static func updaterTests() {
        func answer(tag: String, dmg: String = "https://github.com/merbil/glow/releases/download/v0.3.4/Glow-0.3.4.dmg",
                    prerelease: Bool = false) -> Data {
            Data("""
            {"tag_name":"\(tag)","draft":false,"prerelease":\(prerelease),"html_url":"https://github.com/merbil/glow/releases/tag/\(tag)",
             "assets":[{"name":"notes.txt","browser_download_url":"https://github.com/merbil/glow/releases/download/\(tag)/notes.txt"},
                       {"name":"Glow.dmg","browser_download_url":"\(dmg)"}]}
            """.utf8)
        }
        let release = Updater.parse(answer(tag: "v0.3.4"))
        check(release?.version == "0.3.4" && release?.downloadURL.lastPathComponent == "Glow-0.3.4.dmg",
              "update: reads the version and the DMG from GitHub's answer")
        check(Updater.parse(answer(tag: "v0.3.4", prerelease: true)) == nil, "update: ignores pre-releases")
        check(Updater.parse(answer(tag: "v0.3.4", dmg: "https://evil.example/Glow.dmg")) == nil,
              "update: refuses a download outside Glow's GitHub releases")
        check(Updater.parse(answer(tag: "v0.3.4", dmg: "http://github.com/merbil/glow/releases/download/v0.3.4/Glow.dmg")) == nil,
              "update: refuses a download over plain HTTP")
        check(Updater.parse(answer(tag: "v1.0<script>")) == nil, "update: refuses a strange version tag")
        check(Updater.parse(Data("not json".utf8)) == nil, "update: survives a broken answer")
        check(Updater.isNewer("0.3.10", than: "0.3.9") && Updater.isNewer("1.0", than: "0.9.9")
              && !Updater.isNewer("0.3.3", than: "0.3.3") && !Updater.isNewer("0.3", than: "0.3.0"),
              "update: compares versions number by number")
        Updater.shared.start()      // this binary is not in a .app, so the guard must keep it off
        check(!Updater.shared.isRunning, "update: no checks outside the app bundle (tests, demo)")

        // The download must be exactly this version's DMG in Glow's own releases.
        let base = "https://github.com/merbil/glow/releases/download"
        func allowed(_ url: String, _ version: String = "0.3.4") -> Bool {
            URL(string: url).map { Updater.isAllowedDownload($0, version: version) } ?? false
        }
        check(allowed("\(base)/v0.3.4/Glow-0.3.4.dmg"), "update: the real URL shape passes")
        let bad = [
            "\(base)/../../../../attacker/repo/releases/download/v0.3.4/Glow.dmg": "dot segments",
            "\(base)/%2e%2e/%2e%2e/attacker/repo/releases/download/v0.3.4/Glow.dmg": "%2e%2e",
            "\(base)/..%2f..%2fattacker/repo/releases/download/v0.3.4/Glow.dmg": "..%2f",
            "\(base)/v0.3.4/%2E%2E%2FGlow.dmg": "%2E and %2F",
            "\(base)/v0.3.4\\Glow.dmg": "backslash",
            "https://github.com:8443/merbil/glow/releases/download/v0.3.4/Glow.dmg": "port",
            "https://evil@github.com/merbil/glow/releases/download/v0.3.4/Glow.dmg": "user",
            "https://evil:pw@github.com/merbil/glow/releases/download/v0.3.4/Glow.dmg": "user and password",
            "\(base)/v0.3.4/Glow.dmg?x=1": "query",
            "\(base)/v0.3.4/Glow.dmg#frag": "fragment",
            "\(base)/v0.3.5/Glow.dmg": "tag that is not this version",
            "\(base)/0.3.4/Glow.dmg": "tag without the v",
            "\(base)/v0.3.4/Glow.zip": "not a DMG",
            "\(base)/v0.3.4/sub/Glow.dmg": "extra path segment",
            "\(base)/v0.3.4": "missing file",
            "https://github.com/other/glow/releases/download/v0.3.4/Glow.dmg": "other owner",
            "https://GITHUB.COM/merbil/glow/releases/download/v0.3.4/Glow.dmg": "other host spelling",
            "http://github.com/merbil/glow/releases/download/v0.3.4/Glow.dmg": "plain HTTP",
        ]
        for (url, why) in bad { check(!allowed(url), "update: refuses \(why)") }

        // Versions: ASCII digits, one to four numbers, no empty parts, at most 32 characters.
        for good in ["0", "1.2", "0.3.4", "1.2.3.4"] { check(Updater.isValidVersion(good), "version \(good) is valid") }
        for evil in ["", "1..2", ".1", "1.", "1.2.3.4.5", "٣.1", "½", "Ⅻ", "1.0-rc1", "1.0<script>", "v1.0", " 1.0",
                     String(repeating: "1", count: 33)] {
            check(!Updater.isValidVersion(evil), "version \(evil.prefix(12).debugDescription) is refused")
        }
        check(Updater.isNewer("0.3.0", than: "0.3") == false && Updater.isNewer("0.3.1", than: "0.3")
              && !Updater.isNewer("0.3", than: "0.3.1"), "update: versions of unequal length compare")

        // An answer that can't be used is a failed check (retried within the hour), not "up to date".
        let suite = "com.merterbil.glow.scratch.updater"
        UserDefaults().removePersistentDomain(forName: suite)
        let scratch = UserDefaults(suiteName: suite)!
        let updater = Updater(defaults: scratch)
        check(updater.automaticChecks && updater.state == .idle, "update: new setup checks automatically, nothing known yet")
        updater.finish(with: Data(#"{"tag_name":"v9.9.9","assets":[{"name":"notes.txt","browser_download_url":"\#(base)/v9.9.9/notes.txt"}]}"#.utf8))
        check(updater.state == .failed && scratch.object(forKey: "lastUpdateCheck") == nil, "update: a release without a DMG is a failure")
        updater.finish(with: Data("not json".utf8))
        check(updater.state == .failed && scratch.object(forKey: "lastUpdateCheck") == nil, "update: an unparseable answer is a failure")

        // A found release survives a restart and a failed check; it is checked again when loaded.
        updater.finish(with: answer(tag: "v9.9.9", dmg: "\(base)/v9.9.9/Glow-9.9.9.dmg"))
        check(updater.available?.version == "9.9.9" && scratch.object(forKey: "lastUpdateCheck") != nil, "update: newer release is kept")
        updater.finish(with: Data("not json".utf8))
        check(updater.state == .failed && updater.available?.version == "9.9.9", "update: a failed check doesn't hide it")
        check(Updater(defaults: scratch).available?.version == "9.9.9", "update: remembered across a relaunch")
        scratch.set("\(base)/../../../x/y/releases/download/v9.9.9/Glow.dmg", forKey: "latestReleaseURL")
        check(Updater(defaults: scratch).available == nil, "update: a tampered remembered URL is refused")
        scratch.set("\(base)/v9.9.9/Glow-9.9.9.dmg", forKey: "latestReleaseURL")
        scratch.set("0.0.1", forKey: "latestReleaseVersion")
        check(Updater(defaults: scratch).available == nil, "update: a remembered release that isn't newer is dropped")
        UserDefaults().removePersistentDomain(forName: suite)

        // The setting, and when a check is due. A last check in the future counts as due.
        let now = Date()
        check(Updater.isDue(last: nil, now: now) && !Updater.isDue(last: now.addingTimeInterval(-3600), now: now)
              && Updater.isDue(last: now.addingTimeInterval(-90_000), now: now), "update: due after a day")
        check(Updater.isDue(last: now.addingTimeInterval(86_400 * 400), now: now), "update: a last check in the future is due")
        let off = Updater(defaults: scratch)
        off.automaticChecks = false
        check(scratch.object(forKey: "autoUpdateCheck") as? Bool == false && !Updater(defaults: scratch).automaticChecks,
              "update: the automatic setting is remembered")
        UserDefaults().removePersistentDomain(forName: suite)
        check(Updater.latestReleaseURL.path == "/repositories/\(Updater.repositoryID)/releases/latest",
              "update: asks for the release by repository ID")
    }

    // MARK: Bridge trust

    /// Stands in for the URL loading system, which is what normally supplies a challenge's sender.
    private final class NoSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private static func trustTests() {
        func disposition(host: String, expecting: String?) -> URLSession.AuthChallengeDisposition? {
            let trust = BridgeTrust(host: expecting, pinnedFingerprint: nil)
            let space = URLProtectionSpace(host: host, port: 443, protocol: "https", realm: nil,
                                           authenticationMethod: NSURLAuthenticationMethodServerTrust)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                       failureResponse: nil, error: nil, sender: NoSender())
            var result: URLSession.AuthChallengeDisposition?
            trust.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in result = disposition }
            return result
        }
        check(disposition(host: "evil.example", expecting: "192.168.1.20") == .cancelAuthenticationChallenge,
              "trust: a challenge for another host is cancelled, never handed to the system")
        check(disposition(host: "192.168.1.20", expecting: nil) == .cancelAuthenticationChallenge,
              "trust: a client with no host cancels")
        check(disposition(host: "192.168.1.20", expecting: "192.168.1.20") == .cancelAuthenticationChallenge,
              "trust: the right host without a certificate is cancelled too")
    }

    // MARK: Key storage (no Keychain prompts)

    private static func keyStoreTests() {
        let store = KeyStore.selfTest
        store.delete("probe")
        check(!store.exists("probe") && store.get("probe") == nil, "empty store has no key")
        store.set("SECRET-123", for: "probe")
        check(store.get("probe") == "SECRET-123", "key round-trips through the file")
        let attrs = try? FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("probe").path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(perms == 0o600, "key file is private (600), got \(String(perms, radix: 8))")
        let dirAttrs = try? FileManager.default.attributesOfItem(atPath: store.directory.path)
        let dirPerms = (dirAttrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(dirPerms == 0o700, "key folder is private (700), got \(String(dirPerms, radix: 8))")
        store.set("SECRET-456", for: "probe")
        check(store.get("probe") == "SECRET-456", "overwriting keeps it private and updated")
        store.delete("probe")
        check(store.get("probe") == nil, "delete removes it")
    }

    // MARK: Countdown text

    private static func formatTests() {
        check(AllOffControl.format(300) == "5:00", "5:00")
        check(AllOffControl.format(299.2) == "5:00", "rounds up so it never shows 4:59 at start")
        check(AllOffControl.format(59) == "0:59", "0:59")
        check(AllOffControl.format(3600) == "1:00:00", "1:00:00")
        check(AllOffControl.format(-4) == "0:00", "never negative")
    }

    static func demoLamp(capability: LampCapability) -> Lamp {
        Lamp(id: "t", deviceID: "d", hueName: "Test", isOn: true, brightness: 50,
             xy: nil, mirek: nil, isReachable: true, capability: capability)
    }
}
#endif
