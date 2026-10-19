import AppKit
import SwiftUI

/// Renders the UI with demo data to PNGs, for checking the design without a bridge:
///   Glow --snapshot out.png [--light] [--timer]
///   Glow --menu-shot out.png <Corner|Floor|Ceiling>   (real right-click menu, captured on screen)
@MainActor
enum Snapshot {
    static func render(to url: URL) {
        FooterView.screenshotMode = true
        let args = CommandLine.arguments
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let model = AppModel(demo: true)
        if args.contains("--timer") { model.scheduleAllOff(minutes: 5) }
        if args.contains("--dark-colors") { applyDarkColors(model) }
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count {
            switch args[i + 1] {
            case "arrange":
                model.setRoomHidden("bedroom", true)
                model.setLampHidden(model.lamps["7"]!, true)
                model.page = .arrange
            case "forget": model.page = .confirmForget
            case "rename": model.page = .rename("5")
            default: break
            }
        }
        #if DEBUG
        if let i = args.firstIndex(of: "--onboarding"), i + 1 < args.count {
            let bridges = [DiscoveredBridge(host: "192.168.1.20"), DiscoveredBridge(host: "192.168.1.31")]
            switch args[i + 1] {
            case "searching": model.setOnboardingForPreview(.searching)
            case "choose": model.setOnboardingForPreview(.choose(bridges))
            case "none": model.setOnboardingForPreview(.choose([]))
            case "waiting": model.setOnboardingForPreview(.waitingForButton(host: "192.168.1.20", until: Date().addingTimeInterval(171)))
            case "keyform":
                OnboardingView.previewKeyForm = true
                model.setOnboardingForPreview(.choose([DiscoveredBridge(host: "192.168.1.20")]))
            case "checking": model.setOnboardingForPreview(.checkingKey(host: "192.168.1.20"))
            default: model.setOnboardingForPreview(.failed("The bridge button wasn't pressed in time."))
            }
        }
        if args.contains("--offline") { model.setConnectionForPreview(.offline("Can't reach the Hue Bridge")) }
        if args.contains("--cert") { model.setConnectionForPreview(.offline(HueError.certificateChanged.localizedDescription)) }
        #endif
        let light = args.contains("--light")
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!

        let settingsTab = args.firstIndex(of: "--settings").flatMap { i in
            i + 1 < args.count ? SettingsTab(rawValue: args[i + 1]) : nil
        }
        if let settingsTab {
            model.settingsTab = settingsTab
            model.setRoomHidden("bedroom", true)
            model.setLampHidden(model.lamps["7"]!, true)
        }
        let root = Group {
            if settingsTab != nil { SettingsView() } else { PopoverView() }
        }
            .environment(model)
            .background(.regularMaterial)
            .environment(\.colorScheme, light ? .light : .dark)

        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)

        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = light
            ? NSColor(white: 0.95, alpha: 1) : NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
        window.contentView = host
        // Let SwiftUI finish layout (the list measures itself) before capturing.
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let rect = NSRect(origin: .zero, size: host.fittingSize)
        host.frame = rect
        window.setContentSize(rect.size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return }
        host.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path) (\(Int(rect.width))×\(Int(rect.height)))")
    }

    // MARK: Real right-click menu

    /// Shows the demo popover in a window, opens the real NSMenu on a tile, and captures
    /// Glow's own windows while the menu is open. Briefly appears on screen.
    static func menuShot(to url: URL, lampName: String) {
        FooterView.screenshotMode = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let isLight = CommandLine.arguments.contains("--light")
        let dark = NSAppearance(named: isLight ? .aqua : .darkAqua)!   // the appearance used for this shot
        app.appearance = dark

        let model = AppModel(demo: true)
        // Right-click positions inside the popover for the demo layout.
        let targets: [String: (id: String, point: CGPoint)] = [
            "Corner": ("3", CGPoint(x: 196, y: 250)),
            "Floor": ("1", CGPoint(x: 302, y: 250)),
            "Ceiling": ("10", CGPoint(x: 300, y: 130)),   // bedroom ceiling, single color
        ]
        guard let target = targets[lampName], let lamp = model.lamps[target.id] else {
            print("Unknown lamp \(lampName). Use one of: \(targets.keys.sorted())")
            return
        }

        let root = PopoverView()
            .environment(model)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: isLight ? 0.95 : 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1)))
            .environment(\.colorScheme, isLight ? .light : .dark)
        let host = NSHostingView(rootView: root)
        host.appearance = dark
        let size = host.fittingSize

        let window = NSWindow(contentRect: NSRect(x: 240, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - size.height - 20, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.appearance = dark
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let menu = LampMenu.make(lamp: lamp, onColor: { _ in }, onWhite: { _ in },
                                     onRename: {}, onHide: {})
            menu.appearance = dark
            // The menu runs its own event loop; a timer in .common mode still fires during it.
            let capture = Timer(timeInterval: 0.7, repeats: false) { _ in
                MainActor.assumeIsolated {
                    captureOwnWindows(to: url)
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(capture, forMode: .common)
            // Screen coordinates (origin bottom-left): the menu's top-left goes at the click point.
            let frame = window.frame
            let point = CGPoint(x: frame.minX + target.point.x, y: frame.maxY - target.point.y)
            menu.popUp(positioning: nil, at: point, in: nil)
            app.terminate(nil)
        }
        app.run()
    }

    /// Sets demo color lamps to the darkest palette colors, to check text contrast.
    private static func applyDarkColors(_ model: AppModel) {
        let names = ["Blue", "Indigo", "Violet", "Purple", "Red", "Green"]
        let colorLamps = model.lamps.values
            .filter { if case .color = $0.capability { return $0.isReachable } else { return false } }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        for (lamp, name) in zip(colorLamps, names) {
            if let swatch = ColorPalette.colors.first(where: { $0.name == name }) {
                model.setColor(lamp, swatch)
                model.setBrightness(model.lamps[lamp.id]!, to: [35, 60, 85, 100, 50, 70][names.firstIndex(of: name)!])
            }
        }
    }

    /// Draws every visible window of this process (popover window + menu window) into one image,
    /// over a dark background. Uses each window's own drawing, so no screen-recording permission is needed.
    private static func captureOwnWindows(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 1 }
        guard let first = windows.first else { print("No windows to capture"); return }
        let area = windows.dropFirst().reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -28, dy: -28)
        let scale: CGFloat = 2

        let width = Int(area.width * scale), height = Int(area.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let colors = [CGColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1),
                      CGColor(red: 0.15, green: 0.09, blue: 0.21, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

        // Draw lower windows first so the menu ends up on top.
        for window in windows.sorted(by: { $0.level.rawValue < $1.level.rawValue }) {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            let origin = CGPoint(x: (window.frame.minX - area.minX) * scale, y: (window.frame.minY - area.minY) * scale)
            ctx.draw(image, in: CGRect(origin: origin, size: CGSize(width: window.frame.width * scale,
                                                                    height: window.frame.height * scale)))
        }
        guard let output = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path) (\(width)×\(height))")
    }
}
