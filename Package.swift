// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ccdeck",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared XPC protocol + identifiers, used by both the app and the helper.
        .target(
            name: "HelperShared",
            path: "Sources/HelperShared"
        ),
        .executableTarget(
            name: "ccdeck",
            dependencies: ["HelperShared"],
            path: "Sources/ccdeck",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Privileged root helper (SMAppService daemon). Its bundle identifier is
        // embedded as an __info_plist Mach-O section so it has a stable code
        // signing identity.
        .executableTarget(
            name: "ccdeck-helper",
            dependencies: ["HelperShared"],
            path: "Sources/ccdeck-helper",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ccdeck-helper/Info.plist",
                ])
            ]
        ),
    ]
)
