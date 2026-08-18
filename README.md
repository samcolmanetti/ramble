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
swift run ramble-check       # test suite — 111 checks, no hardware needed
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
      "onStart": { "key": "space", "mods": ["shift"] },
      "onStop":  { "key": "space", "mods": ["shift"] }
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

Find a bundle ID with:

```sh
osascript -e 'id of app "Wispr Flow"'
```

---

## Distributing to another Mac

There's no signed, notarized release — that needs a paid Apple Developer
account, and this is a personal tool. Pick whichever of these fits.

### 1. Build from source (recommended)

The other machine needs Command Line Tools and nothing else:

```sh
xcode-select --install
git clone <this repo> && cd ramble
Scripts/make-signing-cert.sh    # optional but worth it
Scripts/bundle.sh --release
cp -R build/Ramble.app /Applications/
```

No Gatekeeper friction at all, because the app is built locally rather than
downloaded. This is the least annoying path by a wide margin.

### 2. Copy the built `.app`

You can copy `build/Ramble.app` directly — over AirDrop, a shared folder, a zip.
Anything that arrives via download or AirDrop gets a **quarantine attribute**,
and an ad-hoc-signed app then refuses to launch:

```sh
xattr -dr com.apple.quarantine /Applications/Ramble.app
```

Or right-click → Open once, and confirm.

Note that an ad-hoc signature is **machine-specific in practice**: the receiving
Mac sees a different signing identity than a locally built copy would, so
permissions must be granted fresh there regardless.

### 3. Signed and notarized

If you want this to install cleanly on machines you don't control, you need an
Apple Developer Program membership ($99/yr), then:

```sh
Scripts/bundle.sh --release --identity "Developer ID Application: Your Name (TEAMID)"
ditto -c -k --keepParent build/Ramble.app Ramble.zip
xcrun notarytool submit Ramble.zip --apple-id … --team-id … --wait
xcrun stapler staple build/Ramble.app
```

Only worth it if you're handing this to people who won't run a build script.

### On every machine, regardless

Permissions are per-machine and can't be copied:

1. **Bluetooth** — prompted on first launch
2. **Accessibility** — System Settings → Privacy & Security → Accessibility.
   Without it, everything connects and nothing types. The menu bar shows a
   warning when it's missing.

And per-machine setup:

- Pair the Instamic and put it in **Bluetooth Microphone Mode**
- **Quit the Instamic Remote app** — the device allows exactly one BLE central
- Set your transcription app's hotkey, and match it in `config.json`

### Start at login

Drop `Ramble.app` in System Settings → General → Login Items.
