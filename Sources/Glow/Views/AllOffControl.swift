import AppKit
import SwiftUI

/// "All off ▾" with delay options; becomes a countdown pill while a timer runs.
@MainActor
struct AllOffControl: View {
    @Environment(AppModel.self) private var model

    private static let delays: [(label: String, minutes: Int)] = [
        ("In 5 minutes", 5), ("In 15 minutes", 15), ("In 30 minutes", 30), ("In 1 hour", 60),
    ]

    var body: some View {
        Group {
            if let fireDate = model.timerFireDate {
                countdown(until: fireDate)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                menu
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.timerFireDate)
    }

    private var menu: some View {
        Menu {
            Section("Turn all lights off…") {
                Button("Now") { model.allOffNow() }
            }
            Divider()
            ForEach(Self.delays, id: \.minutes) { delay in
                Button(delay.label) { model.scheduleAllOff(minutes: delay.minutes) }
            }
        } label: {
            // A single Text keeps the chevron after the title; menu labels reorder images.
            (Text("All off  ") + Text(Image(systemName: "chevron.down")).font(.system(size: 8, weight: .bold)))
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(PillShape(fill: Color.primary.opacity(0.10), stroke: Color.primary.opacity(0.10)))
        .contentShape(Capsule())
    }

    private func countdown(until fireDate: Date) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Off in \(Self.format(fireDate.timeIntervalSince(context.date)))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            Button {
                model.cancelTimer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.orange.opacity(0.25)))
                    .frame(width: 24, height: 24)          // larger click target
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel the timer")
            .accessibilityLabel("Cancel the timer")
        }
        .foregroundStyle(Self.countdownText)
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .accessibilityElement(children: .contain)
        .frame(height: 28)
        .background(PillShape(fill: Color.orange.opacity(0.16), stroke: Color.orange.opacity(0.45)))
    }

    /// System orange is too faint on a light background; use a deeper orange there (WCAG AA).
    private static let countdownText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange : NSColor(srgbRed: 0.62, green: 0.30, blue: 0.0, alpha: 1)
    })

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Capsule background with a hairline border, drawn as one layer.
private struct PillShape: View {
    let fill: Color
    let stroke: Color
    var body: some View {
        Capsule().fill(fill).overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
    }
}
