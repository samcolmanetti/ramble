# Instamic → Mac Dictation Trigger — Handoff

> **Superseded, kept as the source record.** This is the original handoff, written
> before any code existed. It is preserved because the implementation and the other
> documents cite its section numbers as evidence (§2 for what was ruled out, §3 for
> the GATT reference, §4 for the opcode table, §6 for the duplicate-notification
> behaviour), and because a couple of its conclusions were later *overturned* by
> measurement — which is itself worth keeping on the record.
>
> For what is actually true and shipped, read these instead:
>
> - [PROTOCOL.md](PROTOCOL.md) — the verified wire protocol
> - [FINDINGS.md](FINDINGS.md) — every measurement, including the corrections to this document
> - [README.md](README.md) — how to build, configure, and install it
>
> In particular, §2's claim that BLE and Bluetooth Classic audio are mutually
> exclusive on this device **is wrong** — see FINDINGS.md. The mic works as
> microphone and trigger simultaneously, which is the whole reason this project
> exists.

**Status (historical):** Protocol reverse-engineered, unverified against a second capture. No code written yet.
**Deliverable:** A macOS menu bar app (Swift, CoreBluetooth) that fires a global hotkey when the Instamic's physical record button is pressed.

---

## 1. Goal

Press the physical button on a Zoom Instamic Pro Plus → macOS dictation (Wispr Flow or MacWhisper) starts recording → transcribed text is pasted at the cursor. Press again → stop.

The user wants a hardware trigger for dictation. The Instamic is the device they have.

---

## 2. What was ruled out (don't re-litigate these)

| Approach | Why it's dead |
|---|---|
| Instamic sends a keystroke / HID event | It doesn't. No HID profile. The button is a local control only. |
| Use it as an HFP Bluetooth mic + read the button | **BLE and HFP are mutually exclusive on this device.** In Bluetooth Microphone Mode (the only mode where the Mac hears audio), BLE and Classic Audio are disabled — so the Mac cannot see button events. Confirmed in Zoom's official "Configuration Modes and Profiles" doc. |
| Custom firmware | No SDK, signed/encrypted images behind a registration-gated updater, unknown SoC (FCC ID `T7V1326C2`), brick risk. Months of work. |
| AVRCP media keys | Not implemented by the device. A feature request has been suggested to `support@instamic.io` but assume no. |

### The consequence you must design around

This app runs in **Remote Control Mode** (BLE active). In that mode the Instamic records to its own internal storage and streams **nothing** to the Mac.

So the shipped architecture is:

- Instamic = **trigger** (BLE button events) + a high-quality 32-bit float local backup recording
- Mac's built-in mic (or any other input) = the **audio source** Wispr Flow / MacWhisper actually transcribes

This is an expensive remote control. The user knows and accepts this. Do not silently redesign around it.

---

## 3. Device / GATT reference

Device name: `Instamic BLE`
Address seen in capture: `6D:07:67:6E:6D:1B` — **this is a resolvable private address and rotates.** Never scan or match by address. Scan by service UUID.

### Services

```
Generic Access            0x1800
  Device Name    [R]      0x2A00   → "Instamic BLE"
  Appearance     [R]      0x2A01   → 0x0000
Generic Attribute         0x1801
  Database Hash  [R]      0x2B2A

Unknown Service           0000ff10-0000-1000-8000-00805f9b34fb   ← THE ONE THAT MATTERS
  Notify char    [N R W]  0000ff11-0000-1000-8000-00805f9b34fb
    CCCD                  0x2902

Unknown Service           0000fcc1-0000-1000-8000-00805f9b34fb
  f9c13101 [R]
  f9c13102 [R]
  f9c13103 [W]
  f9c13104 [WNR]
  f9c13105 [R]   → read back 0xE6 (meaning unknown)
  f9c13106 [W]
  f9c13107 [R]   → GATT ERROR 133 on read, twice. AVOID — likely needs encryption
                    or an app-level handshake.
  f9c13108 [R]
  f9c13109 [W]
```

**Only `FF11` is needed.** The `fcc1` service is presumably the command/config channel used by the Instamic Remote app (settings, gain, timecode). Untouched, unnecessary for this project.

**Single-central limitation:** only one BLE central can hold the connection. The official Instamic Remote app must be force-quit for this app to connect, and vice versa.

---

## 4. Wire protocol (derived from capture, verified)

### Frame format

```
00 02 <len> <opcode> <payload[len]> <chk>
```

- Fixed 2-byte preamble `00 02`
- `len` = payload length in bytes
- Total frame size = `len + 5`
- `chk` = `(1 - opcode - sum(payload)) & 0xFF`

Both the length rule and the checksum were verified against **all seven** distinct frames in the capture, exactly. Use the checksum to reject malformed/partial notifications.

```swift
func isValid(_ f: [UInt8]) -> Bool {
    guard f.count >= 6, f[0] == 0x00, f[1] == 0x02 else { return false }
    let len = Int(f[2])
    guard f.count == len + 5 else { return false }
    let opcode = f[3]
    let payload = f[4..<(4 + len)]
    let sum = payload.reduce(0) { ($0 &+ Int($1)) }
    let chk = UInt8((1 - Int(opcode) - sum) & 0xFF)
    return chk == f[f.count - 1]
}
```

### Opcodes observed

| Opcode | Payload example | Interpretation |
|---|---|---|
| `0x03` | `35` / `36` | **Record state. This is the trigger.** `0x35` = started, `0x36` = stopped. |
| `0x04` | `44 FF` / — | Emitted right after start. Unknown; possibly level/gain. |
| `0x02` | `3A 03 4C` (start) / `44 02` (stop) | Unknown; variable length. Possibly status/battery/timecode. |
| `0x07` | `4F AA 58 B9 03 1E 02` | Sent once on subscribe. Session/device info? |
| `0x09` | `49 C0 8F E9 C0 38 9F 01 02` | Sent once on subscribe. Session/device info? |

### Evidence for `0x03` = record state

Three identical five-packet cycles in the capture, each triggered by a button press:

```
17:19:34.355  03 [35]        ← start
17:19:34.355  04 [44 FF]
17:19:34.399  02 [3A 03 4C]
        ...3.2s gap...
17:19:37.643  02 [44 02]
17:19:38.767  03 [36]        ← stop

17:21:30.881  03 [35]   ... 4.9s ...  17:21:36.850  03 [36]
17:21:40.423  03 [35]   ... 4.5s ...  17:21:46.062  03 [36]
```

`0x35` → `0x36` bookend every cycle identically, and the gap between them tracks how long each take ran.

### ⚠️ Verify this before writing the app

The capture only contains three presses of similar duration. **First task: re-capture with nRF Connect using deliberately different durations (2s, 10s, 2s, 10s) and confirm the gaps track.** Also confirm `0x35`/`0x36` never appear spontaneously (e.g. on idle, low battery, or sleep timeout). If either check fails, the hypothesis is wrong and the trigger needs re-identification.

---

## 5. Implementation plan

**Target:** macOS menu bar app, Swift + CoreBluetooth + CoreGraphics. ~150 lines. No third-party dependencies.

### Components

1. **BLE manager** (`CBCentralManager`)
   - `scanForPeripherals(withServices: [CBUUID(string: "FF10")])`
   - On discover → connect → `discoverServices([FF10])` → `discoverCharacteristics([FF11])` → `setNotifyValue(true, for:)`
   - Implement `centralManager(_:didDisconnectPeripheral:error:)` with reconnect + backoff. The device sleeps and the address rotates; reconnection must be robust.

2. **Frame parser**
   - Validate preamble, length, checksum (see above). Drop invalid frames silently.
   - Match opcode `0x03`; branch on payload byte `0x35` / `0x36`.

3. **Hotkey emitter** (`CGEventCreateKeyboardEvent` / `CGEvent(keyboardEventSource:)`)
   - Post key-down + key-up with modifiers to the HID event tap (`.cghidEventTap`).
   - **Requires Accessibility permission.** App must prompt via `AXIsProcessTrustedWithOptions` on first run and degrade gracefully if denied.
   - Make the emitted combo user-configurable — Wispr Flow and MacWhisper use different defaults, and the user may want push-to-talk vs toggle semantics.

4. **Menu bar UI** (`NSStatusItem`)
   - Connection state (disconnected / scanning / connected)
   - Last event + timestamp (essential for debugging)
   - Hotkey configuration
   - Toggle: treat `0x35`/`0x36` as toggle vs push-to-talk

### Config surface

- Target hotkey (default: something unbound, e.g. `⌃⌥⌘D`)
- Mode: toggle (fire once on `0x35`) vs hold (fire on `0x35`, fire again on `0x36`)
- Auto-reconnect on/off

---

## 6. Known gotchas

- **Private address rotation** — scan by service UUID `FF10`, never persist or match the MAC.
- **`f9c13107` returns GATT ERROR 133** — don't read it. Not needed anyway.
- **Official app conflict** — Instamic Remote must be closed. Consider surfacing "another app may be connected" when connection fails repeatedly.
- **Sleep Mode** — the user should set Sleep Mode → Off in the Instamic Remote app so the unit doesn't power down from standby. Battery is 3.5h (Pro Plus) / 4.5h (Pro Plus C) continuous; it charges over USB-C while paired, so a desk setup should stay on the cable.
- **Accessibility permission** is required for synthetic key events and is the most common silent-failure mode. Check it explicitly at launch, not just at first press.
- **Duplicate notifications** — packets 3 and 4 in a cycle arrive within the same millisecond. Debounce on the `0x03` opcode specifically; don't debounce across all opcodes.

---

## 7. Suggested build order

1. Re-capture and confirm the `0x35`/`0x36` hypothesis (section 4).
2. CLI proof of concept: connect, subscribe, print decoded frames to stdout. Confirm button presses appear reliably over a 10-minute session including a sleep/wake cycle.
3. Add hotkey emission. Test against Wispr Flow and MacWhisper.
4. Wrap in menu bar UI + config + reconnect logic.

Step 2 is the real risk. Don't build UI until it's proven.
