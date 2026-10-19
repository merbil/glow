#if DEBUG
import AppKit
import SwiftUI

/// Renders the app icon at every size macOS wants:  Glow --render-icon <AppIcon.iconset>
/// then: iconutil -c icns <AppIcon.iconset> -o Resources/AppIcon.icns
@MainActor
enum IconRenderer {
    struct Icon: View {
        var body: some View {
            // macOS icon grid: 824×824 rounded square centered on a 1024 canvas.
            ZStack {
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.27),
                                                  Color(red: 0.05, green: 0.05, blue: 0.11)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 4))
                // the glow
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.85),
                                                  Color(red: 1.0, green: 0.55, blue: 0.20).opacity(0.0)],
                                         center: .center, startRadius: 10, endRadius: 330))
                    .frame(width: 660, height: 660)
                    .offset(y: -40)
                Image(systemName: "lightbulb.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 330, height: 430)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.62),
                                                             Color(red: 1.0, green: 0.68, blue: 0.24)],
                                                    startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.9), radius: 40)
                    .offset(y: -10)
            }
            .frame(width: 824, height: 824)
            .frame(width: 1024, height: 1024)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
    }

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            let renderer = ImageRenderer(content: Icon().scaleEffect(px / 1024).frame(width: px, height: px))
            renderer.scale = 1
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        print("Wrote \(sizes.count) icon sizes to \(dir.path)")
    }
}
#endif
