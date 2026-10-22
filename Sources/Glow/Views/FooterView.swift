import SwiftUI

@MainActor
struct FooterView: View {
    /// Screenshots for the README/website show the normal "connected" status instead of "Demo mode".
    nonisolated(unsafe) static var screenshotMode = false
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    /// Writes through to ServiceManagement and re-reads the real state (it can fail or need approval).
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { enabled in
            LaunchAtLogin.set(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.notice ?? statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if model.notice == nil, let offlineDetail {
                    Text(offlineDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help([model.notice ?? statusText, model.notice == nil ? offlineDetail : nil].compactMap { $0 }.joined(separator: "\n"))
            Spacer()
            if isOffline {
                Button { model.retryNow() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Try again")
                .accessibilityLabel("Refresh")
            }
            settingsMenu
        }
    }

    private var statusColor: Color {
        switch model.connection {
        case .live: .green
        case .connecting: .yellow
        case .offline: .red
        }
    }

    private var isOffline: Bool {
        if case .offline = model.connection { return !model.isDemo || FooterView.screenshotMode }
        return false
    }

    /// Second line while offline: whether Glow gave up, and when the bridge last answered.
    private var offlineDetail: String? {
        guard isOffline else { return nil }
        var parts: [String] = []
        if model.retriesStopped { parts.append("Stopped trying") }
        if let seen = model.lastContact, Date().timeIntervalSince(seen) > 60 {
            parts.append("last seen \(Self.relative.localizedString(for: seen, relativeTo: Date()))")
        }
        guard !parts.isEmpty else { return nil }
        var text = parts.joined(separator: " · ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var statusText: String {
        switch model.connection {
        case .live: model.isDemo && !FooterView.screenshotMode ? "Demo mode" : "Hue Bridge connected"
        case .connecting: "Connecting…"
        case .offline(let reason): reason
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Lamps & Rooms…") { model.openSettings(.arrange) }
            Button("Settings…") { model.openSettings(.general) }
                .keyboardShortcut(",")
            if let release = Updater.shared.available {
                if Updater.shared.offersInstall {
                    Button("Update to Glow \(release.version)…") {
                        model.openSettings(.general)
                        Task { await Updater.shared.install() }
                    }
                    .disabled(Updater.shared.isWorking)
                } else {
                    Button("Download Glow \(release.version)…") { Updater.shared.download() }
                }
            }
            if model.hiddenCount > 0 {
                Button("Show Hidden (\(model.hiddenCount))") { model.unhideAll() }
            }
            if model.isBlockedByLocalNetworkPrivacy {
                Button("Open Local Network Settings…") { AppModel.openLocalNetworkSettings() }
            }
            Divider()
            Button("About Glow") { model.openSettings(.about) }
            Button("Forget Hue Bridge…") { model.page = .confirmForget }
            Divider()
            Button("Quit Glow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Settings")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
