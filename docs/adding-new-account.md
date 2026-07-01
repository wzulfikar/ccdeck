# Adding a new account

The "Add account…" button signs into a Claude account and captures its
credentials into CC Deck, without ever reconstructing the credential blob — we
let `claude` write it so the format is exactly what Claude Code expects.

## Flow

1. **Resolve a working binary** (`ClaudeBinary.resolve()`). The menu-bar app can't
   trust the shell's `PATH`, and a naive lookup can land on a broken install (a
   pnpm/bun/asdf shim that prints `claude native binary not installed` the moment
   it does real work like `auth login`). Preference order: Homebrew cask
   (`/opt/homebrew/bin/claude`, native binary, most reliable) → `/usr/local/bin`
   → the user's login-shell `command -v claude` → `.bun`/`.asdf` shims last.

2. **Run `claude auth login` as a subprocess** (`AppModel.startAddAccount`). No
   Terminal window is spawned — running it ourselves against a known-good binary
   avoids the spawned-Terminal shell resolving `claude` to a broken install. The
   process's stdout+stderr are piped and merged; stdin is kept open.

3. **Open the sign-in URL** (`presentLoginURL`). A `readabilityHandler` scans the
   merged output for the `https://…` line ("If the browser didn't open, visit: …",
   parsed by `extractLoginURL`) and opens it once in the default browser via
   `NSWorkspace.shared.open`.

4. **Finish the login — two ways, both handled:**
   - **Automatic:** pressing *Authorize* in the browser can complete the flow on
     its own; `claude` writes the credential to the Keychain directly.
   - **Pasted code:** if the browser shows a code to copy back, paste it into the
     "Code (only if shown)" field in the menu. `submitLoginCode` writes it (plus a
     newline) to the subprocess's stdin, and `claude` finishes and writes the
     Keychain.

   The pasted code is **optional** — the UI is worded that way ("Authorize in your
   browser — I'll capture it automatically").

5. **Auto-capture** (`watchForNewLogin` → `captureCurrentLogin`). A background task
   polls the live official Keychain entry every 2s (up to 5 min). When it sees a
   token that isn't the pre-login token and isn't one of the already-known
   accounts, it captures it: fetches the profile, stores the blob keyed by email,
   snapshots the identity `claude` wrote to `~/.claude.json` (so switching can
   restore it), upserts the account, and makes it active. Because it watches the
   Keychain, it works regardless of which of the two finish paths above happened.

6. **Teardown** (`endLoginSession`). On success or the 5-minute timeout, the
   readability handler is cleared, stdin is closed, and the subprocess is
   terminated.

## Alternative: "Get current login"

`captureCurrentLogin` can also be triggered directly — it captures whatever
Claude Code is currently logged into, no `auth login` run. Useful if you signed
in outside CC Deck, or if the auto-capture timed out but you did finish signing
in.

## Why not just spawn a Terminal?

The previous flow used `osascript` to open Terminal running `claude auth login`.
That failed when the spawned shell's `PATH` resolved `claude` to a broken shim
(`claude native binary not installed`), even though signing in manually worked.
Running the subprocess ourselves against a resolved, known-good binary removes
that dependency on the shell environment.
