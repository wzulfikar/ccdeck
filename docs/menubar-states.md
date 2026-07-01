# Menu-bar states

How the CC Deck menu-bar item renders, and what each state means. The icon is the
`gauge.with.dots.needle.*` SF Symbol.

Two different usage numbers drive the item, on purpose:

- The **`%` label and the gauge needle** always show the active account's **5-hour** window
  — the live burn rate you're spending right now.
- The **color** is keyed on the **worst window** (max of 5-hour and 7-day), so it warns on
  whichever limit binds first. In particular **red is a hard stop from *either* window**:
  if the 7-day cap is exhausted the icon goes red while the number/gauge still show the
  (possibly low) 5-hour usage.

## Show usage % in menu bar (setting)

Toggled from **Settings ▸ Show usage % in menu bar**. **Off by default.**

- **Off** — no text; the gauge icon alone conveys usage. The needle tracks usage, bucketed
  into the variants Apple ships (`0`, `33`, `50`, `67`, `100` percent):

  | Usage   | Gauge          |
  |---------|----------------|
  | 0–10%   | `needle.0percent`   |
  | 11–40%  | `needle.33percent`  |
  | 41–50%  | `needle.50percent`  |
  | 51–80%  | `needle.67percent`  |
  | 81–100% | `needle.100percent` |

  Usage here is the active account's **5-hour** window — e.g. an account at 16% (5-hour) /
  64% (7-day) shows the 33% gauge, keyed on the 16%.
- **On** — the `%` is shown as text next to the icon (e.g. `⌁ 84%`), and the gauge is
  **static at 50%** (decorative; the number carries the meaning).

## Color states

The icon and text share one color, keyed on the **worst window** (max of 5-hour and 7-day):

| Worst window | Color                                          |
|--------------|------------------------------------------------|
| < 70%        | Normal — black in light mode, white in dark    |
| 70–99%       | Orange                                         |
| 100%         | Red — hard stop from either the 5-hour or 7-day limit |

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
- The color + gauge decisions live in `MenuBarStyle` (pure, unit-tested in
  `Tests/ccdeckTests/MenuBarStyleTests.swift`). `AppModel.menuIconColor` /
  `AppModel.usageGaugeSymbol` feed it live state; `AppDelegate.applyStatusButton` /
  `statusImage` render the result.
