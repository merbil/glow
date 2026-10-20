import Foundation
import ServiceManagement

/// Non-secret settings, stored in UserDefaults.
/// Renames and hidden lamps live only in Glow and never touch the Hue setup.
struct Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Throwaway storage for demo mode, snapshots and the self-test,
    /// so they never touch the real app's settings (e.g. a pending bridge timer).
    static func scratch() -> Preferences {
        let name = "com.merterbil.glow.scratch"
        UserDefaults().removePersistentDomain(forName: name)
        return Preferences(defaults: UserDefaults(suiteName: name)!)
    }

    /// Glow 0.2.1 and earlier used the bundle id "app.glow.menubar". Copy those settings once,
    /// so an update doesn't ask to pair again or lose renames, order and hidden items.
    static func migrateFromOldBundleID() {
        let standard = UserDefaults.standard
        guard standard.object(forKey: "bridgeHost") == nil,
              !standard.bool(forKey: "migratedFromAppGlowMenubar"),
              let old = UserDefaults(suiteName: "app.glow.menubar")?.persistentDomain(forName: "app.glow.menubar"),
              !old.isEmpty else { return }
        for (key, value) in old where key != "enableTestHooks" { standard.set(value, forKey: key) }
        standard.set(true, forKey: "migratedFromAppGlowMenubar")
    }

    /// Only a host that passes the same check as a typed one: a changed value in the defaults can't
    /// point Glow (and the key) at another machine. An invalid one reads as "not paired".
    var bridgeHost: String? {
        get { defaults.string(forKey: "bridgeHost").flatMap { HostRules.isValidHost($0) ? $0 : nil } }
        nonmutating set { defaults.set(newValue, forKey: "bridgeHost") }
    }

    var bridgeID: String? {
        get { defaults.string(forKey: "bridgeID") }
        nonmutating set { defaults.set(newValue, forKey: "bridgeID") }
    }

    var certificateFingerprint: String? {
        get { defaults.string(forKey: "certificateFingerprint") }
        nonmutating set { defaults.set(newValue, forKey: "certificateFingerprint") }
    }

    var customNames: [String: String] {
        get { defaults.dictionary(forKey: "customNames") as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: "customNames") }
    }

    var hiddenLampIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenLampIDs") ?? []) }
        nonmutating set { defaults.set(Array(newValue), forKey: "hiddenLampIDs") }
    }

    var hiddenRoomIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenRoomIDs") ?? []) }
        nonmutating set { defaults.set(Array(newValue), forKey: "hiddenRoomIDs") }
    }

    /// Room ids in the order the user arranged them ("other" is the no-room section).
    var roomOrder: [String] {
        get { defaults.stringArray(forKey: "roomOrder") ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "roomOrder") }
    }

    /// Lamp ids in the order the user arranged them (one list; each room uses the relative order).
    var lampOrder: [String] {
        get { defaults.stringArray(forKey: "lampOrder") ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "lampOrder") }
    }

    /// "system", "light" or "dark".
    var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "system" }
        nonmutating set { defaults.set(newValue, forKey: "appearance") }
    }

    /// The last version the user has seen, to show "What's new" after an update.
    var lastSeenVersion: String? {
        get { defaults.string(forKey: "lastSeenVersion") }
        nonmutating set { defaults.set(newValue, forKey: "lastSeenVersion") }
    }

    /// The pending "all off" timer on the bridge, if any.
    var pendingTimer: (id: String, fireDate: Date)? {
        get {
            // The id goes into a bridge URL: digits only.
            guard let id = defaults.string(forKey: "timerID"), !id.isEmpty, id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let date = defaults.object(forKey: "timerFireDate") as? Date else { return nil }
            return (id, date)
        }
        nonmutating set {
            defaults.set(newValue?.id, forKey: "timerID")
            defaults.set(newValue?.fireDate, forKey: "timerFireDate")
        }
    }

    func forgetBridge() {
        for key in ["bridgeHost", "bridgeID", "certificateFingerprint", "timerID", "timerFireDate"] {
            defaults.removeObject(forKey: key)
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Glow: launch at login change failed: \(error)")
        }
    }
}
