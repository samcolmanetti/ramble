# Protocol Findings — verified against hardware

Capture: `captures/press-test.log`, 2026-08-17, four button presses of
deliberately uneven duration. Supersedes the hypotheses in
[`instamic-ble-trigger-handoff.md`](instamic-ble-trigger-handoff.md) §3–4 where
they disagree.

---

## The headline: BLE and HFP are **not** mutually exclusive

The handoff's §2 lists this under "what was ruled out — don't re-litigate":

> **BLE and HFP are mutually exclusive on this device.** In Bluetooth Microphone
> Mode (the only mode where the Mac hears audio), BLE and Classic Audio are
> disabled — so the Mac cannot see button events.

**This is wrong.** Measured directly (`captures/mode-bluetooth-mic.log`), with
the device in Bluetooth Microphone Mode, all of the following were true at once:

```
Classic:   Instamic  Services: 0x1800001 < HFP ACL SCO >    ← audio link live
Audio:     Instamic  Default Input Device: Yes  16000 Hz    ← it IS the system mic
BLE:       connected, FF10 → FF11 [NRW], subscribed
           21:30:29.201  op 03 [35]   ▶︎ RECORD START
           21:30:32.686  op 03 [36]   ■ RECORD STOP  held 3.49s
```

The button events flow **while the Mac is using the Instamic as its microphone**.
Note `SCO` in the Classic service list — that's the synchronous audio channel
actually carrying voice, not just a control link.

### What this means for the design

The entire "expensive remote control" compromise in handoff §2 dissolves. The
shipped architecture is not "Instamic triggers, some other mic records". It is:

- **Instamic = the microphone** (16 kHz mono over HFP — which is also Whisper's
  native input rate, so it costs nothing in transcription terms)
- **Instamic's button = the trigger**, over BLE, concurrently
- One hand, one device, and the close-mic placement that makes whispering in an
  office viable in the first place

No virtual audio driver, no voice-activity detection, no second microphone.

### Why the handoff got it wrong

It was reasoning from Zoom's "Configuration Modes and Profiles" document rather
than from a measurement, and the note as transcribed is self-contradictory —
it claims Classic Audio is disabled in the one mode where the Mac hears audio.
Documentation about which modes the *vendor's app* uses is not the same as a
firmware constraint.

---

## Verdict: the `0x03` hypothesis holds

Four presses, measured start-to-stop:

| Take | Intended | `0x02` press frames | `0x03` state frames |
|---|---|---|---|
| 1 | short | 3.60 s | 5.22 s |
| 2 | long | 6.93 s | 8.55 s |
| 3 | short | 3.54 s | 5.13 s |
| 4 | long | 9.78 s | 11.37 s |

Short/long/short/long, with the two short takes agreeing to within 60 ms. The
durations track the presses, which is the discrimination the original capture
(three presses of ~4 s each) could not provide. `0x03` payload `0x35`/`0x36` is
the record state.

Exactly 8 `0x03` frames appeared — 4 starts, 4 stops, none spontaneous, including
across the 13 s, 4 s and 3.4 s idle gaps between takes.

**Checksum rule confirmed live.** 34 frames parsed, **0 malformed**, across
payloads from 1 to 9 bytes. `(1 - opcode - sum(payload)) & 0xFF` is correct.

One caveat on the format: the checksum covers `opcode + sum(payload)` as a single
total, so it cannot detect a mis-split between the opcode byte and the payload.
The length byte is what fixes the boundary, and frame sizes matched throughout.

---

## The finding that changes the design: `0x03 [36]` lags the button by 1.65 s

Every cycle has the same shape. Start:

```
02 [48 02]        ← button press
03 [35]           ← +30 ms, record state = started
04 [44 FF]
02 [3A 03 4C]
07 [4F …]
```

Stop:

```
02 [44 02]        ← button press
09/02 [49 …]      ← +1.5 s
03 [36]           ← +1.65 s, record state = stopped
```

`02 [44 02]` → `03 [36]` measured **1.651, 1.650, 1.620, 1.651 s** — mean 1.643 s,
standard deviation **13 ms**.

**The lag is mode-dependent.** In Bluetooth Microphone Mode the same interval
measures **1.051 and 1.050 s** rather than 1.643 s. So the delay cannot be
compensated with a constant — the trigger has to key off `02 [44 02]` itself.

Two human presses could never be that consistent relative to each other, so one
event is machine-derived from the other. Causality settles which: the press is
the only thing that stops the recording, and `02 [44 02]` is the earliest event
correlated with it, so `[44 02]` is the press and `03 [36]` is the device
reporting *after* it finishes closing the file on internal storage — a flush
delay, which is exactly the kind of thing that takes a consistent 1.6 s.

**Consequence:** triggering the stop hotkey on `03 [36]`, as the handoff
implies, appends **1.65 seconds of dead air to every single dictation**. On the
start side the equivalent lead is 30 ms, which is irrelevant.

### Recommended trigger mapping

| Event | Frame | Why |
|---|---|---|
| start | `03 [35]` | 30 ms behind `02 [48 02]`; not worth the extra false-positive surface |
| stop | `02 [44 02]` | 1.65 s earlier than `03 [36]` |
| stop (fallback) | `03 [36]` | fires only if no `[44 02]` was seen this cycle |

The fallback matters because `0x02` is a *shared* opcode — it also carries
`[48 02]`, `[3A 03 4C]` and the 9-byte telemetry frame — so the stop trigger must
match on the full `(opcode, payload)` pair `02 [44 02]`, never on the opcode
alone. In this capture `[44 02]` appeared exactly 4 times, once per stop, but
n=4; the idle soak is what tests whether it ever appears unprompted.

---

## Corrections to the handoff

| Handoff says | Actually observed |
|---|---|
| Advertises as `Instamic BLE` | Advertises as **`Instamic`** (name resolves to `Instamic BLE` after connecting) |
| Scan by service UUID `FF10` | Advertisement carries **`FF11`** — the *characteristic* UUID. `scanForPeripherals(withServices: [FF10])` finds **nothing**. Scan wide and filter locally. |
| On subscribe: `0x07` then `0x09` | On subscribe: `0x02` then `0x07` (see opcode instability below) |

GATT itself matched the handoff exactly: service `FF10` with characteristic
`FF11 [NRW]`, plus the untouched `FCC1`. Address rotation confirmed — the
peripheral identifier differs from the capture's, as expected.

### Opcode instability — unresolved, not blocking

The 9-byte frame that closes each cycle arrives with **alternating opcodes**:

```
op 02  49 07 89 E9 C0 61 37 01 02     ← on subscribe
op 09  49 40 86 E9 C0 5D 37 01 02     ← take 1
op 02  49 07 81 E9 C0 56 37 01 02     ← take 2
op 09  49 40 7E E9 C0 53 37 01 02     ← take 3
op 02  49 07 77 E9 C0 49 37 01 02     ← take 4
```

Opcode `09` always pairs with payload byte 1 = `0x40`, opcode `02` with `0x07`.
An identical-shaped frame carrying two different opcodes suggests the
opcode/payload boundary is not what we think it is, or that a sequence bit lives
in there. This is also the likely explanation for the handoff seeing `07`/`09`
on subscribe where we saw `02`/`07`.

It does not block anything: only `03 [35]`, `03 [36]` and `02 [44 02]` are
load-bearing, and all three are matched on the full opcode-plus-payload pair.
But it does mean **the opcode table should be treated as provisional**, and the
app must ignore unrecognized frames rather than assuming the table is complete.

### Free telemetry, for later

Byte 5 of that 9-byte payload decrements in proportion to seconds recorded:

| | remaining | Δ | hold |
|---|---|---|---|
| subscribe | 97 | | |
| take 1 | 93 | −4 | 3.60 s |
| take 2 | 86 | −7 | 6.93 s |
| take 3 | 83 | −3 | 3.54 s |
| take 4 | 73 | −10 | 9.78 s |

That is ~1 unit per second of recording — a remaining-capacity counter, probably
the low byte of a wider field (`E9 C0` sits directly above it and held constant).
Decoding it would give the menu bar a "recording time left" readout for free.
Phase 4, not now.

---

## Other observations from the mode probe

- **Address rotation confirmed.** The peripheral identifier differed on every
  session (`9EF037C8…`, then `D272B867…`). Matching by address would break
  immediately, as the handoff warned.
- **Connecting mid-recording is a real case.** The probe attached while the mic
  was already recording and saw a bare `03 [36]` with no preceding `35`. The app
  must treat a stop-without-start as benign and not fire a stray hotkey.

## The FCC1 config service, decoded

Polled with `ramble-sniff --poll 5`. Nine characteristics, four readable
(`f9c13107` skipped — it reproducibly returns GATT error 133, as the handoff
warned). Full UUIDs are `f9c131NN-59d4-11ed-9c9d-0800200c9a66`.

| Characteristic | Bytes | Contents |
|---|---|---|
| `f9c13101` | 10 | `80 1B 60 C3 00 00 00 00 00 80` — static across the run |
| `f9c13102` | 8 | ASCII **`Instamic`** — device name |
| `f9c13105` | 1 | flags byte — oscillates `E6`↔`E2`. **Not battery** (see below) |
| `f9c13108` | 64 | status block — see below |

### `f9c13108` is the useful one

```
offset 5      02 → 03  while recording
offset 6      00 → 01  while recording          ← clean boolean
offset 7..15  ASCII "PINS_001"                  ← filename prefix
offset 32..35 LE u32 = 32,808,716
offset 38..41 LE u32 = 65,567,325
```

**Offset 6 is a live recording-state flag** — `00` idle, `01` recording,
flipping exactly in step with the `0x35`/`0x36` notifications and reverting
afterwards.

This solves a problem flagged earlier: when Ramble connects while a recording is
already in progress, it sees a bare `03 [36]` with no matching start and has no
idea what state the device is in. Now it can simply **read offset 6 on connect**
and know. No guessing, no stray hotkey.

The two 32-bit counters are free and total storage — their ratio is 0.5004, and
the magnitudes are consistent with a half-full card (16.8 GB of 33.6 GB if the
unit is 512-byte sectors, or 33.6 GB of 67.1 GB if it is 1 KB). The unit is
undetermined; a long recording would pin it down.

Note that offset 32–33 (`0C 9F`) equals bytes 5–6 of the 9-byte notification
frame in the same session. So the "counter that decrements with recording
seconds" noted above is the low half of the free-space field — it was storage
filling up, not a time budget.

### Battery: not exposed. `f9c13105` was a false lead.

The first two samples of `f9c13105` were `E6` → `E2`, which looked like a
counter going down. A 10-minute poll shows it **oscillating**, not decreasing:

```
21:42:32  E6   (first read)
21:46:32  E2   Δ [0] E6→E2
21:49:32  E6   Δ [0] E2→E6
21:50:32  E2   Δ [0] E6→E2
21:51:32  E6   Δ [0] E2→E6
```

```
0xE6 = 1110 0110
0xE2 = 1110 0010
              ^ only bit 2 moves
```

A single toggling bit is a status flag, not a fuel gauge. Reading a downward
trend from two samples was wrong.

**No battery level is exposed on any readable characteristic.** `f9c13101`
(10 bytes) stayed byte-identical for the whole run, and `f9c13108` moved only
in its recording-state bytes. The remaining candidate is `f9c13107` — the one
that returns GATT error 133 and is presumed to need encryption or an app-level
handshake. That would neatly explain how the vendor's app shows a battery
readout while we cannot: it authenticates first.

Getting battery would mean reverse-engineering that handshake, which is a
project of its own and is **not** on the path to a working trigger.

### Bluetooth Microphone Mode does not record locally

Across a full record cycle in this mode, the free-space counters in `f9c13108`
did not move at all:

```
21:43:33  Δ [5] 02→03 [6] 00→01     ← recording started
21:44:33  Δ [5] 03→02 [6] 01→00     ← recording stopped
          offsets 32..41 unchanged throughout
```

In Remote Control Mode the same counter dropped measurably for every take. So
in Bluetooth Microphone Mode the button is a **pure control signal** — the LED
turns red and the state flag flips, but nothing is written to the card.

**Consequence for the design:** the "high-quality 32-bit float local backup"
that the handoff treats as a consolation prize is not available in the mode we
actually want to run in. You get the microphone and the trigger; you do not
also get a local safety copy. That is the right trade for dictation, but it
should be a known one rather than a surprise.

## Still outstanding

- **10-minute idle soak** — running. Confirms `0x03` and `02 [44 02]` never fire
  spontaneously from a sleep timeout, low battery, or standby.
- **Sleep/wake and out-of-range reconnect** — the address rotates, so reconnect
  is rediscovery rather than a cached handle.
- **`[44 02]` uniqueness** over a longer window, before it becomes the stop trigger.
- **End-to-end audio check** — confirm a whisper actually registers at usable
  level through the 16 kHz HFP path. No `ffmpeg`/`sox` on this machine, so this
  needs a small level meter built against AVAudioEngine.
