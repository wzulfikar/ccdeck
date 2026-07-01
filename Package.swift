// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ccdeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update framework. Shipped as a binary xcframework; `swift build`
        // drops Sparkle.framework into the build bin dir, which create_app_bundle.sh
        // embeds into Contents/Frameworks and re-signs.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Shared XPC protocol + identifiers, used by both the app and the helper.
        .target(
            name: "HelperShared",
            path: "Sources/HelperShared"
        ),
        .executableTarget(
            name: "ccdeck",
            dependencies: [
                "HelperShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ccdeck",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // The bundle carries Sparkle.framework in Contents/Frameworks; this
                // rpath lets the executable find it when run from the .app (SPM only
                // wires an absolute build-dir rpath, which is gone after packaging).
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
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
        // Unit tests for the pure presentation/model logic (no AppKit UI, SQLite, or
        // Keychain touched). Runs headless via `swift test`.
        .testTarget(
            name: "ccdeckTests",
            dependencies: ["ccdeck"],
            path: "Tests/ccdeckTests"
        ),
    ]
)
