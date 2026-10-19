import AppKit
import SwiftUI

/// A rounded lamp box. Click toggles, drag sideways sets brightness,
/// right-click opens a menu with colors (if supported) and Rename / Hide.
@MainActor
struct LampTile: View {
    let lamp: Lamp
    let name: String
    var model: AppModel? = nil
    let onToggle: () -> Void
    let onBrightness: (Double) -> Void
    let onColor: (ColorPalette.Swatch) -> Void
    let onWhite: (ColorPalette.White) -> Void
    let onRename: () -> Void
    let onHide: () -> Void

    @State private var isPressed = false
    @State private var isDragging = false
    @State private var movedAway = false
    @State private var isHovered = false
    /// True only while a gesture is live; resets by itself if the gesture is cancelled
    /// (e.g. the popover closes mid-drag), so the tile never gets stuck "dragging".
    @GestureState private var gestureActive = false
    @State private var menuAnchor = MenuAnchor()
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var isLit: Bool { lamp.isOn && lamp.isReachable }
    private var tint: HueColor.RGB { HueColor.rgb(for: lamp) }
    /// Text on lit tiles is dark; dark lamp colors are lightened just enough to keep it readable.
    private var fillStart: HueColor.RGB { tint.readableBehindInk() }
    private var fillEnd: HueColor.RGB { tint.mixed(with: .white, 0.45).readableBehindInk() }
    private var unlitPart: HueColor.RGB { fillEnd.mixed(with: .slate, 0.38).readableBehindInk() }
    private static let ink = Color(white: 0.11)
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                background(width: geo.size.width)
                content
            }
            .contentShape(shape)
            .gesture(dragGesture(width: geo.size.width), including: lamp.isReachable ? .all : .none)
        }
        .frame(height: Metrics.tileHeight)
        .clipShape(shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-1).opacity(isFocused ? 1 : 0))
        .shadow(color: isLit ? tint.color.opacity(0.55) : .clear, radius: 11, y: 6)
        .scaleEffect(isPressed && !isDragging && !reduceMotion ? 0.97 : 1)
        .opacity(lamp.isReachable ? 1 : 0.45)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: isPressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: isLit)
        .onHover { isHovered = $0 }
        .onChange(of: gestureActive) { _, active in
            if !active { isPressed = false; isDragging = false; movedAway = false }
        }
        .overlay(RightClickCatcher(anchor: menuAnchor) { event, view in
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: view)
        })
        // Keyboard: Space/Return toggles, ←/→ change brightness.
        .focusable(lamp.isReachable)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { onToggle(); return .handled }
        .onKeyPress(.return) { onToggle(); return .handled }
        .onKeyPress(.leftArrow) { step(-10); return .handled }
        .onKeyPress(.rightArrow) { step(10); return .handled }
        // VoiceOver
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(statusText)
        .accessibilityHint(!lamp.isReachable ? "" : lamp.isDimmable
            ? "Toggles the lamp. Increment or decrement to change brightness." : "Toggles the lamp.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if lamp.isReachable { onToggle() } }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(10)
            case .decrement: step(-10)
            @unknown default: break
            }
        }
        .accessibilityAction(named: lamp.capability == .single ? "Rename or Hide…" : "Color, Rename or Hide…") {
            menuAnchor.popUp(makeMenu())
        }
    }

    private var borderColor: Color {
        if isLit { return contrast == .increased ? Self.ink.opacity(0.5) : .clear }
        return Color.primary.opacity(contrast == .increased ? 0.35 : 0.10)
    }

    private func makeMenu() -> NSMenu {
        LampMenu.make(lamp: lamp, model: model, onColor: onColor, onWhite: onWhite, onRename: onRename, onHide: onHide)
    }

    /// Brightness step for keyboard and VoiceOver. Stepping up from off starts at 10%.
    private func step(_ delta: Double) {
        guard lamp.isReachable else { return }
        guard lamp.isDimmable else { onBrightness(delta > 0 ? 100 : 0); return }   // plugs: → on, ← off
        let current = lamp.isOn ? lamp.brightness : 0
        onBrightness(min(100, max(0, (current + delta).rounded())))
    }

    // MARK: Layers

    @ViewBuilder
    private func background(width: CGFloat) -> some View {
        if isLit {
            // Unlit part: a soft shade of the lamp's color, so dark text stays readable.
            unlitPart.color
            LinearGradient(colors: [fillStart.color, fillEnd.color], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * (lamp.isDimmable ? lamp.brightness : 100) / 100)
                .animation(isDragging || reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                           value: lamp.brightness)
        } else {
            Color.primary.opacity(isHovered ? 0.10 : 0.06)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle().fill(isLit ? Color.white.opacity(0.6) : Color.primary.opacity(0.12))
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isLit ? Self.ink.opacity(0.8) : Color.secondary)
            }
            .frame(width: 24, height: 24)

            Spacer(minLength: 0)

            Text(name)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isLit ? Self.ink : Color.primary)
            Text(statusText)
                .font(.system(size: 11).monospacedDigit())
                .italic(!lamp.isReachable)
                .foregroundStyle(isLit ? Self.ink.opacity(0.72) : Color.secondary)
                .contentTransition(.numericText())
                .padding(.top, 1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var statusText: String {
        if !lamp.isReachable { return "Unreachable" }
        if !lamp.isOn { return "Off" }
        return lamp.isDimmable ? "\(Int(lamp.brightness.rounded()))%" : "On"
    }

    // MARK: Interaction

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                isPressed = true
                let dx = abs(value.translation.width), dy = abs(value.translation.height)
                if !isDragging, !movedAway {
                    if lamp.isDimmable, dx > 5, dx >= dy { isDragging = true }
                    else if dy > 8 || (!lamp.isDimmable && dx > 8) { movedAway = true }   // not a click
                }
                if isDragging, width > 0 {
                    let pct = min(1, max(0, value.location.x / width)) * 100
                    onBrightness(pct.rounded())
                }
            }
            .onEnded { _ in
                if !isDragging, !movedAway { onToggle() }
                isPressed = false
                isDragging = false
                movedAway = false
            }
    }
}
