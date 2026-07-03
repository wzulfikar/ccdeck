import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater and decides whether in-app updates should run at all.
///
/// Two gates keep the updater dormant when it shouldn't act:
///
///  1. **Homebrew installs.** A cask user's app is tracked by `brew`; if Sparkle
///     swapped the `.app` in place, `brew list`/`brew upgrade` would desync and
///     could later clobber the Sparkle-installed build. So when we detect a cask
///     install we never start Sparkle — those users update with `brew upgrade`.
///
///  2. **No feed configured.** `SUFeedURL`/`SUPublicEDKey` are only written into
///     Info.plist once the maintainer has generated an EdDSA key (see
///     docs/auto-update.md). Until then the framework is present but inert, and
///     starting it would just log feed errors — so we don't.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// True when the running app was installed via the Homebrew cask.
    let isBrewManaged: Bool

    /// True when Sparkle is actually driving updates (not brew-managed, feed present).
    let isActive: Bool

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu can enable/disable the
    /// "Check for Updates…" button (it's false briefly at launch and mid-check).
    @Published var canCheckForUpdates = false

    /// Latest upstream version (e.g. "0.1.7") when it's newer than the running build;
    /// nil while up to date or before the check completes. Only populated for Homebrew
    /// installs — Sparkle is inert there, so this is how the menu surfaces "a newer
    /// build exists, run `brew upgrade`". Never triggers a download or install.
    @Published var availableUpdate: String?

    private let controller: SPUStandardUpdaterController?

    /// GitHub Releases feed whose latest `tag_name` advertises the newest version.
    private static let releasesAPI = URL(string: "https://api.github.com/repos/wzulfikar/ccdeck/releases/latest")!

    private init() {
        isBrewManaged = Self.detectBrewInstall()
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

        if isBrewManaged || !hasFeed {
            controller = nil
            isActive = false
            // Sparkle stays off, but a brew install can still *check* GitHub Releases so
            // the menu can nudge `brew upgrade`. Check-only — nothing is downloaded.
            if isBrewManaged {
                Task { await self.checkForBrewUpdate() }
            }
            return
        }

        // startingUpdater: true → also schedules the periodic background check
        // configured by SUScheduledCheckInterval / SUEnableAutomaticChecks.
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        isActive = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Show the update dialog now (user-initiated; always presents UI).
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Running version, normalized to drop any leading "v" (e.g. "0.1.6").
    static var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return v.hasPrefix("v") ? String(v.dropFirst()) : v
    }

    /// Ask GitHub for the latest release tag; if it's newer than the running build,
    /// publish it so the menu can show the update affordance. Failures (offline, rate
    /// limit, malformed JSON) leave `availableUpdate` nil — no error surfaced.
    private func checkForBrewUpdate() async {
        var req = URLRequest(url: Self.releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isNewer(latest, than: Self.currentVersion) {
            availableUpdate = latest
        }
    }

    /// True when `lhs` is a strictly higher dotted version than `rhs`, compared numerically
    /// component-by-component (so "0.1.10" > "0.1.9", not a string compare). Missing
    /// trailing components read as 0.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A cask install leaves a metadata dir under the Homebrew Caskroom even though
    /// the `.app` itself is moved to /Applications, so this is a reliable signal that
    /// path-checking the bundle location can't give us. Covers both arch prefixes.
    private static func detectBrewInstall() -> Bool {
        ["/opt/homebrew/Caskroom/ccdeck", "/usr/local/Caskroom/ccdeck"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
}
