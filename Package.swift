// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceFlow", targets: ["VoiceFlow"])
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceFlow",
            dependencies: ["Starscream"],
            path: "Sources",
            exclude: ["Info.plist"]
        )
    ]
)
