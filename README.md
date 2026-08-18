<div align="center">

# 🎙️ Ramble

**Your mic's record button, wired to your dictation app.**

Press the button on the Instamic clipped to your collar — Wispr Flow starts listening.
Press it again — it stops. No keyboard, no menu, no reaching for the laptop.

[![CI](https://github.com/samcolmanetti/ramble/actions/workflows/ci.yml/badge.svg)](https://github.com/samcolmanetti/ramble/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-black.svg)](#-install)
[![Swift](https://img.shields.io/badge/Swift-6-black.svg)](Package.swift)

</div>

---

## ✨ The trick

The Instamic is your **microphone** *and* your **trigger** — at the same time, over
Bluetooth. The vendor documentation says that's impossible.

It isn't. [**PROTOCOL.md**](PROTOCOL.md) shows the wire protocol that proves it.

```
  🔘 button press          📡 BLE frame            ⌨️  synthesized key
   on the mic     ──────▶   03 [36]      ──────▶    into the frontmost app
                                                            │
                                                            ▼
                                                   🗣️ dictation starts
```

Whichever app is in front decides which key gets sent. Terminal gets Space for
Claude Code voice; everything else gets whatever your dictation app wants.

---

## 📦 Install

```sh
brew install --cask samcolmanetti/tap/ramble
```

Installs `Ramble.app`, puts the diagnostic tools on your `PATH`, and registers a
LaunchAgent so it starts at login and restarts if it dies.

> [!IMPORTANT]
> **First launch: macOS blocks it, silently.** Ramble is ad-hoc signed, not
> notarized, so Gatekeeper stops it before it runs and nothing appears to happen.
> Once per install:
>
> **System Settings → Privacy & Security → Security → "Open Anyway"**

> [!NOTE]
> **Then two permissions, both prompted.** Without Accessibility, everything
> connects and nothing types — the menu bar warns you when it's missing.
>
> 🔵 **Bluetooth** · read the button &nbsp;&nbsp;|&nbsp;&nbsp; ♿️ **Accessibility** · send the key
>
> Building [from source](#%EF%B8%8F-build-from-source) skips the Gatekeeper step
> entirely — a locally built app is never quarantined.

<details>
<summary><b>🔧 Then set up the mic — one minute, once per machine</b></summary>

<br>

| Step | Why |
|---|---|
| Pair the Instamic, set **Bluetooth Microphone Mode** | Both audio and BLE at once |
| **Quit the Instamic Remote app** | The device allows exactly one BLE central — while that app is open, Ramble can never connect |
| Set Sound **output** back to your speakers | macOS routes both directions to a Bluetooth headset by default and drops all system audio to 16 kHz |
| Match your dictation app's hotkey in `config.json` | So the right key gets sent |

Permissions are tied to the machine and can't be copied between them.

</details>

<details>
<summary><b>🩺 When it isn't working</b></summary>

<br>

Every layer reports itself. `~/Library/Logs/Ramble.log` says which one gave up.

| Symptom | Cause | Fix |
|---|---|---|
| Press the button, nothing happens | Accessibility — the log says `failed: Accessibility permission not granted` | Menu bar → **Already enabled? Repair it…** Toggling the switch is not enough after an upgrade |
| Dictation starts on its own | The audio link activating puts the mic in its recording state, and it reports that exactly like a press | Handled: a start within 400 ms of the device's `0x09` announcement is ignored. See [PROTOCOL.md](PROTOCOL.md) |
| Menu bar stuck on *Scanning* | The mic is off, asleep, or another BLE central holds it | Wake the mic; quit the Instamic Remote app — the device allows exactly one |
| It types, but nothing is transcribed | The mic is connected for BLE but not as an audio input | Set `"audio": {"autoConnect": true}`, or connect it in Bluetooth settings |
| Everything sounds like a phone call | The mic took over playback as well — HFP is a headset profile | `autoConnect` hands playback back automatically; otherwise set output in Sound settings |
| Nothing happens at all, right after install | Gatekeeper blocked first launch | System Settings → Privacy & Security → **Open Anyway** |

```sh
ramble-sniff --scan-only   # is the mic advertising at all?
ramble-tap                 # does the OS receive a synthesized keystroke?
ramble-level               # is it loud enough to transcribe?
```

</details>

---

## ⚙️ Configuration

`~/.config/ramble/config.json` — written on first run, **hot-reloaded** on save.

```jsonc
{
  "activeTarget": "Wispr Flow",
  "targets": [
    { "name": "Wispr Flow", "mode": "hold", "onStart": { "key": "fn" } },
    { "name": "MacWhisper" },
    { "name": "Off" }
  ],
  "rules": [
    { "name": "Claude Code voice",
      "bundleIDs": ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
      "onStart": { "key": "space" }, "onStop": { "key": "space" } }
  ]
}
```

Two layers, and the distinction is the useful part:

| | What it is |
|---|---|
| 🎯 **`targets`** | The dictation services you switch between, from the menu bar's **Dictation app** submenu. The active one handles any app without its own rule. |
| 📌 **`rules`** | Per-app overrides matched on bundle ID. **These beat the active target** — so "Claude Code voice in the terminal, whatever I picked everywhere else" needs no switching at all. |

### 🎛️ Modes

| Mode | Behavior | Use it for |
|---|---|---|
| **`toggle`** *(default)* | Taps the key at start, taps again at stop | Almost everything |
| **`hold`** | Presses at start, releases at stop | True push-to-talk, like Wispr Flow's Fn |

> [!TIP]
> Leave `mode` out and you get `toggle`. Ask for `hold` explicitly, per rule.
> In `hold` mode **`onStop` is ignored** — ending a hold means lifting whatever is
> physically down, so Ramble releases exactly the chord it pressed.

<details>
<summary><b>🛟 What happens when things go wrong mid-sentence</b></summary>

<br>

A held key always comes back up: on disconnect, on Bluetooth switching off, on
quit, on `SIGTERM` from a Homebrew upgrade, on a mid-take config reload, and after
a 300-second take with no stop.

If a release ever *fails* — you revoked Accessibility mid-take — the menu names the
key that's still down and Ramble retries every five seconds until it succeeds.

The rule **and** the mode are latched when the take starts. Begin dictating in the
terminal, switch to a browser, press stop: the stop key still goes to the terminal's
rule. Otherwise you'd leave the first app recording forever.

</details>

### 🔊 Letting Ramble manage the mic

macOS will not reconnect a Bluetooth mic on its own, and when it does connect
one it takes the speakers too — dropping all system audio to 16 kHz mono.

```json
"audio": { "autoConnect": true, "device": "Instamic" }
```

Ramble then brings the mic up, makes it the system **input**, and hands playback
straight back to wherever it already was. It re-checks every few seconds, because
macOS grabs the output again every time the headset link returns.

You don't name the output. Ramble watches where playback actually lives and
writes it to `lastOutput`, so moving to your monitor or plugging in headphones
just works, and the answer survives a restart. Set `"preferredOutput"` only if
you want to override that.

> [!NOTE]
> **There is no mic-only Bluetooth connection.** A wireless mic speaks HFP, which
> is a *headset* profile — connecting it for the microphone unavoidably offers
> macOS a speaker as well. Ramble can't prevent that; it just refuses to let the
> speaker stick. Off by default, since it changes system state.

<details>
<summary><b>📋 Every other option</b></summary>

<br>

| Option | Effect |
|---|---|
| No `onStart` | Does nothing — that's what `"Off"` is, and how you mute a password manager |
| `{"shell": "..."}` | Runs a command instead of a key, for URL schemes and CLIs |
| `"showMenuBarIcon": false` | Hides the icon; Ramble keeps running. Set it back to `true` and it reappears on save |

> [!WARNING]
> **Avoid modifiers on terminal targets.** Terminals send the same byte for Space
> and Shift+Space unless the Kitty keyboard protocol's disambiguation mode is
> active, and Ghostty was observed dropping Cmd entirely on the way to the TUI.
> Global hotkeys like Wispr Flow's Fn are intercepted before the terminal, so
> they're unaffected.

Find a bundle ID with:

```sh
osascript -e 'id of app "Wispr Flow"'
```

</details>

---

## 🧰 Tools

Shipped inside the app bundle — they're the difference between "it doesn't work"
and knowing *which* of the four layers failed.

| | |
|---|---|
| 🎙️ `Ramble` | The menu bar app |
| 📡 `ramble-sniff` | Connect and print decoded frames; `--fire` to send hotkeys |
| ⌨️ `ramble-tap` | Watch what the OS actually receives from a synthesized keystroke |
| 📊 `ramble-level` | Measure your whisper level and signal-to-noise ratio |
| ✅ `ramble-check` | The test suite |

---

## 🛠️ Build from source

**Xcode is not needed** — Command Line Tools are enough.

```sh
xcode-select --install
git clone https://github.com/samcolmanetti/ramble && cd ramble

Scripts/make-signing-cert.sh   # one-time: grants survive rebuilds
Scripts/bundle.sh --release
cp -R build/Ramble.app /Applications/
```

A locally built app has no quarantine attribute, so there's no Gatekeeper friction
at all. For your own machines, this is the least annoying path.

```sh
swift run ramble-check   # the test suite — no hardware needed
```

`swift test` doesn't work here: XCTest and swift-testing both ship inside Xcode, so
the suite is a plain executable. It exits non-zero on failure, so CI treats it like
any other test command.

<details>
<summary><b>🔏 The signing problem, honestly</b></summary>

<br>

There's no Developer ID here, so builds are **ad-hoc signed**. One consequence is
worth stating plainly rather than burying:

> [!CAUTION]
> **Every upgrade breaks Accessibility.** macOS ties the grant to the app's code
> signature. An ad-hoc signature is a content hash, so a new build is a different
> app as far as TCC is concerned, and the button silently stops typing.
>
> **Toggling the switch off and on does not fix it.** The entry stays bound to the
> old build — it reads as enabled and still does nothing. Clear the record instead:
>
> **Menu bar → `Already enabled? Repair it…`**
>
> or the same thing by hand:
>
> ```sh
> tccutil reset Accessibility io.ramble.Ramble
> ```
>
> Then allow Ramble when it asks.

Locally, `Scripts/make-signing-cert.sh` creates a stable self-signed identity in
five minutes, and grants survive every rebuild. `bundle.sh` picks it up
automatically and falls back to ad-hoc with a warning.

Fixing it *properly* means an Apple Developer Program membership ($99/yr):

```sh
Scripts/bundle.sh --release --identity "Developer ID Application: Name (TEAMID)"
ditto -c -k --keepParent build/Ramble.app Ramble.zip
xcrun notarytool submit Ramble.zip --apple-id … --team-id … --wait
xcrun stapler staple build/Ramble.app
```

With a stable Developer ID the signature is identical across builds, so grants
survive upgrades and Gatekeeper stops complaining. Worth it only if this goes to
people who won't tolerate re-granting.

</details>

<details>
<summary><b>🚀 Cutting a release</b></summary>

<br>

```sh
Scripts/release.sh 0.1.0            # build, zip, checksum, update the cask
Scripts/release.sh 0.1.0 --publish  # ...and create the GitHub release
```

It rewrites `version` and `sha256` in `Casks/ramble.rb`, then **verifies the
checksum actually landed** and refuses to continue if it didn't. Copy the cask into
your tap and push.

The zip is made with `ditto`, not `zip`, because `zip` can invalidate a bundle's
code signature.

</details>

---

## 📚 Docs

| | |
|---|---|
| 📡 [PROTOCOL.md](PROTOCOL.md) | The wire protocol — shareable, and the interesting one |
| 🔬 [FINDINGS.md](FINDINGS.md) | Everything measured, including the corrections |
| 🏗️ [PLAN.md](PLAN.md) | Architecture and build order |
| ✅ [VERIFY.md](VERIFY.md) | Hardware verification procedure |
| 📜 [handoff](instamic-ble-trigger-handoff.md) | The original reverse-engineering notes, superseded but still cited |

---

<div align="center">

MIT — see [LICENSE](LICENSE)

</div>
