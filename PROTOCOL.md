# How Ramble detects Instamic button presses

Short version: **the Instamic broadcasts its record state over Bluetooth LE, and
we subscribe to it.** No audio analysis, no inference — the device tells us
directly, using the same channel its own remote-control app uses.

---

## The channel

The Instamic exposes a BLE GATT service that the official Instamic Remote app
talks to. Two things live there:

```
Service  FF10
  └── Characteristic FF11  [notify, read, write]     ← the event stream
Service  FCC1                                        ← config/status, 9 chars
```

Subscribe to notifications on `FF11` and the device pushes a frame every time
its state changes — including every button press.

**One caveat that costs an hour if you don't know it:** the advertisement
packet contains **`FF11`**, the *characteristic* UUID, not `FF10`. Scanning with
`scanForPeripherals(withServices: [FF10])` — the obvious thing, and what the
GATT table implies — finds nothing at all. Scan wide and filter on the local
name (`Instamic`) or on either UUID.

The device also uses a **resolvable private address that rotates**, so never
match or cache by MAC.

And it accepts exactly **one BLE central at a time**. If the Instamic Remote app
is open, you get nothing; if you're connected, it gets nothing.

## The frame format

```
00 02 <len> <opcode> <payload[len]> <chk>
```

- `00 02` — fixed preamble
- `len` — payload length; total frame is `len + 5` bytes
- `chk` — `(1 - opcode - sum(payload)) & 0xFF`

Verified against live traffic: several hundred frames parsed, zero checksum
failures, payloads from 1 to 9 bytes. Worth validating rather than trusting —
it cleanly rejects partial notifications.

One structural note: the checksum covers `opcode + sum(payload)` as a single
total, so it *cannot* detect a mis-split between the opcode byte and the
payload. The length byte is what fixes that boundary.

## The button

```
op 0x03, payload 0x35  →  recording started
op 0x03, payload 0x36  →  recording stopped
```

That's it. A full press cycle looks like:

```
02 [48 02]        button pressed
03 [35]           +30 ms   → RECORDING STARTED
04 [44 FF]
02 [3A 03 4C]
...
02 [44 02]        (see the trap below)
03 [36]           → RECORDING STOPPED
```

### The trap: `02 [44 02]` is a 15-second timer

This one is worth passing on, because it is genuinely convincing until it isn't.

`02 [44 02]` appears about 1.1 seconds *before* `03 [36]` on short takes. That
looks like the real button press, with `0x36` arriving only after the device
finishes flushing its file — and the 1.1 s lead is remarkably consistent
(σ = 13 ms across four takes), which reads like a causal relationship.

It isn't. On longer takes:

| Take length | `[44 02]` fires at |
|---|---|
| 48.7 s | 15.00 s |
| 41.6 s | 15.03 s, 40.50 s |
| 34.7 s | 15.00 s, 33.51 s |

Measured first-offsets across five takes: **15.00, 15.02, 15.03, 15.00,
15.00 s**. It's a fixed timer that *also* happens to fire at the real press.
Every early test take was under 15 seconds, so the timer never showed.

Trigger on it and every dictation truncates at exactly 15 seconds.
**Use `03 [36]`.**

## Why this beats audio-level detection

Both approaches work. They fail differently, and the failure modes are what
matter:

| | Audio-level detection | BLE notification |
|---|---|---|
| What it observes | a *consequence* of the button | the button itself |
| Speech, coughs, door slams | can false-trigger | irrelevant |
| Pressing during silence | nothing to detect | works |
| Start vs stop | inferred from state | explicit, distinct opcodes |
| Latency | however long the threshold takes | ~30 ms |
| Audio path | must be capturing to detect | independent |

The last row is the big one. Audio-level detection requires you to be listening
to the mic to notice the button — so the trigger and the audio are coupled. BLE
notifications are a separate transport, which means the button works even while
something else owns the audio stream.

## The thing everyone assumes is impossible

Zoom's documentation says BLE and Classic audio are mutually exclusive on this
device — that in Bluetooth Microphone Mode, where the Mac actually hears audio,
BLE is off and the button is invisible.

**Measured directly, that is false.** With the Instamic in Bluetooth Microphone
Mode, all of this was true simultaneously:

```
Classic:  Instamic  Services: 0x1800001 < HFP ACL SCO >   ← voice channel live
Audio:    Instamic  Default Input Device: Yes, 16000 Hz   ← it IS the system mic
BLE:      connected, FF10 → FF11, subscribed
          op 03 [35]  ▶︎ RECORD START
          op 03 [36]  ■ RECORD STOP
```

So you can have the Instamic as your microphone **and** its button as a trigger,
at the same time, from one device. Which is the whole point — otherwise it's an
expensive remote control for some other microphone.

(16 kHz mono over HFP sounds like a downgrade and mostly isn't: Whisper-family
models resample to 16 kHz internally anyway, and a lavalier at your mouth beats
a good desk mic across a room. Measured SNR for a deliberately quiet whisper in
a normal room: **34 dB**.)

## Reproducing this

```sh
swift run ramble-sniff            # connect, decode, print every frame
swift run ramble-sniff --poll 5   # also poll the FCC1 config service
swift run ramble-tap              # watch what the OS receives, for the output side
```

The sniffer prints each frame with a timestamp, opcode, payload hex, and
checksum validity, and measures the gap between start and stop.

**When you test, include one take of 45+ seconds.** That single omission is what
hid the 15-second timer.
