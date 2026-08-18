# Ramble — Implementation Plan

A macOS menu bar app that turns the Instamic's physical record button into a
per-application dictation trigger.

Companion to [`instamic-ble-trigger-handoff.md`](instamic-ble-trigger-handoff.md),
which holds the reverse-engineered BLE protocol and the list of dead ends. This
document covers *what we build and in what order*.

---

## 1. What this is

```
Instamic button press
      ↓  BLE notify on FF11 (opcode 0x03 / 0x35 to start, 0x02 / [44 02] to stop)
Ramble (menu bar, always running)
      ↓  look up rule for the frontmost app
      ↓  synthesize keystroke via CGEvent
Wispr Flow / MacWhisper / Claude Code voice / Codex voice
      ↓
transcribed text at the cursor
```

The Instamic is **only a trigger**. In Remote Control Mode (BLE active) it records
to internal storage and streams nothing to the Mac; the Mac's own input device is
what actually gets transcribed. This is settled — see handoff §2.

### The per-app requirement

Different transcription services want different keystrokes, and which one you want
depends on where you're typing:

| Frontmost app | Service | Trigger |
|---|---|---|
| Ghostty / iTerm running Claude Code | Claude Code voice mode | tap `space` (empty input) |
| Codex.app | Codex voice mode | its voice key |
| Anything else | Wispr Flow | its global hotkey |
| Zed / VS Code | MacWhisper or Wispr Flow | user's choice |

So the keystroke is not a single global setting — it's a lookup on the frontmost
app's bundle identifier, with a default fallback. That's the core of the config model.

---

## 2. Toolchain constraint

This machine has **Command Line Tools only, no Xcode** (`xcodebuild` unavailable,
Swift 6.3.2, macOS 26.5). That rules out an `.xcodeproj`.

The build is therefore **Swift Package Manager + a hand-rolled `.app` bundle**:
SPM produces the executable, a script assembles `Ramble.app` (binary + `Info.plist`
+ icon) and codesigns it. AppKit, CoreBluetooth, and Carbon are all in the CLT SDK,
so nothing is lost except the Xcode GUI. If full Xcode gets installed later,
the package opens directly in it with no migration.

One thing *is* lost: **`swift test` does not work.** Both XCTest and
swift-testing ship inside Xcode, not the CLT, so a `testTarget` fails to compile
with `no such module 'XCTest'`. Rather than make a multi-gigabyte Xcode install a
prerequisite for running tests, the suite is a plain executable — `swift run
ramble-check` — with a ~20-line assertion harness. It exits non-zero on failure,
so CI treats it like any other test command, and porting to XCTest later is
mechanical.

### Codesigning and TCC — plan for this early

Ramble needs two TCC permissions: **Bluetooth** (CoreBluetooth) and
**Accessibility** (posting `CGEvent` keystrokes). macOS keys those grants to the
binary's code signature. Ad-hoc signing (`codesign -s -`) keys them to the *cdhash*,
which changes on every rebuild — meaning a re-prompt, and often a stale entry that
has to be manually removed from System Settings, after every single build. That is
a miserable dev loop.

Mitigation: create one **self-signed code signing certificate** in the login
keychain ("Ramble Dev") and sign every build with it. TCC then keys to a stable
designated requirement and the grants survive rebuilds. This is a five-minute
one-time setup and should happen in Phase 0, not be discovered in Phase 3.

During Phase 1–2 the CLI runs from a terminal, so TCC attributes the prompts to the
*terminal app* (Ghostty/iTerm), not to our binary. Grants made during CLI
development do not carry over to the bundled app — expect to grant twice.

---

## 3. Repository layout

```
ramble/
├── Package.swift
├── Sources/
│   ├── RambleCore/              # no UI, fully testable
│   │   ├── Frame.swift          # 00 02 <len> <op> <payload> <chk> parse + validate
│   │   ├── RecordEvent.swift    # frame → .recordStarted / .recordStopped / .other
│   │   ├── BLEClient.swift      # CBCentralManager, wide scan, reconnect/backoff
│   │   ├── Keystroke.swift      # CGEvent emission, key name → keycode table
│   │   ├── RuleEngine.swift     # frontmost bundle ID → action, with start/stop latch
│   │   └── Config.swift         # ~/.config/ramble/config.json, load + watch
│   ├── ramble-sniff/            # Phase 1 CLI: connect, decode, log
│   ├── Ramble/                  # Phase 3 menu bar app (AppKit, NSStatusItem)
│   └── ramble-check/            # test suite (see §2 — `swift test` is unavailable)
├── Scripts/
│   ├── bundle.sh                # SPM binary → Ramble.app, Info.plist, codesign
│   └── make-signing-cert.sh     # one-time self-signed cert setup
└── Resources/Info.plist
```

`RambleCore` holds everything; both the CLI and the app are thin shells over it.
The frame parser and rule engine are pure functions over bytes and strings, so they
get real unit tests without the device present.

---

## 4. Config model

`~/.config/ramble/config.json`, hot-reloaded on change (also editable from the menu
bar UI in Phase 3):

```json
{
  "mode": "toggle",
  "autoReconnect": true,
  "defaultAction": {
    "onStart": { "key": "d", "mods": ["ctrl", "opt", "cmd"] },
    "onStop":  { "key": "d", "mods": ["ctrl", "opt", "cmd"] }
  },
  "rules": [
    {
      "name": "Claude Code voice (terminal)",
      "bundleIDs": ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
      "onStart": { "key": "space" },
      "onStop":  { "key": "space" }
    },
    {
      "name": "Codex voice",
      "bundleIDs": ["com.openai.codex"],
      "onStart": { "key": "TBD" },
      "onStop":  { "key": "TBD" }
    },
    {
      "name": "MacWhisper",
      "bundleIDs": ["dev.zed.Zed", "com.microsoft.VSCode"],
      "onStart": { "key": "TBD" },
      "onStop":  { "key": "TBD" }
    }
  ]
}
```

Bundle IDs above are read off this machine and are correct as of today; Wispr Flow
is `com.electron.wispr-flow` and is the intended `defaultAction` target once its
hotkey is confirmed.

### Semantics that need to be right

- **Rule latching.** The rule is resolved from the frontmost app at `0x35` (start)
  and *cached for that session*. The `0x36` (stop) event replays the same rule even
  if focus moved in between. Otherwise you start dictation in the terminal and stop
  it in Chrome, leaving the terminal recording forever.
- **Toggle vs push-to-talk.** `toggle` fires a full key-down/key-up on both start
  and stop (the Instamic button is itself a toggle, so this is the natural fit).
  `hold` sends key-down at `0x35` and key-up at `0x36`, keeping the key
  physically down for the duration — supported, but flagged as risky: some apps
  ignore multi-second synthetic holds, and a crash mid-hold leaves a stuck key.
  Default is `toggle`.
- **Escape hatch.** An action may alternatively be `{"shell": "..."}` for services
  driven by URL schemes or CLI rather than a hotkey. Cheap to add, avoids being
  boxed in by services that have no global hotkey.
- **No matching rule** → `defaultAction`. An explicit `"onStart": null` means "do
  nothing in this app", which is how you blacklist e.g. a password manager.

---

## 5. Build order

Each phase ends at something that works and is committed.

### Phase 0 — Scaffold *(small)*

SPM package, `.gitignore`, signing cert script, empty `RambleCore` with the frame
parser ported from the handoff plus unit tests over the seven captured frames.
Tests pass before any hardware is involved.

### Phase 1 — `ramble-sniff`, and protocol verification ✅ *done*

**Verified against hardware — see [`FINDINGS.md`](FINDINGS.md).** The `0x03`
hypothesis holds. Two things changed as a result: the advertisement carries
`FF11` rather than `FF10`, so scanning by the handoff's service UUID finds
nothing; and `03 [36]` trails the actual button press by a consistent 1.65 s, so
the stop trigger must fire on `02 [44 02]` instead or every dictation gains 1.65 s
of dead air.

<details><summary>Original Phase 1 plan</summary>


A CLI that scans for service `FF10`, connects, subscribes to `FF11`, and prints
every decoded frame with a millisecond timestamp, opcode, payload hex, and
validity. Invalid frames print too, marked — during verification we want to *see*
malformed traffic, not silently drop it.

The handoff's §7 lists "re-capture with nRF Connect" and "write a CLI PoC" as two
separate steps. They collapse: **`ramble-sniff` is the verification instrument.**
Building it first means the verification is done with the exact parser the product
will ship, so a parser bug shows up now rather than masquerading as a protocol
mystery later.

Verification protocol, run against the device before writing a single line of
Phase 2:

1. Four presses with deliberately different durations — 2s, 10s, 2s, 10s — and
   confirm the `0x35`→`0x36` gaps track the durations. This is the test the
   existing capture cannot pass, since all three of its presses were ~4s.
2. A 10-minute idle soak with no button contact, confirming `0x35`/`0x36` never
   appear spontaneously (sleep timeout, low battery, standby).
3. One sleep/wake cycle of the Mac, confirming reconnect works and the rotated
   private address doesn't break re-discovery.
4. One deliberate disconnect (walk the mic out of range) and reconnect.

**If step 1 or 2 fails, stop.** The `0x03` hypothesis is wrong and the trigger has
to be re-identified from `0x02`/`0x04` — that is a different project shape, and no
Phase 2 work would survive it.

Also worth logging in this phase: what the `0x02` and `0x04` payloads do across
long vs short takes. If `0x02` carries battery or remaining-storage, that is free
menu bar telemetry in Phase 3.

</details>

### Phase 2 — Actions and the rule engine

`Keystroke.swift` (CGEvent emission to `.cghidEventTap`, with an explicit
`AXIsProcessTrustedWithOptions` check at startup) and `RuleEngine.swift`
(`NSWorkspace.shared.frontmostApplication` → rule, with latching). Wired into
`ramble-sniff` behind a `--fire` flag so the whole trigger path is exercisable
from the terminal.

Testing here is empirical and per-service: confirm against Wispr Flow first (it's
already installed), then Claude Code voice in Ghostty, then the rest. Expect to
discover that at least one service needs a different key-event flavor than the
others — hence the escape hatch in §4.

### Phase 3 — Menu bar app

`NSStatusItem` with connection state (disconnected / scanning / connected), last
event + timestamp, per-app rule editor, and mode toggle. `Scripts/bundle.sh`
assembles and signs the `.app`. Login-item registration via `SMAppService`.

The last-event display is not a nicety — when the trigger silently stops working,
"did the packet arrive?" vs "did the keystroke fire?" is the only question worth
answering, and the menu bar is where you answer it in one glance.

Reconnect with backoff, plus the "another app may be connected" hint after
repeated connection failures — the Instamic accepts exactly one BLE central, so
Instamic Remote being open is the single most likely cause of a stuck
"scanning..." state.

### Phase 4 — Deliberately out of scope for now

Auto-switching the Mac's input device on trigger; ingesting the Instamic's 32-bit
float internal recordings for a higher-quality re-transcribe; the `fcc1` command
service (gain, timecode, settings). All plausible, none needed for the core loop.

---

## 6. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| `0x03` isn't record state | Project restarts | Phase 1 gates everything; verification protocol above |
| TCC re-prompts on every build | Dev loop misery | Stable self-signed cert in Phase 0 |
| Instamic Remote holds the BLE connection | Ramble can't connect | Detect repeated failures, surface the cause in the menu |
| Device sleeps / address rotates | Trigger silently dies | Scan by service UUID only; reconnect with backoff; Sleep Mode → Off in Instamic Remote |
| Accessibility denied | Packets arrive, nothing types | Check at launch and before each fire; menu bar shows it |
| A service ignores synthetic keys | That target unusable | Shell-command escape hatch per rule |
| Battery: 3.5h continuous | Mid-session death | Keep on USB-C at the desk; surface battery if `0x02` carries it |

---

## 7. Open questions for the user

1. **Wispr Flow's actual hotkey** — its config isn't in the plist we can read, so
   the default action's keystroke needs confirming from its settings UI.
2. **Codex voice mode / MacWhisper triggers** — MacWhisper isn't installed on this
   machine. Which services do you actually want wired up in Phase 2?
3. **Toggle vs push-to-talk** as the shipped default — plan assumes `toggle`,
   since the Instamic button is already a toggle.
