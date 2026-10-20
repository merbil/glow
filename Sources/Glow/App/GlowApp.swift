import AppKit
import SwiftUI

@main
enum Launcher {
    /// `--snapshot <file.png> [--light] [--timer]` renders the popover with demo data and exits.
    /// `--menu-shot <file.png> <lamp>` captures the real right-click menu.
    /// `--selftest` (debug builds) runs the built-in tests.
    /// `--install-update <dmg> <version>` and `--print-version <file>` (debug builds) are for the update test.
    /// `--demo` runs the real menu bar app with sample lamps (no bridge needed).
    static func main() {
        let args = CommandLine.arguments
        // Diagnostic modes that use the real key or Glow's network permission are for development:
        // in release builds they need `defaults write com.merterbil.glow enableTestHooks -bool YES`.
        #if DEBUG
        let diagnosticsAllowed = true
        #else
        let diagnosticsAllowed = UserDefaults.standard.bool(forKey: "enableTestHooks")
        #endif
        if !diagnosticsAllowed, args.contains("--e2e") || args.contains("--diagnose") {
            print("Diagnostics are disabled. Enable with: defaults write com.merterbil.glow enableTestHooks -bool YES")
            exit(2)
        }
        if args.contains("--e2e") {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                Task { @MainActor in exit(await LiveTest.run()) }
                NSApplication.shared.run()
            }
            return
        }
        if let i = args.firstIndex(of: "--diagnose"), i + 1 < args.count {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                Task { @MainActor in exit(await Diagnostics.run(host: args[i + 1])) }
                NSApplication.shared.run()
            }
            return
        }
        #if !DEBUG
        if args.contains("--selftest") {
            print("--selftest is only available in debug builds: swift build && .build/debug/Glow --selftest")
            exit(2)
        }
        #else
        if let i = args.firstIndex(of: "--print-version"), i + 1 < args.count {
            // Used by the update test: the relauncher runs the new app this way, with no UI.
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            exit((try? version.write(toFile: args[i + 1], atomically: true, encoding: .utf8)) == nil ? 1 : 0)
        }
        if let i = args.firstIndex(of: "--install-update"), i + 2 < args.count {
            // Update pipeline against this bundle with a local DMG (scripts/test-self-update.sh). No model, no UI.
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let (dmg, version) = (URL(fileURLWithPath: args[i + 1]), args[i + 2])
                Task { @MainActor in exit(await UpdateInstaller.testInstall(dmg: dmg, version: version)) }
                NSApplication.shared.run()
            }
            return
        }
        if let i = args.firstIndex(of: "--try-key"), i + 2 < args.count {
            // Runs the real "use an existing key" flow against a real bridge, with throwaway
            // settings and the test Keychain, so the installed app is never affected.
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let (host, key) = (args[i + 1], args[i + 2])
                Task { @MainActor in
                    let model = AppModel(demo: false, preferences: .scratch(), keyStore: .selfTest)
                    model.discover = { [] }
                    model.useExistingKey(host: host, key: key)
                    for _ in 0..<40 where !model.isPaired {
                        if case .failed = model.onboarding { break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    if model.isPaired {
                        _ = await model.refresh()
                        print("KEY ACCEPTED. \(model.lamps.count) lamps in \(model.sections.count) groups:")
                        for section in model.sections {
                            print("  \(section.title): " + section.lamps.map {
                                "\($0.hueName) (\($0.isOn ? "on" : "off"), \($0.capability))" }.joined(separator: ", "))
                        }
                    } else {
                        print("KEY NOT ACCEPTED: \(model.onboarding)")
                    }
                    model.forgetBridge()
                    KeyStore.selfTest.delete("appKey")
                    exit(model.isPaired ? 0 : 1)
                }
                NSApplication.shared.run()
            }
            return
        }
        if let i = args.firstIndex(of: "--tutorial-frames"), i + 1 < args.count {
            MainActor.assumeIsolated { TutorialFrames.render(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            MainActor.assumeIsolated { IconRenderer.render(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if args.contains("--pentest") {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                Task { @MainActor in exit(await PenTest.run()) }
                NSApplication.shared.run()
            }
            return
        }
        if args.contains("--selftest") {
            // AppKit needs the real main thread, so run a normal app run loop (no UI).
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                Task { @MainActor in exit(await SelfTest.run()) }
                NSApplication.shared.run()
            }
            return
        }
        #endif
        if let i = args.firstIndex(of: "--menu-shot"), i + 2 < args.count {
            MainActor.assumeIsolated {
                Snapshot.menuShot(to: URL(fileURLWithPath: args[i + 1]), lampName: args[i + 2])
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated {
                Snapshot.render(to: URL(fileURLWithPath: args[i + 1]))
            }
            return
        }
        GlowApp.main()
    }
}

struct GlowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel

    init() {
        Preferences.migrateFromOldBundleID()
        let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
        model.start()
        AppDelegate.model = model
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            Image(systemName: model.anyOn ? "lightbulb.fill" : "lightbulb")
                .accessibilityLabel("Glow")
        }
        .menuBarExtraStyle(.window)

        Window("Glow Settings", id: "settings") {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by GlowApp so the "show popover" hook can pick a page.
    @MainActor static weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when run as a bare executable during development.
        NSApp.setActivationPolicy(.accessory)
        AppDelegate.model?.applyAppearance()        // NSApp exists for sure now
        if AppDelegate.model?.isDemo == false { Updater.shared.start() }

        // Hook for screenshots/testing. Off unless enabled:
        //   defaults write com.merterbil.glow enableTestHooks -bool YES
        #if !DEBUG
        guard UserDefaults.standard.bool(forKey: "enableTestHooks") else { return }
        #endif
        // Hook for screenshots/testing: open the popover from the command line, optionally on a page
        // ("arrange", "settings" and "about" open the Settings window instead):
        //   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.merterbil.glow.show"), object: "arrange", userInfo: nil, deliverImmediately: true)'
        // It can only open Glow's own popover.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.merterbil.glow.show"), object: nil, queue: .main
        ) { note in
            let page = note.object as? String
            MainActor.assumeIsolated {
                switch page {
                case "settings": AppDelegate.model?.openSettings(.general); return
                case "arrange": AppDelegate.model?.openSettings(.arrange); return
                case "about": AppDelegate.model?.openSettings(.about); return
                case "forget": AppDelegate.model?.page = .confirmForget
                default: AppDelegate.model?.page = .lights
                }
                AppDelegate.togglePopover(open: true)
            }
        }
    }

    /// Clicks Glow's own menu bar item.
    @MainActor static func togglePopover(open: Bool) {
        let popoverVisible = NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtraWindow") }
        guard open != popoverVisible else { return }
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = window.contentView?.subviews.compactMap({ $0 as? NSStatusBarButton }).first
                ?? findButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    @MainActor private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = findButton(in: sub) { return found } }
        return nil
    }
}
