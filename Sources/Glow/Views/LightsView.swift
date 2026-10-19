import SwiftUI

@MainActor
struct LightsView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            if model.hasUnseenUpdate { UpdateBanner() }

            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: false) {
                rooms
                    .padding(.horizontal, 14)
                    // Without a bridge connection clicks can't do anything: show that.
                    .disabled(isOffline)
                    .opacity(isOffline ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.25), value: isOffline)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 1), Metrics.maxListHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }

            Divider().padding(.horizontal, 14)
            FooterView()
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lights")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            AllOffControl()
                .disabled(isOffline)
                .opacity(isOffline ? 0.5 : 1)
        }
    }

    private var isOffline: Bool {
        if case .offline = model.connection { return true }
        return false
    }

    private var summary: String {
        let total = model.visibleLampCount
        if total == 0 { return "No lamps shown" }
        let on = model.onCount
        return on == 0 ? "All \(total) off" : "\(on) of \(total) on"
    }

    @ViewBuilder
    private var rooms: some View {
        if model.sections.isEmpty {
            EmptyStateView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        RoomHeader(section: section)
                        LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                            ForEach(section.lamps) { lamp in
                                LampTile(
                                    lamp: lamp,
                                    name: model.displayName(lamp),
                                    model: model,
                                    onToggle: { model.toggle(lamp) },
                                    onBrightness: { model.setBrightness(lamp, to: $0) },
                                    onColor: { model.setColor(lamp, $0) },
                                    onWhite: { model.setWhite(lamp, $0) },
                                    onRename: { model.page = .rename(lamp.id) },
                                    onHide: { withAnimation { model.setLampHidden(lamp, true) } }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }
}

/// Room title with an on/off switch for the whole room. Right-click to hide the room.
@MainActor
private struct RoomHeader: View {
    @Environment(AppModel.self) private var model
    let section: LampSection

    private var reachable: Bool { section.anyReachable }

    var body: some View {
        HStack(spacing: 6) {
            Text(section.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { section.anyOn },
                set: { model.setRoom(section, on: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!reachable)
            .accessibilityLabel("\(section.title): all lamps")
            .help(section.anyOn ? "Turn off everything in \(section.title)" : "Turn on everything in \(section.title)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Hide \(section.title) from Glow") { withAnimation { model.setRoomHidden(section.id, true) } }
            Button("Arrange & Hide…") { model.page = .arrange }
        }
    }
}

/// Shown once after an update.
@MainActor
private struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.yellow)
            Text("Glow was updated to \(AppInfo.version).")
                .font(.system(size: 12))
            Button("What's new") {
                model.markUpdateSeen()
                model.openSettings(.about)
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                withAnimation { model.markUpdateSeen() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.12)))
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}

@MainActor
private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(model.connection == .live ? "No lamps to show" : "Connecting to your Hue Bridge…")
                .font(.system(size: 12.5, weight: .medium))
            if model.hiddenCount > 0 {
                Button("Show hidden lamps and rooms") { model.unhideAll() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
