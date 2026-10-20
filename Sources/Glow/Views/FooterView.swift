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
            Text(model.notice ?? statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(model.notice ?? statusText)
            Spacer()
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
