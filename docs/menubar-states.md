# Menu-bar states

How the CC Deck menu-bar item renders, and what each state means. The icon is the
`gauge.with.dots.needle.*` SF Symbol; usage always refers to the **active account's worst
window** (max of the 5-hour and 7-day percentages) — the same value shown as the compact
`%` label.

## Show usage % in menu bar (setting)

Toggled from **Settings ▸ Show usage % in menu bar**. **Off by default.**

- **Off** — no text; the gauge icon alone conveys usage. The needle tracks usage, snapped
  to the variants Apple ships (`0`, `33`, `50`, `67`, `100` percent):
  - 0% usage → needle points bottom-left (`needle.0percent`)
  - higher usage → needle sweeps toward full (`needle.100percent`)
- **On** — the `%` is shown as text next to the icon (e.g. `⌁ 84%`), and the gauge is
  **static at 50%** (decorative; the number carries the meaning).

## Color states

The icon and text share one color, keyed on usage:

| Usage      | Color                                          |
|------------|------------------------------------------------|
| < 70%      | Normal — black in light mode, white in dark    |
| 70–99%     | Orange                                          |
| 100%       | Red                                             |

When **Stay awake** is on, the icon and text are **purple**, overriding the usage color
above. Purple is a distinct "mode" signal, not a usage warning.

## Imminent reset

When the soonest upcoming reset (any account, either window) is **5 minutes or less**
away, the countdown takes over the text slot regardless of the usage-% setting — e.g.
`⌁ 5 min` — instead of the usage number. The gauge icon is unchanged.

## Interactions

- **Click** — opens the popover window.
- **⌥-click (Option)** — toggles Stay awake without opening the window. (⌘-click is
  reserved by macOS for dragging menu-bar items, so Option is used instead.)

## Implementation notes

- Colors are **baked into the image pixels** as a non-template `NSImage`, not applied via
  `contentTintColor`. On the status button an explicit tint (dynamic *or* concrete)
  resolves against a lying `.aqua` appearance and renders dark-on-dark; baking sidesteps
  it. The plain < 70% state is left as a template so the bar auto-recolors it
  white-on-dark / black-on-light.
- Concrete sRGB colors are used (not `.systemOrange` / `.systemRed` / `.systemPurple`) for
  the same appearance-resolution reason.
- See `AppModel.menuIconColor`, `AppModel.usageGaugeSymbol`, and
  `AppDelegate.applyStatusButton` / `statusImage`.
