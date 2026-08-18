# Phase 1 — Protocol Verification

Before any hotkey code gets written, confirm that opcode `0x03` payload
`0x35`/`0x36` really is the record button. The existing capture (handoff §4) is
three presses of near-identical duration, which is consistent with the
hypothesis but doesn't discriminate against several alternatives.

`ramble-sniff` is the instrument. It uses the exact parser the app will ship, so
a parser bug surfaces here rather than looking like a protocol mystery later.

---

## 0. Put the Instamic in Remote Control Mode

BLE and Classic audio are mutually exclusive on this device (handoff §2). If the
Mac still shows the Instamic as an audio device, it's in Bluetooth Microphone
Mode and the button is invisible over BLE.

Check:

```sh
system_profiler SPBluetoothDataType | grep -A6 'Instamic'
```

- `Services: 0x800001 < HFP ACL >` → **wrong mode.** It's a microphone right now.
- Absent from the connected list entirely → good sign; Classic is down.

Also confirm it stopped hijacking audio:

```sh
system_profiler SPAudioDataType | grep -B4 'Default Input Device: Yes'
```

If the Instamic is still your default input, Classic is still up. Switching
modes may need a power cycle of the unit, not just a toggle in the app.

**Quit the Instamic Remote app before continuing.** The device accepts exactly
one BLE central; if the official app holds it, `ramble-sniff` will scan forever.

---

## 1. Run the checks

```sh
swift run ramble-check
```

Should print `PASS 42/42 checks`. This is pure parser logic — no hardware
involved. Note that the handoff records opcodes and payloads but not checksum
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
| 4 | ~10 seconds |

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

## Result

Paste the capture log back. If steps 3 and 4 are clean, Phase 2 (keystroke
emission and the per-app rule engine) starts against a verified protocol.
