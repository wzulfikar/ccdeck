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

        // Regular policy → Dock icon is visible and clickable.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: MenuView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        trackStatusButton()  // keep icon label/color in sync with live usage

        // Re-render every 10s so the "N min" reset countdown ticks down instead of
        // sticking at the value from the last 60s poll.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyStatusButton() }
        }

        showPopover()        // show the menu-bar window on launch
    }

    /// Clicking the Dock icon (whether or not a window is open) reopens the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPopover()
        return true
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
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

        // Render gauge + title into ONE template image and let the menu-bar machinery
        // recolor it. This is the only reliable path: an SF-Symbol template image
        // auto-colors to the true bar appearance (white on dark) — that's what made the
        // bare icon correct — whereas any title set via `attributedTitle`/`title`, or a
        // hand-picked tint from `effectiveAppearance` (which lies .aqua here), renders
        // dark-on-dark. Baking the text into the same template makes it follow the icon.
        button.image = statusImage(title: title)
        button.imagePosition = .imageOnly
        // nil → bar auto-colors (white on dark / black on light); ≥70% stamps orange.
        button.contentTintColor = model.menuIconColor
    }

    /// Compose the gauge symbol + `title` into a single template NSImage. The image
    /// height is pinned to the symbol's height so the icon never shrinks when text is
    /// present. Drawing color is irrelevant for a template (only alpha is used).
    private func statusImage(title: String) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: font.pointSize + 2, weight: .regular)
        let symbol = (NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                              accessibilityDescription: "CC Deck")?
            .withSymbolConfiguration(symbolCfg) ?? NSImage())
        let symbolSize = symbol.size

        // Color is irrelevant for a template image (only alpha is sampled), but the glyphs
        // must be fully opaque so the menu-bar machinery can recolor them white-on-dark.
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
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
        image.isTemplate = true
        return image
    }
}
