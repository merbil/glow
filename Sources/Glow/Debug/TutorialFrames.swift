#if DEBUG
import AppKit
import SwiftUI

/// Renders the frames of the website tutorial GIF:  Glow --tutorial-frames <outdir>
/// Drives the demo model through four interactions (toggle, drag to dim, right-click colors,
/// All off with a timer), drawing a mouse cursor on top. The GIF is assembled by a script outside the repo.
@MainActor
enum TutorialFrames {
    // MARK: Stage state (what the canvas draws besides the real popover)

    @Observable
    @MainActor
    final class Stage {
        enum Menu { case none, color(lampID: String), allOff }
        var cursor = CGPoint(x: 0, y: 0)
        var menu = Menu.none
        var menuOrigin = CGPoint.zero            // top-left of the menu, canvas coordinates
        var hoverDot: Int?                       // index into ColorPalette.colors
        var hoverRow: Int?                       // row index in the All off menu
        var rippleCenter = CGPoint.zero
        var rippleProgress: Double?              // 0...1 while a click ripple plays
    }

    // MARK: Layout of the demo popover (points)

    static let margin: CGFloat = 36
    static let columns = 3
    static let tileWidth: CGFloat = (Metrics.popoverWidth - 28 - 2 * Metrics.gridSpacing) / 3
    /// Vertical layout, calibrated against rendered frames (`--calibrate`).
    static let gridTop: CGFloat = 61.5
    static let roomHeaderHeight: CGFloat = 15.5
    static let roomHeaderGap: CGFloat = 7
    static let sectionGap: CGFloat = 14
    /// Center of the "All off" pill, popover coordinates.
    static let allOffCenter = CGPoint(x: Metrics.popoverWidth - 18 - 41, y: 16 + 17)

    static func tileFrame(of id: String, in model: AppModel) -> CGRect {
        var y = gridTop
        for section in model.sections {
            y += roomHeaderHeight + roomHeaderGap
            for (i, lamp) in section.lamps.enumerated() {
                if lamp.id == id {
                    let row = i / columns, col = i % columns
                    return CGRect(x: 14 + CGFloat(col) * (tileWidth + Metrics.gridSpacing),
                                  y: y + CGFloat(row) * (Metrics.tileHeight + Metrics.gridSpacing),
                                  width: tileWidth, height: Metrics.tileHeight)
                }
            }
            let rows = (section.lamps.count + columns - 1) / columns
            y += CGFloat(rows) * Metrics.tileHeight + CGFloat(max(0, rows - 1)) * Metrics.gridSpacing + sectionGap
        }
        return .zero
    }

    // MARK: Menus (imitating native macOS dark menus)

    private static let menuFill = Color(red: 0.17, green: 0.17, blue: 0.185)
    private static let rowHeight: CGFloat = 22
    private static let menuVPad: CGFloat = 5

    private struct MenuPanel<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, TutorialFrames.menuVPad)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TutorialFrames.menuFill.opacity(0.98)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 16, y: 9)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .fixedSize()
        }
    }

    private struct MenuRow: View {
        let title: String
        var highlighted = false
        var secondary = false
        var body: some View {
            Text(title)
                .font(secondary ? .system(size: 11, weight: .semibold) : .system(size: 13))
                .foregroundStyle(secondary ? Color(white: 0.62) : highlighted ? Color.white : Color(white: 0.93))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: TutorialFrames.rowHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlighted ? Color.accentColor : .clear).padding(.horizontal, 5))
        }
    }

    private struct MenuSeparator: View {
        var body: some View {
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private struct ColorMenu: View {
        let model: AppModel
        let lamp: Lamp
        let hoverDot: Int?
        var body: some View {
            MenuPanel {
                ColorMenuSection(lamp: lamp, model: model, onColor: { _ in }, onWhite: { _ in }, isDark: true)
                    .overlay(alignment: .topLeading) {
                        if let hoverDot {
                            let p = TutorialFrames.dotCenter(hoverDot)
                            Circle().strokeBorder(Color(white: 0.93).opacity(0.85), lineWidth: 1.5)
                                .frame(width: 25, height: 25)
                                .offset(x: p.x - 12.5, y: p.y - 12.5 - TutorialFrames.menuVPad)
                        }
                    }
                MenuSeparator()
                MenuRow(title: "Rename in Glow…")
                MenuRow(title: "Hide from Glow")
            }
        }
    }

    private struct AllOffMenu: View {
        let hoverRow: Int?
        var body: some View {
            MenuPanel {
                MenuRow(title: "Turn all lights off…", secondary: true)
                MenuRow(title: "Now", highlighted: hoverRow == 0)
                MenuSeparator()
                MenuRow(title: "In 5 minutes", highlighted: hoverRow == 1)
                MenuRow(title: "In 15 minutes", highlighted: hoverRow == 2)
                MenuRow(title: "In 30 minutes", highlighted: hoverRow == 3)
                MenuRow(title: "In 1 hour", highlighted: hoverRow == 4)
            }
            .frame(width: 176, alignment: .leading)
        }
    }

    /// Center of color dot `index` inside the color menu (menu coordinates).
    static func dotCenter(_ index: Int) -> CGPoint {
        let col = index % 8, row = index / 8
        return CGPoint(x: 14 + CGFloat(col) * 27 + 9, y: menuVPad + 8 + CGFloat(row) * 27 + 9)
    }

    /// Center of row `index` (0 = Now, 1 = In 5 minutes, ...) in the All off menu (menu coordinates).
    static func allOffRowCenter(_ index: Int) -> CGPoint {
        let y: CGFloat = menuVPad + rowHeight                     // after the title row
        let rowY = index == 0 ? y + rowHeight / 2 : y + rowHeight + 11 + CGFloat(index - 1) * rowHeight + rowHeight / 2
        return CGPoint(x: 60, y: rowY)
    }

    // MARK: Canvas

    private struct Canvas: View {
        let model: AppModel
        let stage: Stage
        let popoverSize: CGSize
        let size: CGSize
        let cursorImage: NSImage
        let hotSpot: CGPoint

        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.16), Color(red: 0.15, green: 0.09, blue: 0.21)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                PopoverView()
                    .environment(model)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                    .frame(width: popoverSize.width, height: popoverSize.height)
                    .offset(x: TutorialFrames.margin, y: TutorialFrames.margin)

                switch stage.menu {
                case .none: EmptyView()
                case .color(let id):
                    if let lamp = model.lamps[id] {
                        ColorMenu(model: model, lamp: lamp, hoverDot: stage.hoverDot)
                            .offset(x: stage.menuOrigin.x, y: stage.menuOrigin.y)
                    }
                case .allOff:
                    AllOffMenu(hoverRow: stage.hoverRow)
                        .offset(x: stage.menuOrigin.x, y: stage.menuOrigin.y)
                }

                if let p = stage.rippleProgress {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.75 * (1 - p)), lineWidth: 2.5)
                        .background(Circle().fill(Color.white.opacity(0.18 * (1 - p))))
                        .frame(width: 14 + 34 * p, height: 14 + 34 * p)
                        .position(stage.rippleCenter)
                }

                Image(nsImage: cursorImage)
                    .interpolation(.high)
                    .offset(x: stage.cursor.x - hotSpot.x, y: stage.cursor.y - hotSpot.y)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        }
    }

    // MARK: Director

    @MainActor
    final class Director {
        let model = AppModel(demo: true)
        let stage = Stage()
        let outDir: URL
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let canvasSize: CGSize
        let popoverSize: CGSize
        var frame = 0
        /// Runs before every capture (used to keep the demo countdown reading "Off in 4:59").
        var beforeCapture: (() -> Void)?
        static let fps = 15.0

        init(outDir: URL) {
            self.outDir = outDir
            let dark = NSAppearance(named: .darkAqua)!
            // Measure the popover the way Snapshot does.
            let probe = NSHostingView(rootView: PopoverView().environment(model).environment(\.colorScheme, .dark))
            probe.appearance = dark
            probe.layoutSubtreeIfNeeded()
            popoverSize = probe.fittingSize
            canvasSize = CGSize(width: popoverSize.width + 2 * TutorialFrames.margin,
                                height: popoverSize.height + 2 * TutorialFrames.margin + 60)
            let cursor = NSCursor.arrow
            let canvas = Canvas(model: model, stage: stage, popoverSize: popoverSize, size: canvasSize,
                                cursorImage: cursor.image, hotSpot: cursor.hotSpot)
            host = NSHostingView(rootView: AnyView(canvas))
            host.appearance = dark
            host.frame = NSRect(origin: .zero, size: canvasSize)
            window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = dark
            window.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
            window.contentView = host
        }

        func settle(_ seconds: Double) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }

        /// Writes one 2x PNG of the current state.
        func capture(settle seconds: Double = 0.04) {
            beforeCapture?()
            settle(seconds)
            let rect = NSRect(origin: .zero, size: canvasSize)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = rect.size
            host.cacheDisplay(in: rect, to: rep)
            frame += 1
            let url = outDir.appendingPathComponent(String(format: "frame-%04d.png", frame))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }

        func hold(_ seconds: Double, settle s: Double = 0.04) {
            for _ in 0..<max(1, Int((seconds * Self.fps).rounded())) { capture(settle: s) }
        }

        static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

        /// Moves the cursor with an eased curve (slight arc), one frame per tick.
        func move(to target: CGPoint, seconds: Double, settle s: Double = 0.04, each: ((Double) -> Void)? = nil) {
            let start = stage.cursor
            let n = max(1, Int((seconds * Self.fps).rounded()))
            let dist = hypot(target.x - start.x, target.y - start.y)
            let bow = min(14, dist * 0.06)
            for i in 1...n {
                let e = Self.ease(Double(i) / Double(n))
                let arc = sin(e * .pi) * bow
                stage.cursor = CGPoint(x: start.x + (target.x - start.x) * e,
                                       y: start.y + (target.y - start.y) * e - arc)
                each?(e)
                capture(settle: s)
            }
            stage.cursor = target
        }

        /// A click ripple; `action` runs once, on the third frame (the click lands).
        func click(atFrame action: () -> Void, settle s: Double = 0.2) {
            stage.rippleCenter = stage.cursor
            let n = 7
            for i in 0..<n {
                stage.rippleProgress = Double(i) / Double(n - 1)
                if i == 2 { action() }
                capture(settle: i == 2 ? s : 0.04)
            }
            stage.rippleProgress = nil
        }

        func canvasPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + TutorialFrames.margin, y: p.y + TutorialFrames.margin) }
    }

    // MARK: Script

    static func render(to outDir: URL) {
        FooterView.screenshotMode = true
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("frame-") { try? FileManager.default.removeItem(at: f) }

        let d = Director(outDir: outDir)
        let model = d.model, stage = d.stage
        let calibrate = CommandLine.arguments.contains("--calibrate")
        func tile(_ id: String) -> CGRect { tileFrame(of: id, in: model) }

        // Let SwiftUI measure the list before the first frame.
        d.settle(0.6)
        d.settle(0.3)

        if calibrate {
            // Frames with the cursor at the computed tile centers, to check the layout constants.
            for id in ["2", "3", "5", "8", "11"] {
                stage.cursor = d.canvasPoint(CGPoint(x: tile(id).midX, y: tile(id).midY))
                d.capture(settle: 0.2)
            }
            stage.cursor = d.canvasPoint(allOffCenter)
            d.capture()
            print("Calibration frames: \(d.frame)")
            return
        }

        stage.cursor = d.canvasPoint(CGPoint(x: Metrics.popoverWidth - 150, y: 180))
        d.hold(0.9, settle: 0.1)

        // 1. Click to toggle an off lamp.
        do {
            let t = tile("2")
            d.move(to: d.canvasPoint(CGPoint(x: t.midX + 6, y: t.midY - 4)), seconds: 0.9)
            d.hold(0.25)
            d.click(atFrame: { model.toggle(model.lamps["2"]!) })
            d.hold(0.8, settle: 0.1)
        }

        // 2. Drag to dim: the fill edge follows the cursor, 40% → 85% → 60%.
        do {
            let t = tile("3")
            func x(_ pct: Double) -> CGFloat { t.minX + t.width * pct / 100 }
            let y = t.midY + 8
            d.move(to: d.canvasPoint(CGPoint(x: x(40), y: y)), seconds: 0.9)
            d.hold(0.2)
            stage.rippleCenter = stage.cursor
            for i in 0..<3 { stage.rippleProgress = Double(i) / 4; d.capture() }
            stage.rippleProgress = nil
            func drag(to pct: Double, seconds: Double) {
                let from = (stage.cursor.x - margin - t.minX) / t.width * 100
                d.move(to: d.canvasPoint(CGPoint(x: x(pct), y: y)), seconds: seconds) { e in
                    let p = from + (pct - from) * e
                    model.setBrightness(model.lamps["3"]!, to: p.rounded())
                }
            }
            drag(to: 85, seconds: 0.9)
            d.hold(0.3)
            drag(to: 60, seconds: 0.7)
            d.hold(0.8, settle: 0.1)
        }

        // 3. Right-click a color lamp, pick a color.
        do {
            let t = tile("5")
            d.move(to: d.canvasPoint(CGPoint(x: t.midX - 10, y: t.midY - 8)), seconds: 1.0)
            d.hold(0.25)
            let origin = stage.cursor
            d.click(atFrame: {
                stage.menu = .color(lampID: "5")
                stage.menuOrigin = origin
            })
            d.hold(0.7)
            let target = 13          // Purple
            let dot = dotCenter(target)
            let dotCanvas = CGPoint(x: origin.x + dot.x, y: origin.y + dot.y)
            d.move(to: dotCanvas, seconds: 0.8) { e in stage.hoverDot = e > 0.85 ? target : nil }
            stage.hoverDot = target
            d.hold(0.25)
            d.click(atFrame: {
                model.setColor(model.lamps["5"]!, ColorPalette.colors[target])
                stage.menu = .none
                stage.hoverDot = nil
            }, settle: 0.25)
            d.hold(0.8, settle: 0.1)
        }

        // 4. All off, in 5 minutes.
        do {
            let c = d.canvasPoint(allOffCenter)
            d.move(to: c, seconds: 1.0)
            d.hold(0.25)
            d.click(atFrame: {
                stage.menu = .allOff
                stage.menuOrigin = CGPoint(x: c.x - 41 - 2, y: c.y + 14 + 6)
            })
            d.hold(0.6)
            let rowPt = allOffRowCenter(1)
            let target = CGPoint(x: stage.menuOrigin.x + rowPt.x, y: stage.menuOrigin.y + rowPt.y)
            d.move(to: target, seconds: 0.7) { e in
                stage.hoverRow = e > 0.9 ? 1 : (e > 0.6 ? 0 : nil)
            }
            stage.hoverRow = 1
            d.hold(0.3)
            d.click(atFrame: {
                model.scheduleAllOff(minutes: 5)
                stage.menu = .none
                stage.hoverRow = nil
                // Rendering is slower than real time, so restart the demo timer before each frame
                // and let it tick once: the pill always reads "Off in 4:59".
                d.beforeCapture = {
                    model.scheduleAllOff(minutes: 5)
                    d.settle(1.5)
                }
            }, settle: 0.4)
            d.move(to: d.canvasPoint(CGPoint(x: Metrics.popoverWidth - 120, y: 200)), seconds: 0.7)
            d.hold(1.2, settle: 0.04)
        }
        print("Wrote \(d.frame) frames to \(outDir.path) (\(Int(d.canvasSize.width * 2))×\(Int(d.canvasSize.height * 2)))")
    }
}
#endif
