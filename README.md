# Ramble

Turns the physical record button on a Zoom Instamic into a per-application
dictation trigger for macOS. Press the button on the mic clipped to your collar;
Wispr Flow, MacWhisper, or Claude Code voice mode starts recording. Press again;
it stops.

The Instamic is both the **microphone** and the **trigger**, over Bluetooth,
simultaneously — see [PROTOCOL.md](PROTOCOL.md) for how, and why the vendor
documentation says that's impossible.

- [PROTOCOL.md](PROTOCOL.md) — the wire protocol, shareable
- [FINDINGS.md](FINDINGS.md) — everything measured, including corrections
- [PLAN.md](PLAN.md) — architecture and build order
- [VERIFY.md](VERIFY.md) — hardware verification procedure

---

## Build

Requires the Swift toolchain. **Xcode is not needed** — Command Line Tools are
enough (`xcode-select --install`).

```sh
swift run ramble-check       # test suite — 120 checks, no hardware needed
Scripts/bundle.sh            # assemble build/Ramble.app
open build/Ramble.app
```

`swift test` does not work here: XCTest and swift-testing both ship inside
Xcode, so the suite is a plain executable instead. It exits non-zero on failure,
so CI treats it like any other test command.

### Sign once, or re-grant permissions forever

macOS ties Accessibility and Bluetooth grants to a binary's **code signature**.
Ad-hoc signing keys them to a hash that changes on every build, so each rebuild
re-prompts and leaves a stale entry in System Settings.

```sh
Scripts/make-signing-cert.sh   # prints the one-time Keychain Access steps
```

Five minutes, then grants survive rebuilds. `bundle.sh` picks the identity up
automatically and falls back to ad-hoc with a warning.

## Tools

| | |
|---|---|
| `Ramble` | the menu bar app |
| `ramble-sniff` | connect and print decoded frames; `--fire` to send hotkeys |
| `ramble-tap` | watch what the OS actually receives from a synthesized keystroke |
| `ramble-level` | measure whisper level and SNR through the mic |
| `ramble-check` | the test suite |

## Configuration

`~/.config/ramble/config.json`, written on first run and **hot-reloaded** when
it changes.

```json
{
  "mode": "toggle",
  "defaultRule": {
    "name": "Wispr Flow (push-to-talk)",
    "bundleIDs": [],
    "mode": "hold",
    "onStart": { "key": "fn" },
    "onStop":  { "key": "fn" }
  },
  "rules": [
    {
      "name": "Claude Code voice",
      "bundleIDs": ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
      "mode": "toggle",
      "onStart": { "key": "space" },
      "onStop":  { "key": "space" }
    }
  ]
}
```

- **Rules match the frontmost app's bundle ID**; first match wins, otherwise
  `defaultRule`.
- **`mode` is per-rule.** `hold` presses the key at start and releases it at
  stop — required for push-to-talk like Wispr Flow's Fn. `toggle` taps it both
  times. One global mode can't serve both, which is why rules override it.
- **The rule is latched when the take starts.** Begin dictating in the terminal,
  switch to a browser, press stop — the stop keystroke still goes to the
  terminal's rule. Otherwise you'd leave the first app recording forever.
- **`"onStart": null` mutes an app** entirely — useful for a password manager.
- **`{"shell": "..."}`** works instead of a key, for anything driven by a URL
  scheme or CLI.
- **Avoid modifiers on terminal targets.** Terminals send the same byte for
  Space and Shift+Space unless the Kitty keyboard protocol's disambiguation
  mode happens to be active, and Ghostty was observed dropping Cmd entirely on
  the way to the TUI. Global hotkeys like Wispr Flow's Fn are intercepted
  before the terminal, so they're unaffected.

Find a bundle ID with:

```sh
osascript -e 'id of app "Wispr Flow"'
```

---

## Distributing to another Mac

Via Homebrew, from [samcolmanetti/homebrew-tap](https://github.com/samcolmanetti/homebrew-tap):

```sh
brew install --cask samcolmanetti/tap/ramble
```

The cask installs `Ramble.app`, exposes `ramble-sniff`, `ramble-tap` and
`ramble-level` on `PATH`, and registers a LaunchAgent so it starts at login and
restarts if it dies.

### Cutting a release

```sh
Scripts/release.sh 0.1.0            # build, zip, checksum, update the cask
Scripts/release.sh 0.1.0 --publish  # ...and create the GitHub release
```

`release.sh` rewrites `version` and `sha256` in `Casks/ramble.rb`; copy that
file into the tap and push.

The zip is made with `ditto`, not `zip`, because `zip` can invalidate a bundle's
code signature.

### The signing problem, honestly

There's no Developer ID here, so builds are **ad-hoc signed**. That has one
consequence worth stating plainly rather than burying:

**Every upgrade breaks the permissions.** macOS ties Accessibility and Bluetooth
grants to a binary's code signature; an ad-hoc signature is a content hash, so a
new build is a different app as far as TCC is concerned. After
`brew upgrade --cask ramble` you must toggle Accessibility off and back on. The
cask's caveats say so, matching the same warning in
`aerospace-swipe-intercept`.

Fixing it properly means an Apple Developer Program membership ($99/yr):

```sh
Scripts/bundle.sh --release --identity "Developer ID Application: Name (TEAMID)"
ditto -c -k --keepParent build/Ramble.app Ramble.zip
xcrun notarytool submit Ramble.zip --apple-id … --team-id … --wait
xcrun stapler staple build/Ramble.app
```

With a stable Developer ID the signature is identical across builds, so grants
survive upgrades and Gatekeeper stops complaining. Worth it only if this goes to
people who won't tolerate re-granting.

### Building from source instead

Needs Command Line Tools and nothing else — no Xcode:

```sh
xcode-select --install
git clone https://github.com/samcolmanetti/ramble && cd ramble
Scripts/make-signing-cert.sh    # one-time; stable identity, grants survive rebuilds
Scripts/bundle.sh --release
cp -R build/Ramble.app /Applications/
```

A locally built app has no quarantine attribute, so there's no Gatekeeper
friction at all. For your own machines this is the least annoying path.

### Per-machine setup, regardless of install method

Permissions can't be copied between machines:

1. **Bluetooth** — prompted on first launch
2. **Accessibility** — without it, everything connects and nothing types. The
   menu bar shows a warning when it's missing.

Then:

- Pair the Instamic and put it in **Bluetooth Microphone Mode**
- **Quit the Instamic Remote app** — the device allows exactly one BLE central
- Set Sound output back to your speakers; macOS routes both directions to a
  Bluetooth headset by default and drops all system audio to 16 kHz
- Set your transcription app's hotkey and match it in `config.json`

### Start at login

The cask installs a LaunchAgent that handles this. For a source build, drop
`Ramble.app` into System Settings → General → Login Items.
