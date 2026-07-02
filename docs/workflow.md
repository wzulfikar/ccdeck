# ccdeck build & release workflow

Three layered scripts. Each composes the one below, and each higher script has exactly one "skip the lower layer" escape hatch. Daily use is `build` (dev loop) and `release` (ship); `bundle` is the rare middle step for dmg testing.

```
build.sh ──▶ bundle.sh ──▶ release.sh        reset.sh
 (.app)      (.dmg)         (publish)      (clean slate)
```

## The scripts

### `./scripts/build.sh [--prod]`

| | dev (default) | `--prod` |
|---|---|---|
| Output | `dist/CC Deck (dev).app` | `dist/CC Deck.app` |
| Bundle ID | `com.wzulfikar.ccdeck.dev` | `com.wzulfikar.ccdeck` |
| Config | debug (fast) | release |
| Sparkle | **disabled** — a dev build must never auto-update itself into prod | enabled |
| Keychain service | `ccdeck-dev` | `ccdeck` |
| App Support dir | `ccdeck-dev/` | `ccdeck/` |
| Signing | `ccdeck-dev` self-signed cert if present, else ad-hoc | `CODESIGN_IDENTITY` env, else ad-hoc |

`--prod` also writes `dist/.prod-build.manifest` (version + git sha + dirty flag). This is the freshness handshake that `bundle.sh --no-build` and `release.sh --no-bundle` verify — it's what prevents "released the wrong bits" accidents.

Both variants coexist in `dist/` and on your machine: separate bundle ID, Keychain service, and database mean the dev app can run right next to the installed production app without touching its data.

### `./scripts/bundle.sh [--no-build] [--no-notarize]`

Prod build → notarize `.app` → staple → dmg → notarize dmg → staple → verify → `dist/ccdeck.dmg`.

- `--no-build` — dmg from the existing prod build. **Fails hard** if there is no prod build/manifest; **warns** if the build's git sha ≠ HEAD (explicit override, so a warning not a failure).
- `--no-notarize` — skip notarization for local dmg testing (your stated use case for this script — no Apple creds needed, no minutes waiting). The manifest records `notarized=0` and `release.sh` will **refuse** to publish it, so a test dmg can never ship by mistake.

Writes `dist/.bundle.manifest` (version, sha, notarized) on success.

### `./scripts/release.sh [vX.Y.Z] [--no-bundle] [--dry-run]`

Resolve version → bundle → commit `version.txt` + tag → `gh release create` → Sparkle appcast → Homebrew cask.

- `--no-bundle` — publish the existing `dist/ccdeck.dmg`. The version is **taken from the bundle manifest** (the dmg's embedded version is already baked in — releasing it under a different number would desync the app and the tag). Refuses un-notarized bundles.
- `--dry-run` — prints every publish step, executes none. Zero side effects: no build, no commit, no tag, no push.
- The old `--no-publish` is retired — that role is exactly what `bundle.sh` is now.

Two reliability changes vs. the old release.sh:

1. **Artifacts first, git second.** The commit/tag/push only happen after the notarized dmg exists. A failure mid-notarization leaves no tag behind — just rerun.
2. **Version bump is based on the latest git tag**, not `version.txt`, so a rerun after a failed release doesn't double-bump (v0.1.4 → v0.1.5 by accident). The `-rc` promote behavior from `version.txt` is preserved.

## Daily operation

```bash
./scripts/build.sh            # iterate: open "dist/CC Deck (dev).app"
./scripts/release.sh          # ship: patch bump, full pipeline
./scripts/release.sh v0.2.0   # ship a specific version
./scripts/release.sh --dry-run   # sanity-check what a release would do

./scripts/bundle.sh --no-notarize   # rare: poke at dmg packaging locally
```

### `./scripts/reset.sh [--dev|--prod] [--official-creds] [--dry-run] [--yes]`

Returns the machine to a pre-ccdeck state — "developing from day one." Resets both variants by default; `--dev` / `--prod` narrows it. Per variant it: quits the running app (graceful, then kill by bundle path so it never takes down the *other* variant), boots out the "Stay awake" helper daemon (sudo, prod only), resets **TCC privacy permissions** (`tccutil reset All <bundle-id>`), deletes the app from `/Applications`, purges the app's **Keychain service** items (`ccdeck` / `ccdeck-dev`, looped until empty), and removes Application Support data, `defaults` (incl. Sparkle's update-check state), caches, HTTPStorages, and saved application state. Then it clears `dist/`.

Safety rails:

- **Interactive confirmation** — you must type `yes` (skip with `--yes`; `--dry-run` implies it).
- `--dry-run` prints every action and touches nothing — run this first.
- The live `"Claude Code-credentials"` keychain item is **never** touched unless you pass `--official-creds`, because deleting it logs Claude Code itself out.
- Not removed: the `ccdeck-dev` signing cert (harmless, tedious to recreate), and the helper's Background Item row in System Settings — macOS drops it once the app is gone (`sfltool resetbtm` force-clears it, but that resets *every* app's background items, so it's left to you).

## Tests

```bash
./scripts/test.sh          # fast — unit tests (Tests/ccdeckTests), seconds
./scripts/test.sh --slow   # slow — script pipeline tests, minutes
./scripts/test.sh --all    # both
```

The slow suite is a new test target, `Tests/ccdeckScriptTests`, gated by `CCDECK_SLOW_TESTS=1` via Swift Testing's `.enabled(if:)` — so a bare `swift test` (CI, habit) stays fast and just reports the slow ones as skipped. The suite is `.serialized` because the tests share `dist/`.

What it verifies (never notarizes, never publishes):

- **build.sh** — dev bundle exists with the `.dev` bundle ID, correct display name, **no `SUFeedURL`**, valid code signature; `--prod` produces the prod bundle ID, coexists with the dev app, and writes a manifest whose sha matches HEAD; unknown flags are rejected.
- **bundle.sh** — `--no-build` fails without a prod build; a full `--no-notarize` run produces a dmg that passes `hdiutil verify`, mounts, and contains `CC Deck.app`; `--no-build` reuses the existing build without recompiling; manifest records `notarized=0`.
- **release.sh** — refuses a missing bundle and an un-notarized bundle; a full `--dry-run` plans every publish surface (bundle, tag, gh release, appcast, cask) while leaving git tags and HEAD untouched; refuses versions whose tag already exists.
- **reset.sh** — `--dry-run` plans both variants and every cleanup surface (TCC, keychain, defaults) while leaving earlier tests' artifacts intact; aborts without a typed confirmation; rejects unknown flags. (The destructive path is deliberately untested — it would wipe your real dev state.)

## Code changes that make the dev variant real

Separate bundle IDs alone wouldn't isolate anything — two values were hardcoded:

- `Keychain.appService` → now `ccdeck-dev` when the bundle ID ends in `.dev`. **Deliberate exception:** `officialService` ("Claude Code-credentials") stays shared, because there's only one live Claude Code credential and switching it is the app's whole purpose. Consequence: activating an account from the dev app changes the real active account. If you ever want a fully inert dev mode, that's the next thing to gate.
- `Store.dbURL` → dev builds get `Application Support/ccdeck-dev/`.

Also `create_app_bundle.sh` now takes `APP_BUNDLE` / `BUNDLE_ID` / `SPARKLE_ENABLED` from the environment (defaults unchanged = prod), which is how `build.sh` stays a thin wrapper.

## Known limitations / notes

- **"Stay awake" helper won't work in dev builds.** The LaunchDaemon label follows the bundle ID (`com.wzulfikar.ccdeck.dev.helper`, so no collision with prod), but `HelperShared` hardcodes the prod mach service name — and dev signing can't register SMAppService daemons anyway, which your bundle script already warns about. Prod is unaffected.
- **Dev signing:** create the self-signed `ccdeck-dev` cert once (Keychain Access ▸ Certificate Assistant, Code Signing) and `build.sh` picks it up automatically — that's what makes the Keychain "Always Allow" stick across rebuilds.
- Optional polish: make the dev menu bar icon visually distinct (e.g. in `MenuBarStyle`, check `Bundle.main.bundleIdentifier?.hasSuffix(".dev")` and tint or badge the icon) so you never confuse the two apps at a glance.

## Applying

`git apply ccdeck-workflow.patch` from the repo root (or review the individual scripts and drop them in). Then:

```bash
./scripts/test.sh          # should pass immediately
./scripts/build.sh         # smoke-test the dev app
./scripts/test.sh --slow   # full pipeline check
```
