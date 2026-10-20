import SwiftUI

/// The Glow Settings window (Settings… / ⌘, in the gear menu).
@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // Icon tabs like the system's own Settings windows (a plain TabView draws a
            // segmented control half-overlapping the content box, which looked off).
            HStack(spacing: 4) {
                tabButton(.general, "General", "gearshape", key: "1")
                tabButton(.arrange, "Lamps & Rooms", "square.grid.2x2", key: "2")
                tabButton(.about, "About", "info.circle", key: "3")
            }
            .padding(.vertical, 8)
            Divider()
            Group {
                switch model.settingsTab {
                case .general: GeneralTab()
                case .arrange: ArrangeView()
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 640)
    }

    private func tabButton(_ tab: SettingsTab, _ title: String, _ icon: String, key: KeyEquivalent) -> some View {
        let selected = model.settingsTab == tab
        return Button { model.settingsTab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(minWidth: 74)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lets the menu-bar code open the Settings window (SwiftUI's openWindow lives in the view tree).
@MainActor
struct SettingsOpener: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            model.openSettingsWindow = { openWindow(id: "settings") }
        }
    }
}

// MARK: - General

@MainActor
private struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var confirmForget = false
    private var updater: Updater { Updater.shared }

    private var latestText: String {
        switch updater.state {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date"
        case .failed: return "Couldn't check"
        case .available(let release): return release.version
        }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Startup") {
                Toggle("Open Glow when you log in", isOn: Binding(
                    get: { launchAtLogin },
                    set: { LaunchAtLogin.set($0); launchAtLogin = LaunchAtLogin.isEnabled }
                ))
            }
            Section("Updates") {
                LabeledContent("Installed version", value: updater.currentVersion)
                LabeledContent("Latest version", value: latestText)
                HStack {
                    if updater.available != nil {
                        Text("Open the downloaded file and drag Glow to Applications, replacing the old one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let release = updater.available {
                        Button("Download Glow \(release.version)") { updater.download() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Check Now") { Task { await updater.check() } }
                            .disabled(!updater.isRunning || updater.state == .checking)
                    }
                }
            }
            Section("Hue Bridge") {
                LabeledContent("Status", value: statusText)
                if let host = model.bridgeHost {
                    LabeledContent("Address", value: host)
                }
                HStack {
                    Spacer()
                    Button("Forget Hue Bridge…", role: .destructive) { confirmForget = true }
                        .disabled(!model.isPaired)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Forget this Hue Bridge?", isPresented: $confirmForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Bridge", role: .destructive) { model.forgetBridge() }
        } message: {
            Text("Glow will disconnect and remove its key. To use Glow again you'll pair by pressing the bridge button. Your lamps and Hue app are not changed.")
        }
    }

    private var statusText: String {
        if !model.isPaired { return "Not connected" }
        switch model.connection {
        case .live: return "Connected"
        case .connecting: return "Connecting…"
        case .offline(let reason): return reason
        }
    }
}
