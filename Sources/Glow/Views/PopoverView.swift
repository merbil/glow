import AppKit
import SwiftUI

enum Metrics {
    static let popoverWidth: CGFloat = 372
    static let maxListHeight: CGFloat = 470
    static let tileHeight: CGFloat = 82
    static let tileRadius: CGFloat = 16
    static let gridSpacing: CGFloat = 8
}

@MainActor
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        Group {
            if !model.isPaired {
                OnboardingView()
            } else {
                switch model.page {
                case .lights: LightsView()
                case .rename(let id): RenameView(lampID: id)
                case .confirmForget: ConfirmForgetView()
                }
            }
        }
        .frame(width: Metrics.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in
            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .background(SettingsOpener())
        .background(WindowFitter(contentHeight: contentHeight))
        .animation(.easeOut(duration: 0.18), value: model.page)
        .onAppear { model.popoverDidAppear() }
        // Always reopen on the lights page (not on Rename or "Forget bridge?").
        .onDisappear { model.page = .lights }
    }
}

/// Shared header for the secondary pages: back button + title.
@MainActor
struct PageHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.page = .lights
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .keyboardShortcut(.cancelAction)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The menu bar window grows when its content gets taller, but doesn't shrink back when the
/// content gets shorter (after hiding a room, reordering, leaving the Rename page…). The leftover
/// window showed as an empty "phantom frame" around the popover. This keeps the window exactly as
/// tall as the content, with its top edge pinned under the menu bar, and redraws its shadow.
struct WindowFitter: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.contentHeight = contentHeight
        // After this layout pass, so the window isn't resized in the middle of one.
        DispatchQueue.main.async { view.fit() }
    }

    final class FitterView: NSView {
        var contentHeight: CGFloat = 0
        private var observers: [NSObjectProtocol] = []
        private var recentResizes: [Date] = []

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                // SwiftUI can resize the window itself, and showing it again doesn't re-render the view.
                observers = [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        DispatchQueue.main.async { self?.refit() }
                    }
                }
            }
            fit()
        }

        /// A refit from a notification. If SwiftUI keeps pushing the size back, stop after a few per second.
        private func refit() {
            let now = Date()
            recentResizes = recentResizes.filter { now.timeIntervalSince($0) < 1 }
            guard recentResizes.count < 6 else {
                Log.model.notice("popover fit: too many resizes, skipping")
                return
            }
            if fit() { recentResizes.append(now) }
        }

        /// Only the menu bar window is fitted (not, say, the tutorial-frames canvas). True if it was resized.
        @discardableResult
        func fit() -> Bool {
            guard let window, contentHeight > 0,
                  String(describing: type(of: window)).contains("MenuBarExtraWindow") else { return false }
            var resized = false
            let current = window.contentRect(forFrameRect: window.frame)
            if abs(current.height - contentHeight) > 0.5 {
                resized = true
                var content = current
                content.origin.y = current.maxY - contentHeight      // keep the top edge in place
                content.size.height = contentHeight
                Log.model.debug("popover fit: window \(Int(current.height)) → content \(Int(self.contentHeight))")
                window.setFrame(window.frameRect(forContentRect: content), display: true)
                // The content keeps its old centred position until the next layout pass, which
                // showed as a strip of empty window. Lay it out against the new size right away.
                window.contentView?.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
            }
            if let contentView = window.contentView, abs(convert(bounds, to: nil).minY) > 0.5 {
                Log.model.notice("popover fit: content was off by \(Int(self.convert(self.bounds, to: nil).minY)) pt, laying out again")
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
            }
            window.invalidateShadow()
            return resized
        }
    }
}
