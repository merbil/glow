import SwiftUI
import UniformTypeIdentifiers

/// Arrange & Hide: drag rooms and lamps into the order you like, and hide what you don't need.
/// (Kept separate from the lights page, where dragging a tile sideways sets brightness.)
@MainActor
struct ArrangeView: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Arrange & Hide", trailing: AnyView(
                Button("Done") { model.page = .lights }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            ))
            Text("Drag rooms and lamps to reorder them. Use the eye to hide things you don't need. This only changes Glow, not your Hue setup.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    ForEach(model.sections(includeHidden: true)) { section in
                        roomCard(section)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: Metrics.maxListHeight)

            Divider().padding(.horizontal, 14)
            HStack {
                Button("Reset Order") { withAnimation { model.resetArrangement() } }
                Spacer()
                if model.hiddenCount > 0 {
                    Button("Show All") { withAnimation { model.unhideAll() } }
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .onDisappear { dragging = nil }
    }

    private func roomCard(_ section: LampSection) -> some View {
        VStack(spacing: 2) {
            // Room row: drag handle, name, eye.
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                eyeButton(hidden: section.isHidden, label: section.title) {
                    model.setRoomHidden(section.id, !section.isHidden)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onDrag {
                dragging = "room:" + section.id
                return NSItemProvider(object: ("room:" + section.id) as NSString)
            }
            .onDrop(of: [UTType.text], delegate: ReorderDrop(target: "room:" + section.id,
                                                              dragging: $dragging, model: model))
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                Button("Move \(section.title) up") { model.moveRoom(section.id, by: -1) }
                Button("Move \(section.title) down") { model.moveRoom(section.id, by: 1) }
            }

            // Lamp rows.
            ForEach(section.lamps) { lamp in
                let hidden = model.hiddenLampIDs.contains(lamp.id)
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Circle()
                        .fill(lamp.isOn && lamp.isReachable ? HueColor.rgb(for: lamp).color : Color.primary.opacity(0.15))
                        .frame(width: 10, height: 10)
                    Text(model.displayName(lamp))
                        .font(.system(size: 12))
                        .strikethrough(hidden, color: .secondary)
                        .foregroundStyle(hidden ? .secondary : .primary)
                    Spacer()
                    eyeButton(hidden: hidden, label: model.displayName(lamp)) {
                        model.setLampHidden(lamp, !hidden)
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onDrag {
                    dragging = "lamp:" + lamp.id
                    return NSItemProvider(object: ("lamp:" + lamp.id) as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDrop(target: "lamp:" + lamp.id,
                                                                  dragging: $dragging, model: model))
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .opacity(section.isHidden ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: model.sections(includeHidden: true).map(\.id))
    }

    private func eyeButton(hidden: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { action() } }) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .font(.system(size: 12))
                .foregroundStyle(hidden ? .secondary : .primary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hidden ? "Show \(label)" : "Hide \(label)")
        .accessibilityLabel(hidden ? "Show \(label)" : "Hide \(label)")
    }
}

/// Live reordering while dragging: rooms move among rooms, lamps among lamps of the same room.
@MainActor
private struct ReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        // Only our own drags (a stale state from a cancelled drag must not reorder anything).
        dragging != nil && info.hasItemsConforming(to: [UTType.text])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), let dragging, dragging != target else { return }
        let (kind, id) = split(dragging)
        let (targetKind, targetID) = split(target)
        guard kind == targetKind else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if kind == "room" { model.moveRoom(id, to: targetID) } else { model.moveLamp(id, to: targetID) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    private func split(_ value: String) -> (String, String) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}
