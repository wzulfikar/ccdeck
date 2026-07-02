import SwiftUI
import AppKit

@main
struct CCDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No window scene — the UI lives entirely in the menu-bar popover, driven
        // from AppDelegate. Settings is an empty placeholder that never shows.
        Settings { EmptyView() }
    }
}

/// Owns the status-bar item + popover. We use AppKit directly (rather than SwiftUI's
/// MenuBarExtra) so we can: keep a Dock icon, open the popover programmatically on
/// launch, and reopen it when the Dock icon is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()

        // Create the updater on the main thread at launch so its background check
        // schedule starts (no-op for Homebrew installs / when no feed is configured).
        _ = AppUpdater.shared

        // Regular policy → Dock icon is visible and clickable.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.delegate = self
        // NSPopover would run its own resize animation when contentSize changes; we drive
        // the size ourselves frame-by-frame (below), so any built-in animation just fights
        // ours. Keep it off so the popover snaps to whatever size we set each frame.
        popover.animates = false
        // We size the popover manually instead of using `.preferredContentSize`:
        // NSHostingController's preferredContentSize does NOT sample intermediate frames of a
        // SwiftUI `withAnimation` — it jumps to the final size. That left the window at the
        // final height while the settings accordion was still mid-reveal (content overflowed
        // / repositioned inside a wrong-sized window → the drift). MenuView measures its real
        // rendered height with a GeometryReader, which fires every animation frame, and hands
        // it back here so the window tracks the content exactly.
        let host = NSHostingController(rootView: MenuView(model: model, onHeight: { [weak self] h in
            guard let self, h > 0 else { return }
            self.popover.contentSize = NSSize(width: 320, height: h)
        }))
        popover.contentViewController = host

        trackStatusButton()  // keep icon label/color in sync with live usage

        // Re-render every 10s so the "N min" reset countdown ticks down instead of
        // sticking at the value from the last 60s poll.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyStatusButton() }
        }

        // Show the menu-bar window on launch — same code path as clicking the icon.
        // Two things must hold first, and neither is ready this early in launch: the app
        // must be active (activation is async), and the status item must have taken its
        // slot in the menu bar. Show before the slot is assigned and the popover anchors
        // to the button's still-at-origin window → it appears in the bottom-left corner.
        // So poll every 100ms until both hold (button window off the origin == placed),
        // then show once; give up after ~3s so a background launch doesn't spin forever.
        showInitialWhenReady()
    }

    /// The status item's window sits at the screen origin until AppKit assigns it a
    /// menu-bar slot; once placed it moves to the top-right. A non-zero origin.x is our
    /// signal that the button can correctly anchor the popover.
    private var statusButtonIsPlaced: Bool {
        (statusItem.button?.window?.frame.origin.x ?? 0) > 0
    }

    private func showInitialWhenReady(deadline: Date = Date().addingTimeInterval(3)) {
        guard !popover.isShown, Date() < deadline else { return }
        if NSApp.isActive, statusButtonIsPlaced {
            showPopover()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showInitialWhenReady(deadline: deadline)
        }
    }

    /// Clicking the Dock icon toggles the popover: close it if shown, open it otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
        return true
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        // ⌥-click is a shortcut to flip keep-awake without opening the window.
        // Read the live modifier state (NSApp.currentEvent is unreliable for status items).
        if NSEvent.modifierFlags.contains(.option) {
            model.toggleStayAwake()
            return
        }
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // A `.transient` popover silently refuses to appear while the app isn't active
        // (the case on cold launch). Activate first, and surface the status-bar window so
        // it can anchor + become key.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The status message is transient flash feedback (e.g. "Captured: …"),
    /// so wipe it when the popover closes — it shouldn't linger on reopen.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in model.statusMessage = "" }
    }

    // MARK: - Status icon

    /// Re-render the status button whenever any observable it reads changes.
    private func trackStatusButton() {
        withObservationTracking {
            applyStatusButton()
        } onChange: {
            Task { @MainActor [weak self] in self?.trackStatusButton() }
        }
    }

    private func applyStatusButton() {
        guard let button = statusItem.button else { return }
        // When a reset is imminent the countdown takes over the slot — the usage %
        // is dropped so it's just "N min", no "60% 4 min" clutter.
        var title: String
        if let mins = model.soonestResetMinutes {
            title = "\(mins) min"
        } else {
            title = model.showUsageInMenuBar ? model.menuTitle : ""
        }

        // Render gauge + title into ONE image. Any non-white color (purple for keep-awake,
        // orange at ≥70%, red at 100%) is BAKED into the pixels as a non-template image;
        // only the plain white/safe state is a template the bar auto-recolors. We never tint
        // via contentTintColor — on this status button an explicit tint (dynamic OR concrete)
        // resolves dark-on-dark; baking sidesteps that entirely. Color + gauge come straight
        // from the model, which delegates to `MenuBarStyle` (see docs/menubar-states.md).
        button.image = statusImage(title: title,
                                   bakedColor: model.menuIconColor,
                                   symbolName: model.usageGaugeSymbol)
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
        updatePulse(button)
    }

    /// Pulse the status icon (opacity 1 ↔ 0.35) while the active account's first fetch is
    /// still loading, so the empty 0% gauge reads as "fetching" rather than "0% used".
    /// Driven from `applyStatusButton`, which re-runs whenever `menuBarIsLoading` changes.
    private func updatePulse(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        if model.menuBarIsLoading {
            guard button.layer?.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            button.layer?.add(pulse, forKey: "pulse")
        } else {
            button.layer?.removeAnimation(forKey: "pulse")
            button.layer?.opacity = 1
        }
    }

    /// Compose the gauge symbol + `title` into one NSImage. The image height is pinned to
    /// the symbol's height so the icon never shrinks when text is present. When
    /// `bakedColor` is nil the result is a template (only alpha matters, glyphs drawn
    /// black-but-opaque so the bar recolors them); when set, the symbol + text are drawn
    /// in that exact color and the image is NOT a template, so the color survives.
    private func statusImage(title: String, bakedColor: NSColor?, symbolName: String) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        var symbolCfg = NSImage.SymbolConfiguration(pointSize: font.pointSize + 2, weight: .regular)
        if let bakedColor {
            symbolCfg = symbolCfg.applying(NSImage.SymbolConfiguration(paletteColors: [bakedColor]))
        }
        let symbol = (NSImage(systemSymbolName: symbolName,
                              accessibilityDescription: "CC Deck")?
            .withSymbolConfiguration(symbolCfg) ?? NSImage())
        let symbolSize = symbol.size

        // For a template, color is irrelevant (only alpha sampled) but glyphs must be
        // opaque so the bar can recolor them; for a baked image, draw text in the color.
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: bakedColor ?? NSColor.black]
        let text = title as NSString
        let textSize = title.isEmpty ? .zero : text.size(withAttributes: textAttrs)
        let gap: CGFloat = title.isEmpty ? 0 : 4

        let height = symbolSize.height            // pin to symbol so the icon stays full-size
        let width = symbolSize.width + gap + textSize.width

        // Draw via lockFocus into a concrete image so the baked alpha exists immediately.
        // A `drawingHandler`-based NSImage renders its body lazily, and the status bar
        // can't introspect its alpha to honor `isTemplate` — so it tints the image dark
        // instead of auto-recoloring it. An eager bitmap makes `isTemplate` reliable.
        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)))
        image.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        if !title.isEmpty {
            text.draw(at: NSPoint(x: symbolSize.width + gap, y: (height - textSize.height) / 2),
                      withAttributes: textAttrs)
        }
        image.unlockFocus()
        image.isTemplate = bakedColor == nil
        return image
    }
}
