# Protocol Findings — verified against hardware

Capture: `captures/press-test.log`, 2026-08-17, four button presses of
deliberately uneven duration. Supersedes the hypotheses in
[`instamic-ble-trigger-handoff.md`](instamic-ble-trigger-handoff.md) §3–4 where
they disagree.

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

## Still outstanding

- **10-minute idle soak** — running. Confirms `0x03` and `02 [44 02]` never fire
  spontaneously from a sleep timeout, low battery, or standby.
- **Sleep/wake and out-of-range reconnect** — the address rotates, so reconnect
  is rediscovery rather than a cached handle.
- **`[44 02]` uniqueness** over a longer window, before it becomes the stop trigger.
