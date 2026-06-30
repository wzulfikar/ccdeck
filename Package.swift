// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ccswitch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ccswitch",
            path: "Sources/ccswitch",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
