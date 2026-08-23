// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vpnks",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "vpnks",
            path: "Sources/vpnks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
