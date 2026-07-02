# Auto-update (Sparkle)

CC Deck updates itself with [Sparkle](https://sparkle-project.org). Direct-DMG
installs check the feed and update in place; Homebrew-cask installs are left alone
and update with `brew upgrade` (Sparkle swapping the `.app` would desync `brew`).

## How it works

- The app embeds `Sparkle.framework` in `Contents/Frameworks` (copied + re-signed by
  `scripts/utils/create_app_bundle.sh`).
- `AppUpdater` (`Sources/ccdeck/Updater.swift`) starts Sparkle only when **both**:
  - the app is **not** a Homebrew cask install — detected via the Caskroom metadata
    dir (`/opt/homebrew/Caskroom/ccdeck` or `/usr/local/Caskroom/ccdeck`); and
  - a feed is configured — i.e. `SUFeedURL` is present in `Info.plist`.
- Feed URL: `https://github.com/wzulfikar/ccdeck/releases/latest/download/appcast.xml`.
  GitHub's `latest/download/<asset>` always resolves to the newest release, so the
  single-entry `appcast.xml` uploaded per release is all existing installs need.
- Update UI: a **Check for Updates…** button in the menu (and a daily background
  check). Cask installs instead see a "update with `brew upgrade`" hint.

## One-time setup (maintainer)

Auto-update stays **dormant** until you generate an EdDSA signing key and record its
public half. Do this once:

1. Find Sparkle's `generate_keys` (SPM drops the tools under `.build/artifacts`):

   ```sh
   swift build   # ensure Sparkle is fetched
   find .build/artifacts -name generate_keys
   ```

2. Generate the key pair. The **private** key is stored in your login Keychain
   (back it up — losing it means clients can't verify future updates); the command
   prints the **public** key:

   ```sh
   /path/to/generate_keys
   ```

3. Save the printed public key so the bundle picks it up:

   ```sh
   echo 'PASTE_PUBLIC_KEY_HERE' > Resources/sparkle_pubkey.txt
   ```

   (or export `SPARKLE_PUBLIC_KEY=…` before building). `scripts/utils/create_app_bundle.sh` writes
   it into `Info.plist` as `SUPublicEDKey`; without it the Sparkle keys are omitted
   and the updater stays dormant.

From then on, `scripts/release.sh` signs and attaches `appcast.xml` automatically
(`generate_appcast` reads the private key from the Keychain).

> Keep `Resources/sparkle_pubkey.txt` committed — it's public. Never commit the
> private key; it lives only in the Keychain.

## Version format note

Sparkle compares `CFBundleVersion` numerically, so the bundle uses the plain dotted
number (`0.1.2`) while the in-app label re-adds the `v`. `version.txt` keeps the
`v` prefix as before.
