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

    var body: some View {
        Group {
            if !model.isPaired {
                OnboardingView()
            } else {
                switch model.page {
                case .lights: LightsView()
                case .arrange: ArrangeView()
                case .rename(let id): RenameView(lampID: id)
                case .confirmForget: ConfirmForgetView()
                }
            }
        }
        .frame(width: Metrics.popoverWidth)
        .background(SettingsOpener())
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
