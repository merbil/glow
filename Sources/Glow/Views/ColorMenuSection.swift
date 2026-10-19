import AppKit
import SwiftUI

/// The color part of a lamp's right-click menu, in the style of Finder's tag dots.
/// Meant to be hosted inside an NSMenuItem; shows only what the lamp supports.
@MainActor
struct ColorMenuSection: View {
    let lamp: Lamp
    /// When set, the section follows the lamp's live state (the menu stays open after a pick).
    var model: AppModel? = nil
    let onColor: (ColorPalette.Swatch) -> Void
    let onWhite: (ColorPalette.White) -> Void
    /// Inside a native menu SwiftUI's default colours don't follow dark mode (labels came out
    /// dark-on-dark), so every colour here is chosen explicitly from the menu's appearance.
    var isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    private var ink: Color { isDark ? Color(white: 0.93) : Color(white: 0.12) }

    @State private var hovered: String?
    private let dot: CGFloat = 18
    private let columns = Array(repeating: GridItem(.fixed(18), spacing: 9), count: 8)

    private var current: Lamp { model?.lamps[lamp.id] ?? lamp }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch lamp.capability {
            case .color(let range):
                colorGrid
                whitesRow(ColorPalette.whites(for: range ?? 153...500))
            case .whites(let range):
                whitesRow(ColorPalette.whites(for: range))
            case .single:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var colorGrid: some View {
        let selected = current.isOn ? ColorPalette.selectedColor(for: current) : nil
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
            ForEach(ColorPalette.colors) { swatch in
                Circle()
                    .fill(swatch.rgb.color)
                    .frame(width: dot, height: dot)
                    .overlay(ring(isOn: swatch == selected || hovered == swatch.id))
                    .scaleEffect(hovered == swatch.id ? 1.15 : 1)
                    .onHover { hovered = $0 ? swatch.id : nil }
                    .onTapGesture { onColor(swatch) }
                    .help(swatch.name)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func whitesRow(_ whites: [ColorPalette.White]) -> some View {
        let selected = current.isOn ? ColorPalette.selectedWhite(for: current) : nil
        return HStack(spacing: 6) {
            ForEach(whites) { white in
                let isActive = white.id == selected?.id || hovered == white.id
                HStack(spacing: 5) {
                    Circle()
                        .fill(white.rgb.color)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.1)))
                    Text(white.name)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(ink)
                .background(Capsule().fill(ink.opacity(isActive ? 0.16 : 0.07)))
                .overlay(Capsule().strokeBorder(ink.opacity(white.id == selected?.id ? 0.45 : 0)))
                .onHover { hovered = $0 ? white.id : nil }
                .onTapGesture { onWhite(white) }
            }
        }
    }

    private func ring(isOn: Bool) -> some View {
        Circle()
            .strokeBorder(ink.opacity(isOn ? 0.85 : 0), lineWidth: 1.5)
            .padding(-3.5)
    }
}
