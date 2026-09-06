import SwiftUI

/// Stable per-model chart colors, derived from the model name.
///
/// The chart used to colour models by their index in the *present* model set, so the same
/// model changed colour whenever the window (today / 7d / 30d) contained a different mix.
/// A model now claims a palette slot from a hash of its name and keeps it: same colour in
/// every window, every launch, with no model table to update as new ones ship.
///
/// Swift's own `hashValue` is seeded per process and would drift between launches, hence
/// the hand-rolled FNV-1a. `AppModel` persists the claims (see `modelColorSlots`) so a model
/// that shows up later can never bump one that is already using its slot.
enum ModelColor {
    /// Hue steps around the wheel. 16 × 22.5° stays visually separable; more steps would
    /// put two models a few degrees apart and read as the same colour.
    private static let hues = 16
    /// Saturation/brightness tiers, tripling the palette without crowding the hues. All
    /// three are legible on the dark and the light popover background.
    private static let tiers: [(Double, Double)] = [(0.80, 0.95), (0.58, 0.78), (0.42, 1.0)]
    /// Total distinct colours. Past this many *distinct model names over the app's
    /// lifetime*, newcomers reuse a colour rather than displace anyone.
    static var slots: Int { hues * tiers.count }

    /// The slot `name` prefers, before considering who else is there.
    static func preferredSlot(for name: String) -> Int { Int(fnv1a(name) % UInt64(slots)) }

    /// The slot `name` gets given that `taken` are spoken for: its hashed slot, else the
    /// next free one. Returns the hashed slot when the palette is full (a duplicate colour
    /// beats evicting someone).
    static func claimSlot(for name: String, taken: Set<Int>) -> Int {
        let preferred = preferredSlot(for: name)
        guard taken.count < slots else { return preferred }
        var slot = preferred
        while taken.contains(slot) { slot = (slot + 1) % slots }
        return slot
    }

    /// Slot → colour. Hue advances fastest so neighbouring slots stay far apart in hue.
    static func color(slot: Int) -> Color {
        let (sat, bright) = tiers[(slot / hues) % tiers.count]
        return Color(hue: Double(slot % hues) / Double(hues), saturation: sat, brightness: bright)
    }

    /// Colour for a name with no claim on record — used only as a fallback for a model the
    /// chart draws before `AppModel` has registered it.
    static func color(for name: String) -> Color { color(slot: preferredSlot(for: name)) }

    /// FNV-1a over UTF-8 — deterministic across processes, unlike `Hashable`.
    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return h
    }
}
