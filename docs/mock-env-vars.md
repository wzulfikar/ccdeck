# Mock env vars

Screenshot/debug stubs for forcing specific UI states without waiting for the real
situation to occur (a rate limit, high usage, an upstream release). Switched on via the
`CCDECK_MOCK` environment variable — a comma-separated list of stub names.

Each stub is opt-in and inert when unset, so a normal run (no `CCDECK_MOCK`) behaves
exactly as shipped. The variable is parsed once at launch; changing it needs a relaunch.

Source: `Sources/ccdeck/Mock.swift`.

## Stubs

| Name | Effect |
|------|--------|
| `fake_update` | Pretends a newer release (`9.9.9`) exists → header shows the blue update down-arrow + `brew upgrade` popover. |
| `menubar_rate_limited` | Forces the menu-bar icon to the rate-limited state: 5-hour/7-day at 100% → **red** icon, `100%` text. |
| `menubar_70_pct` | Forces the menu-bar icon to 70% usage → **orange** icon, `70%` text. |

Notes:

- The menu-bar stubs apply in ascending severity, so listing both `menubar_70_pct` and
  `menubar_rate_limited` leaves the icon in the rate-limited (red) state.
- The `%` text only appears when **Settings ▸ Show usage % in menu bar** is on — enable it
  for those screenshots. The colored gauge icon shows regardless.
- Adding a new stub: add a flag in `Mock.swift` and read it at the relevant site.

## Running with stubs

Set the var when launching. Order of names doesn't matter.

Single stub:

```sh
CCDECK_MOCK=fake_update swift run
```

Multiple stubs:

```sh
CCDECK_MOCK=menubar_rate_limited,menubar_70_pct,fake_update swift run
```

### Launching a built `.app`

`open` does **not** pass your shell environment to the launched app — a plain
`CCDECK_MOCK=… open …` sets the var only for the `open` process, not the app. Use one of:

```sh
# open with the --env flag (detaches like a normal launch)
open --env CCDECK_MOCK=menubar_rate_limited,fake_update "dist/CC Deck (dev).app"

# or run the binary directly — plain shell env works, and you get logs in the terminal
CCDECK_MOCK=menubar_rate_limited,fake_update "dist/CC Deck (dev).app/Contents/MacOS/ccdeck"
```

Kill any running instance first, or LaunchServices reactivates the existing process
instead of relaunching with the new env:

```sh
killall ccdeck 2>/dev/null; killall "CC Deck (dev)" 2>/dev/null
```
