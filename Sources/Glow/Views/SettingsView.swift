import SwiftUI

/// The Glow Settings window (Settings… / ⌘, in the gear menu).
@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 480, height: 520)
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
