// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Embed Info.plist in the binary so that running straight from Xcode / `swift run`
// still has the local-network permission text and Bonjour service declaration.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "Glow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glow",
            path: "Sources/Glow",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
