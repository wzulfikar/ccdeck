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

    private let controller: SPUStandardUpdaterController?

    private init() {
        isBrewManaged = Self.detectBrewInstall()
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

        if isBrewManaged || !hasFeed {
            controller = nil
            isActive = false
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

    /// A cask install leaves a metadata dir under the Homebrew Caskroom even though
    /// the `.app` itself is moved to /Applications, so this is a reliable signal that
    /// path-checking the bundle location can't give us. Covers both arch prefixes.
    private static func detectBrewInstall() -> Bool {
        ["/opt/homebrew/Caskroom/ccdeck", "/usr/local/Caskroom/ccdeck"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
}
