# Phase 1 — Protocol Verification

Before any hotkey code gets written, confirm that opcode `0x03` payload
`0x35`/`0x36` really is the record button. The existing capture (handoff §4) is
three presses of near-identical duration, which is consistent with the
hypothesis but doesn't discriminate against several alternatives.

`ramble-sniff` is the instrument. It uses the exact parser the app will ship, so
a parser bug surfaces here rather than looking like a protocol mystery later.

---

## 0. Put the Instamic in Bluetooth Microphone Mode

> This step used to say **Remote Control Mode**, on the handoff's §2 claim that
> BLE and Classic audio are mutually exclusive. That claim is false — see the
> headline finding in [FINDINGS.md](FINDINGS.md), measured in
> `captures/mode-bluetooth-mic.log`. Following the old instruction gives you a
> working button and **no audio**, which is exactly half a dictation trigger.

Set the mode in the Instamic Remote app, then **quit that app** — the device
accepts exactly one BLE central, and while the official app holds it, neither
Ramble nor `ramble-sniff` can ever connect.

Switching modes may need a power cycle of the unit, not just a toggle in the app.

You want *both* links up at once. Check Classic:

```sh
system_profiler SPBluetoothDataType | grep -A6 'Instamic'
```

- `Services: 0x1800001 < HFP ACL SCO >` → **right.** `SCO` is the channel
  actually carrying voice, not just a control link.
- Absent from the connected list → the audio half is down; the button may still
  work, but nothing will be transcribed.

And confirm the Mac is really listening to it:

```sh
ramble-level --list        # the Instamic should appear, at 16000 Hz
```

16 kHz mono is the HFP rate, and also Whisper's native input rate, so it costs
nothing in transcription quality.

> **Set Sound *output* back to your speakers.** macOS routes both directions to
> a Bluetooth headset by default, which drops all system audio to 16 kHz.

---

## 1. Run the checks

```sh
swift run ramble-check
```

Should print `PASS` with every check passing. This is pure parser logic — no
hardware involved. Note that the handoff records opcodes and payloads but not checksum
bytes, so these cases are reconstructed from the documented rule. They prove the
parser is self-consistent; step 3 is what proves the rule itself is right.

## 2. Confirm the device is advertising

```sh
swift build
./.build/debug/ramble-sniff --scan-only
```

**Run this from Terminal, Ghostty, or iTerm directly** — not from an editor,
script runner, or agent. macOS attributes the Bluetooth permission prompt to the
launching app, and a bare CLI with no bundle identity gets no dialog at all;
CoreBluetooth then silently never starts. The tool detects this and says so
after 3 seconds, but the fix is always "run it from a real terminal and approve
the prompt."

You should see a stream of advertisements from every BLE device nearby. Look for:

```
advert  Instamic BLE   rssi -52   FF10
```

- **Nothing at all, for any device** → permission problem, see above.
- **Other devices but no Instamic** → still in the wrong mode, or asleep. Press
  the button once to wake it.
- **`Instamic BLE` with no `FF10` in the UUID column** → it advertises without
  the service in the packet. Not a problem: the default wide scan matches on
  name too. It does mean `--narrow` will never find it.

Ctrl-C when you've seen it.

## 3. Connect and watch the frames

```sh
./.build/debug/ramble-sniff | tee capture-$(date +%Y%m%d-%H%M).log
```

Expect:

```
scanning…
found Instamic BLE (…) rssi -52
✓ connected to Instamic BLE
subscribed to FF11 — press the record button
```

Two frames arrive immediately on subscribe (opcodes `0x07` and `0x09`). Those
are expected — session/device info, not button events.

### The test that actually matters

Press the record button four times with **deliberately different durations**:

| Press | Hold for |
|---|---|
| 1 | ~2 seconds |
| 2 | ~10 seconds |
| 3 | ~2 seconds |
| 4 | **~45 seconds** |

The long one is not optional. The device emits a `02 [44 02]` frame on a
15-second timer, and an early version of this project mistook that frame for
the button press because every verification take was shorter than 15 s. Any
take that clears the timer by a wide margin exposes internal periodic traffic
that short takes cannot. **Always include one take several times longer than
the others.**

The tool measures and prints each gap:

```
op 03  [35]   ▶︎ RECORD START  (take 1)
op 03  [36]   ■ RECORD STOP   held 2.05s
op 03  [35]   ▶︎ RECORD START  (take 2)
op 03  [36]   ■ RECORD STOP   held 10.13s
```

**Pass:** the `held` values track what you actually did — roughly 2, 10, 2, 10.
**Fail:** the durations are all similar regardless of how long you held, or
`0x35`/`0x36` arrive in the wrong order, or a stop arrives with no start.

A failure here means `0x03` is something else — a periodic status ping, say —
and the trigger has to be re-identified from `0x02` or `0x04`. Do not start
Phase 2 on a failed step 3; none of that work would survive.

### Then leave it running

- **10-minute idle soak**, no button contact. `0x35`/`0x36` must never appear
  spontaneously. If they do — from a sleep timeout, low battery, or standby —
  the app would fire random hotkeys at you, and the trigger needs a guard
  condition beyond the opcode.
- **Sleep and wake the Mac.** Confirm it reconnects. The device uses a rotating
  resolvable private address, so reconnection is discovery, not a cached handle.
- **Walk out of range and back.** Same expectation, plus backoff in the log.

## 4. What else to record while you're there

Worth noting in the capture log, since a second session costs another setup:

- What `0x02` and `0x04` payloads look like on a 2s take versus a 10s take. If
  `0x02` carries battery or remaining storage, that's free menu bar telemetry.
- Whether any `⚠️ MALFORMED` lines appear. None expected — but if the checksum
  rule is subtly wrong, this is where it shows, and the error message says
  exactly which byte disagreed.
- Whether `0x03` ever carries a payload other than `0x35`/`0x36`. The tool flags
  this specifically rather than lumping it in with other traffic.

---

## 5. Config safety, by hand

`ramble-check` covers `Config` load/save directly, but the reload *policy* lives
in `AppDelegate`, which the suite cannot instantiate — AppKit needs a running
app. These four steps take a minute and cover the one failure that destroys a
user's work.

With Ramble running and a config you have edited by hand:

1. **Break the file.** Add a stray comma to `~/.config/ramble/config.json` and
   save. The menu should show a config error naming the bad key — not a generic
   Foundation sentence — and the mic button should keep firing the rules from
   before the edit. Nothing should silently revert to the starter config.
2. **Try to save while it is broken.** Pick a different app from the *Dictation
   app* submenu. The menu should say it is not saving until the error is fixed,
   and `config.json` on disk must still contain **your** broken text — not a
   starter config written over it. This is the regression that matters.
3. **Fix the file.** Remove the comma and save. The error should clear on its
   own (the file is watched), and switching dictation app should persist again.
4. **Add an unknown key.** Put `"futureSetting": 1` at the top level, save, then
   switch dictation app from the menu. Re-open the file: `futureSetting` must
   still be there.

---

## Result

Paste the capture log back. If steps 3 and 4 are clean, Phase 2 (keystroke
emission and the per-app rule engine) starts against a verified protocol.
