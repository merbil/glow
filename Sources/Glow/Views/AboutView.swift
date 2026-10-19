import SwiftUI

/// About Glow (Settings tab): version, and the release notes bundled with the app.
@MainActor
struct AboutTab: View {
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .bottom, endPoint: .top))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.07)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Glow").font(.system(size: 16, weight: .semibold))
                            Text(AppInfo.display)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Your Hue lamps, one click away.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    let notes = ReleaseNotes.all
                    if notes.isEmpty {
                        Text("Release notes aren't available in this build.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(showAll ? notes : Array(notes.prefix(1))) { release in
                            ReleaseView(release: release, isCurrent: release.version == AppInfo.version)
                        }
                        if notes.count > 1 {
                            Button(showAll ? "Show only the latest" : "Show all versions (\(notes.count))") {
                                withAnimation { showAll.toggle() }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

@MainActor
private struct ReleaseView: View {
    let release: ReleaseNotes.Release
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(release.title).font(.system(size: 13, weight: .semibold))
                if isCurrent {
                    Text("Installed")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                }
            }
            ForEach(Array(release.lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(text.uppercased())
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                case .bullet(let text, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(level == 0 ? "•" : "◦").foregroundStyle(.secondary)
                        Text(ReleaseNotes.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .padding(.leading, CGFloat(level) * 14)
                case .text(let text):
                    Text(ReleaseNotes.inline(text))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Reads RELEASE_NOTES.md (bundled in the app's Resources by scripts/build-app.sh).
enum ReleaseNotes {
    enum Line { case heading(String), bullet(String, level: Int), text(String) }

    struct Release: Identifiable {
        let title: String
        let version: String
        var lines: [Line]
        var id: String { title }
    }

    /// Loaded once; the file doesn't change while the app runs.
    @MainActor static let all: [Release] = load()

    static func load() -> [Release] {
        var url = Bundle.main.url(forResource: "RELEASE_NOTES", withExtension: "md")
        #if DEBUG
        if url == nil {   // running from `swift build`: use the repository copy
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../RELEASE_NOTES.md").standardized
        }
        #endif
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3))
                let version = title.split(separator: " ").first.map(String.init) ?? title
                releases.append(Release(title: title, version: version, lines: []))
            } else if releases.isEmpty || line.isEmpty || line.hasPrefix("# ") {
                continue
            } else if line.hasPrefix("### ") {
                releases[releases.count - 1].lines.append(.heading(String(line.dropFirst(4))))
            } else if line.hasPrefix("- ") {
                releases[releases.count - 1].lines.append(.bullet(String(line.dropFirst(2)), level: indent >= 2 ? 1 : 0))
            } else {
                releases[releases.count - 1].lines.append(.text(line))
            }
        }
        return releases
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
