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
        // orange at ≥70%) is BAKED into the pixels as a non-template image; only the plain
        // white/safe state is a template the bar auto-recolors. We never tint via
        // contentTintColor — on this status button an explicit tint (dynamic OR concrete)
        // resolves dark-on-dark; baking sidesteps that entirely. Keep-awake wins over the
        // usage color.
        let bakedColor: NSColor? = model.shouldStayAwake
            ? NSColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1)  // ~systemPurple
            : model.menuIconColor                                          // orange ≥70%, else nil
        button.image = statusImage(title: title, bakedColor: bakedColor)
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
    }

    /// Compose the gauge symbol + `title` into one NSImage. The image height is pinned to
    /// the symbol's height so the icon never shrinks when text is present. When
    /// `bakedColor` is nil the result is a template (only alpha matters, glyphs drawn
    /// black-but-opaque so the bar recolors them); when set, the symbol + text are drawn
    /// in that exact color and the image is NOT a template, so the color survives.
    private func statusImage(title: String, bakedColor: NSColor?) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        var symbolCfg = NSImage.SymbolConfiguration(pointSize: font.pointSize + 2, weight: .regular)
        if let bakedColor {
            symbolCfg = symbolCfg.applying(NSImage.SymbolConfiguration(paletteColors: [bakedColor]))
        }
        let symbol = (NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
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
