import AppKit
import SwiftUI

/// The native right-click menu for a lamp: color dots and whites at the top
/// (only what the lamp supports), then Rename / Hide.
@MainActor
enum LampMenu {
    /// Shown instead of the color section for lamps that can't change color.
    static let singleColorNote = "This lamp has one fixed color"

    static func make(
        lamp: Lamp,
        model: AppModel? = nil,
        onColor: @escaping (ColorPalette.Swatch) -> Void,
        onWhite: @escaping (ColorPalette.White) -> Void,
        onRename: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if lamp.capability != .single {
            // Picking a color keeps the menu open (try a few, then click outside to close).
            let appearance = NSApp.effectiveAppearance
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let section = ColorMenuSection(lamp: lamp, model: model, onColor: onColor, onWhite: onWhite, isDark: dark)
            // A SwiftUI view inside an NSMenu doesn't pick up the menu's dark appearance by itself
            // (the white chips' labels came out dark-on-dark), so colours are set explicitly above.
            let host = NSHostingView(rootView: AnyView(section.environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let item = NSMenuItem()
            item.view = host
            item.isEnabled = lamp.isReachable
            menu.addItem(item)
            menu.addItem(.separator())
        } else {
            // Without this, the menu shows only Rename / Hide and looks broken.
            let note = NSMenuItem(title: singleColorNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }

        menu.addItem(ClosureMenuItem("Rename in Glow…", action: onRename))
        menu.addItem(ClosureMenuItem("Hide from Glow", action: onHide))
        return menu
    }
}

/// NSMenuItem that runs a Swift closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Lets keyboard / VoiceOver users open a tile's menu without a mouse.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }
}

/// Catches right-clicks (and Control-clicks) on a SwiftUI view, letting every
/// other click and drag pass through to the view underneath.
struct RightClickCatcher: NSViewRepresentable {
    var anchor: MenuAnchor?
    let action: (NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        anchor?.view = view
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: ((NSEvent, NSView) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isSecondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isSecondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?(event, self) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { action?(event, self) }
        }
    }
}
