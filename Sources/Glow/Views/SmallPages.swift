import SwiftUI

/// Rename a lamp (only in Glow). Shown inside the popover; system alerts don't work reliably there.
@MainActor
struct RenameView: View {
    @Environment(AppModel.self) private var model
    let lampID: String
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Rename Lamp")
            if let lamp = model.lamps[lampID] {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(lamp.hueName, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)          // Return triggers Save (default action)
                    Text("This name is only used in Glow. Leave it empty to use the Hue name, \"\(lamp.hueName)\".")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.page = .lights }
                        Button("Save") { save(lamp) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .onAppear {
                    name = model.displayName(lamp)
                    focused = true
                }
            } else {
                Text("This lamp is no longer available.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(18)
            }
        }
    }

    private func save(_ lamp: Lamp) {
        model.rename(lamp, to: name)
        model.page = .lights
    }
}

/// "Are you sure?" before forgetting the bridge.
@MainActor
struct ConfirmForgetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Forget Hue Bridge?")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 18))
                    Text("Glow will disconnect from your bridge and remove its key. To use Glow again you'll have to pair again by pressing the button on the bridge.\n\nYour lamps, rooms and Hue app are not changed.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.page = .lights }
                        .keyboardShortcut(.cancelAction)
                    Button("Forget Bridge", role: .destructive) {
                        model.page = .lights
                        model.forgetBridge()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }
}
