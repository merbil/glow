import AppKit

/// The menu bar bulb with a small red dot, shown after Glow stopped retrying an unreachable bridge.
/// Not a template image (the dot must stay red), so the bulb is drawn in the menu bar's own label
/// colour, resolved at draw time for light and dark menu bars.
enum MenuBarIcon {
    static func withAlertDot(filled: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let bulb = NSImage(systemSymbolName: filled ? "lightbulb.fill" : "lightbulb", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let size = NSSize(width: bulb.size.width + 4, height: max(bulb.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(x: 0, y: (rect.height - bulb.size.height) / 2)
            // Tint the symbol: draw it, then fill with the label colour using its alpha.
            let tinted = NSImage(size: bulb.size, flipped: false) { r in
                bulb.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            // Dot at the top right, with a clear ring so it reads against the bulb.
            let d: CGFloat = 5.5
            let dot = NSRect(x: rect.maxX - d - 0.5, y: rect.maxY - d - 0.5, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
