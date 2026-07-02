# Stay-awake helper

The "Stay awake" button keeps the Mac awake in two layers:

- **`StayAwake.swift`** (app target) — IOKit
  `kIOPMAssertionTypePreventUserIdleSystemSleep` power assertion (`caffeinate -i`).
  Blocks ordinary idle sleep on **AC and battery**. No privileges, no prompt.
  (The `…PreventSystemSleep` / `caffeinate -s` variant is AC-only — on battery
  macOS ignores it, so it must not be used here.)
- **`ccdeck-helper`** — privileged root LaunchDaemon (registered via
  `SMAppService`). Runs `pmset -a disablesleep 0|1` so the Mac stays awake with
  the lid closed on battery (clamshell sleep is enforced below the assertion
  layer; only `disablesleep` overrides it, which needs root). The app talks to it
  over XPC (`HelperManager` → `NSXPCConnection(.privileged)`).

The helper validates callers by code signature at runtime: bundle id must equal
the app's, and — when the helper carries a team id — the caller must share that
same team. The team is read from the helper's own signature (`SecCodeCopySelf`),
not hardcoded, so the check follows whatever identity built the app.

## Lid-close display-off (`ClamshellMonitor.swift`)

With keep-awake on and the lid shut, the machine keeps running (`disablesleep`)
but the internal panel would otherwise stay powered. The `PreventSystemSleep`
assertion in `StayAwake` deliberately *allows the display to sleep* — it only
blocks system sleep — so the display can be powered off independently while the
system runs.

`ClamshellMonitor` registers an IOKit general-interest notification on
`IOPMrootDomain` and reads the `AppleClamshellState` property. On each open→closed
transition it runs `pmset displaysleepnow`, which sleeps the display only (no
system sleep) and needs **no privileges** — it runs as the regular user, not via
the helper. The monitor listens only while keep-awake is active (started in
`toggleStayAwake`, stopped on toggle-off and on "Remove keep-awake helper…").

Notes / limits:

- It fires on the *transition* to closed. Normal order is: enable keep-awake,
  then close the lid. Enabling while already closed (e.g. on an external display)
  won't fire — by design, to avoid blanking an external-display setup.
- The display wakes again from any input or when the lid opens; that's the OS,
  nothing to undo on our side.

## Troubleshooting: "Couldn't communicate with a helper application."

Full message in the UI:

> Lid-close keep-awake unavailable (Couldn't communicate with a helper
> application.). Idle sleep still blocked; keep the lid open.

### Cause: stale daemon

The most common cause is a **stale daemon**. After a rebuild, launchd keeps
running the *old* helper binary until the daemon is reloaded — it does not pick
up the new binary on disk automatically. If the old binary predates a change to
the validator (e.g. an older hardcoded signing team), it rejects the freshly
built app and XPC fails with this error.

Diagnose by comparing the on-disk helper's build time to the running root
helper's start time:

```sh
# binary mtime
ls -la /Applications/ccdeck.app/Contents/MacOS/ccdeck-helper
# running root helper start time (find its pid first: ps aux | grep ccdeck-helper)
ps -o lstart= -p <pid>
```

If the running helper started *before* the binary's mtime, the daemon is stale.

### Fix

**Option A — in-app (no sudo):**

1. Right-click the "Stay awake" button → **Remove keep-awake helper…**
   (unregisters the daemon).
2. Click **Stay awake** again → re-registers and loads the new binary.

**Option B — terminal (force restart now):**

```sh
sudo launchctl kickstart -k system/com.wzulfikar.ccdeck.helper
```

### Avoiding it on every rebuild

The build/install script should kick the daemon (unregister or
`launchctl kickstart -k`) after copying the new helper, otherwise launchd keeps
the old one until reboot.

## Other requirements

- App must run from **`/Applications`** (translocated / `dist/` copies won't
  register the daemon).
- App and helper must be signed by the **same team**, signed inside-out (helper
  first, then app, **no** `--deep`).
- First toggle-on prompts a one-time approval in **System Settings ▸ Login
  Items**; silent thereafter.

## Dev vs prod variants (avoiding daemon collisions)

Never run two builds that share the bundle id `com.wzulfikar.ccdeck` (hence the
daemon label `…ccdeck.helper`) but are signed by **different teams** on one
machine — only one such daemon registers system-wide, and the helper rejects
XPC clients whose team doesn't match the registrant's, so the "other" build's
lid-close silently fails. This bit us with a personal-team `dist/` build vs the
Klu-team brew build (see `.work/lessons/stay-awake-dev-prod-variant.md`).

Fix: `create_app_bundle.sh` builds two **variants** via `VARIANT=dev|prod`
(default `prod`). `dev` uses `com.wzulfikar.ccdeck-dev` → its own daemon label →
coexists with the prod build. Ids are derived at runtime from
`Bundle.main.bundleIdentifier` (see `HelperShared/HelperProtocol.swift`), so one
source tree builds either. `release.sh` pins `VARIANT=prod`.
