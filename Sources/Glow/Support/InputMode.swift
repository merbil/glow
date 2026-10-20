import AppKit
import Observation

/// Tracks whether the user is navigating by keyboard, so focus rings show only for
/// keyboard users (a mouse click also focuses a tile, but shouldn't draw a ring).
@MainActor
@Observable
final class InputMode {
    static let shared = InputMode()

    private(set) var usingKeyboard = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let keyboard = event.type == .keyDown
            if self?.usingKeyboard != keyboard { self?.usingKeyboard = keyboard }
            return event
        }
    }
}
