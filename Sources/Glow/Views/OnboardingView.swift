import SwiftUI

/// First run: find the Hue Bridge and pair by pressing its button,
/// or reuse a key another app (e.g. Home Assistant) already has.
@MainActor
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""
    @State private var showKeyForm = OnboardingView.previewKeyForm
    /// Snapshot hook: start with the key form open.
    nonisolated(unsafe) static var previewKeyForm = false
    @State private var keyHost = ""
    @State private var existingKey = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lightbulb.2.fill")
                .font(.system(size: 30))
                .foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .bottom, endPoint: .top))
                .padding(.top, 8)
            Text("Connect Glow to Hue")
                .font(.system(size: 15, weight: .semibold))

            Group {
                switch model.onboarding {
                case .searching:
                    status("Looking for your Hue Bridge…", spinner: true)
                case .choose(let bridges):
                    choose(bridges)
                case .waitingForButton(let host, let until):
                    waiting(host: host, until: until)
                case .checkingKey(let host):
                    status("Checking the key with the bridge at \(host)…", spinner: true)
                case .failed(let message):
                    failed(message)
                }
            }
            .frame(maxWidth: .infinity)

            if model.onboarding != .searching, !isCheckingKey {
                existingKeySection
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private func status(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func choose(_ bridges: [DiscoveredBridge]) -> some View {
        if bridges.isEmpty {
            Text("No bridge found automatically. Make sure this Mac is on the same Wi‑Fi as your bridge, or enter its IP address (shown in the Hue app under Settings → Bridges).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                ForEach(bridges) { bridge in
                    Button {
                        model.pair(with: bridge.host)
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Hue Bridge at \(bridge.host)")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        manualEntry
        Button("Search Again") { model.beginOnboarding(autoPair: false) }
            .buttonStyle(.link)
            .font(.system(size: 12))
    }

    private func waiting(host: String, until: Date) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.06)).frame(width: 74, height: 74)
                Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2).frame(width: 38, height: 38)
                    .symbolEffectPulse()
            }
            Text("Press the round button on top of your Hue Bridge.")
                .font(.system(size: 12.5, weight: .medium))
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                status("Listening for the button… \(left / 60):\(String(format: "%02d", left % 60)) left", spinner: true)
            }
            Button("Cancel") { model.cancelPairing() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func failed(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if model.isBlockedByLocalNetworkPrivacy {
            Button("Open Local Network Settings") { AppModel.openLocalNetworkSettings() }
                .controlSize(.regular)
        }
        Button("Try Again") { model.retryPairing() }
            .controlSize(.regular)
        manualEntry
    }

    private var isCheckingKey: Bool {
        if case .checkingKey = model.onboarding { return true }
        return false
    }

    /// The bridge address to prefill: the one being paired, else the first one found.
    private var bridgeHostGuess: String {
        if case .waitingForButton(let host, _) = model.onboarding { return host }
        return model.suggestedHost.isEmpty ? manualHost : model.suggestedHost
    }

    @ViewBuilder
    private var existingKeySection: some View {
        Divider()
        if showKeyForm {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use an existing key")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Paste the Hue app key (also called \"username\" or \"api_key\") from another app that's already paired with this bridge, such as Home Assistant.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Bridge IP, e.g. 192.168.1.20", text: $keyHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                SecureField("Hue app key", text: $existingKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(useKey)
                HStack {
                    Button("Cancel") { showKeyForm = false }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    Spacer()
                    Button("Use Key", action: useKey)
                        .keyboardShortcut(.defaultAction)
                        .disabled(keyHost.trimmingCharacters(in: .whitespaces).isEmpty
                                  || existingKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if keyHost.isEmpty { keyHost = bridgeHostGuess } }
        } else {
            Button("Already have a Hue key from another app?") {
                keyHost = bridgeHostGuess
                showKeyForm = true
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    private func useKey() {
        guard !keyHost.isEmpty, !existingKey.isEmpty else { return }
        model.useExistingKey(host: keyHost, key: existingKey)
        existingKey = ""
        showKeyForm = false
    }

    private var manualEntry: some View {
        HStack(spacing: 6) {
            TextField("Bridge IP, e.g. 192.168.1.20", text: $manualHost)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { model.pair(with: manualHost) }
            Button("Connect") { model.pair(with: manualHost) }
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private extension View {
    /// A gentle "breathing" animation for the bridge-button illustration.
    func symbolEffectPulse() -> some View {
        modifier(Pulse())
    }
}

private struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        // The endless animation is scoped to scale and opacity only. Applied to the whole view, it also
        // picked up the circle's position while the window was still settling, and the ring kept
        // sliding between the corner and the middle.
        content
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                $0.scaleEffect(on ? 1.15 : 0.9).opacity(on ? 1 : 0.5)
            }
            .onAppear { on = true }
    }
}
