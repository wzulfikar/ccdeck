import Foundation
import Testing

/// End-to-end tests for the build/bundle/release scripts. They shell out to the
/// real scripts and inspect the dist/ artifacts, so they take minutes and are
/// gated behind CCDECK_SLOW_TESTS=1 — run them via `./scripts/test.sh --slow`.
/// A plain `swift test` reports them as skipped.
///
/// Nothing here notarizes or publishes: bundle.sh runs with --no-notarize and
/// release.sh runs with --dry-run, and the release test asserts that a dry run
/// leaves no tag or commit behind.
private let slowEnabled = ProcessInfo.processInfo.environment["CCDECK_SLOW_TESTS"] == "1"

/// Repo root, derived from this file's location (Tests/ccdeckScriptTests/…).
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // ScriptTests.swift
    .deletingLastPathComponent()   // ccdeckScriptTests
    .deletingLastPathComponent()   // Tests -> repo root

@discardableResult
private func sh(_ command: String) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = repoRoot
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func plistValue(_ app: String, _ key: String) throws -> String {
    try sh("/usr/libexec/PlistBuddy -c 'Print :\(key)' '\(app)/Contents/Info.plist'")
        .out.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func exists(_ relativePath: String) -> Bool {
    FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(relativePath).path)
}

private func readFile(_ relativePath: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
}

// .serialized: the tests share dist/ and build state, so they must not run in
// parallel; serialized suites also run in source order, which later tests rely
// on (earlier tests leave a prod build in dist/).
@Suite("scripts (slow)", .serialized, .enabled(if: slowEnabled))
struct ScriptTests {

    // MARK: build.sh

    @Test("build.sh produces an isolated dev bundle")
    func buildDev() throws {
        let r = try sh("./scripts/build.sh")
        #expect(r.status == 0, "build.sh failed:\n\(r.out)")

        let app = "dist/CC Deck (dev).app"
        #expect(exists(app))
        #expect(exists("\(app)/Contents/MacOS/ccdeck"))
        #expect(try plistValue(app, "CFBundleIdentifier") == "com.wzulfikar.ccdeck.dev")
        #expect(try plistValue(app, "CFBundleName") == "CC Deck (dev)")

        // A dev build must never carry a Sparkle feed — it would eventually
        // auto-update itself into the production app.
        let feed = try sh("/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' '\(app)/Contents/Info.plist'")
        #expect(feed.status != 0, "dev build unexpectedly has SUFeedURL")

        // Signature (ad-hoc or ccdeck-dev) must at least verify.
        #expect(try sh("codesign --verify --strict '\(app)'").status == 0)
    }

    @Test("build.sh --prod produces the prod bundle plus a freshness manifest")
    func buildProd() throws {
        let r = try sh("./scripts/build.sh --prod")
        #expect(r.status == 0, "build.sh --prod failed:\n\(r.out)")

        let app = "dist/CC Deck.app"
        #expect(exists(app))
        #expect(try plistValue(app, "CFBundleIdentifier") == "com.wzulfikar.ccdeck")

        // Prod and dev bundles coexist in dist/ — building one must not clobber the other.
        #expect(exists("dist/CC Deck (dev).app"))

        let manifest = try readFile("dist/.prod-build.manifest")
        #expect(manifest.contains("version=v"))
        let head = try sh("git rev-parse HEAD").out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(manifest.contains("sha=\(head)"), "manifest sha should match HEAD")
    }

    @Test("build.sh rejects unknown flags")
    func buildUsage() throws {
        let r = try sh("./scripts/build.sh --nope")
        #expect(r.status != 0)
        #expect(r.out.contains("usage:"))
    }

    // MARK: bundle.sh

    @Test("bundle.sh --no-build fails when there is no prod build")
    func bundleRequiresProdBuild() throws {
        try sh("rm -rf 'dist/CC Deck.app' dist/.prod-build.manifest dist/ccdeck.dmg dist/.bundle.manifest")
        let r = try sh("./scripts/bundle.sh --no-build --no-notarize")
        #expect(r.status != 0)
        #expect(r.out.contains("no production build"))
    }

    @Test("bundle.sh --no-notarize triggers a prod build and produces a valid dmg")
    func bundleProducesDmg() throws {
        let r = try sh("./scripts/bundle.sh --no-notarize")
        #expect(r.status == 0, "bundle.sh failed:\n\(r.out)")

        #expect(exists("dist/ccdeck.dmg"))
        #expect(try sh("hdiutil verify dist/ccdeck.dmg").status == 0)

        // Mount it and confirm the app is inside, then detach.
        let mount = try sh("""
            m=$(hdiutil attach -nobrowse -readonly dist/ccdeck.dmg | awk -F'\\t' 'END{print $NF}')
            test -d "$m/CC Deck.app"; ok=$?
            hdiutil detach "$m" -quiet
            exit $ok
            """)
        #expect(mount.status == 0, "dmg does not contain CC Deck.app:\n\(mount.out)")

        let manifest = try readFile("dist/.bundle.manifest")
        #expect(manifest.contains("notarized=0"))
    }

    @Test("bundle.sh --no-build reuses the existing prod build")
    func bundleNoBuildReuses() throws {
        // Prod build exists from the previous tests; --no-build must succeed
        // without invoking swift build (heuristic: it is fast and skips the
        // "==> build variant" log line).
        let r = try sh("./scripts/bundle.sh --no-build --no-notarize")
        #expect(r.status == 0, "\(r.out)")
        #expect(!r.out.contains("==> build variant"))
    }

    // MARK: release.sh

    @Test("release.sh --no-bundle fails without a bundle, and refuses an un-notarized one")
    func releaseGuards() throws {
        // No dmg at all -> hard fail.
        try sh("rm -f dist/ccdeck.dmg dist/.bundle.manifest")
        let missing = try sh("./scripts/release.sh --no-bundle --dry-run")
        #expect(missing.status != 0)
        #expect(missing.out.contains("no bundle found"))

        // Recreate an un-notarized bundle -> refused (protects users from a
        // Gatekeeper-blocked download).
        try sh("./scripts/bundle.sh --no-build --no-notarize")
        let unnotarized = try sh("./scripts/release.sh --no-bundle --dry-run")
        #expect(unnotarized.status != 0)
        #expect(unnotarized.out.contains("--no-notarize"))
    }

    @Test("release.sh --dry-run plans the full pipeline without tagging or committing")
    func releaseDryRun() throws {
        let tagsBefore = try sh("git tag").out
        let headBefore = try sh("git rev-parse HEAD").out

        let r = try sh("./scripts/release.sh v99.99.99 --dry-run")
        #expect(r.status == 0, "\(r.out)")
        #expect(r.out.contains("releasing v99.99.99"))
        // The plan must cover every publish surface.
        #expect(r.out.contains("bundle.sh"))
        #expect(r.out.contains("git tag v99.99.99"))
        #expect(r.out.contains("gh release create v99.99.99"))
        #expect(r.out.contains("appcast"))
        #expect(r.out.contains("homebrew-tap"))

        // …and must have zero side effects.
        #expect(try sh("git tag").out == tagsBefore)
        #expect(try sh("git rev-parse HEAD").out == headBefore)
        #expect(try sh("git rev-parse -q --verify refs/tags/v99.99.99").status != 0)
    }

    // MARK: reset.sh

    @Test("reset.sh --dry-run plans a full cleanup with zero side effects")
    func resetDryRun() throws {
        let r = try sh("./scripts/reset.sh --dry-run")
        #expect(r.status == 0, "\(r.out)")
        // Plans both variants and every cleanup surface…
        #expect(r.out.contains("com.wzulfikar.ccdeck.dev"))
        #expect(r.out.contains("tccutil reset All com.wzulfikar.ccdeck"))
        #expect(r.out.contains("keychain"))
        #expect(r.out.contains("defaults delete"))
        // …but touches nothing: artifacts from the earlier tests must survive.
        #expect(exists("dist/ccdeck.dmg"))
        #expect(exists("dist/CC Deck.app"))
    }

    @Test("reset.sh aborts without confirmation and rejects unknown flags")
    func resetGuards() throws {
        let aborted = try sh("echo no | ./scripts/reset.sh --dev")
        #expect(aborted.status != 0)
        #expect(aborted.out.contains("aborted"))
        let usage = try sh("./scripts/reset.sh --nope")
        #expect(usage.status != 0)
        #expect(usage.out.contains("usage:"))
    }

    @Test("release.sh refuses a version whose tag already exists")
    func releaseRefusesExistingTag() throws {
        let existing = try sh("git tag -l 'v*' | sort -V | tail -1")
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!existing.isEmpty, "repo has no v* tags to test against")
        let r = try sh("./scripts/release.sh \(existing) --dry-run")
        #expect(r.status != 0)
        #expect(r.out.contains("already exists"))
    }
}
