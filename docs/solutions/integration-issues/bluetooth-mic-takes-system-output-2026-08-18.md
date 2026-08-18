---
title: Connecting a Bluetooth microphone hands macOS a speaker too, and macOS takes it
date: 2026-08-18
category: docs/solutions/integration-issues
module: audio-routing
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "All system audio drops to 16 kHz mono after connecting a Bluetooth mic"
  - "The mic becomes the default output device as well as the default input"
  - "Output is hijacked again every time the headset link reconnects"
  - "macOS does not reconnect a paired Bluetooth mic on its own, so the app runs with no audio source"
root_cause: wrong_api
resolution_type: code_fix
tags: [bluetooth, hfp, coreaudio, iobluetooth, audio-routing, macos, sco]
---

# Connecting a Bluetooth microphone hands macOS a speaker too, and macOS takes it

## Problem

A wireless microphone cannot be connected "as a microphone only". It speaks HFP
— a *headset* profile — so bringing the link up for its mic unavoidably offers
macOS a speaker as well, and macOS immediately routes playback to it, dropping
all system audio to 16 kHz mono.

## Symptoms

- Everything on the machine suddenly sounds like a phone call
- The device appears in **both** the input and output lists
- `SwitchAudioSource -c -t output` reports the microphone
- Setting output back by hand works, until the link drops and returns
- Separately: macOS will not reconnect the paired mic by itself, so a trigger
  can fire into a dictation app that has nothing to listen to

## What Didn't Work

- **Looking for a mic-only connection.** There isn't one. `IOBluetoothDevice`
  opens the device, not a profile subset. The speaker endpoint comes with it.
- **Fixing the output once, at connect time.** macOS re-grabs output on every
  reconnect, so a one-shot correction silently stops holding.
- **Hardcoding the output device name in config.** Wrong the moment the user
  docks, plugs in headphones, or moves desks — the mic would interrupt playback
  on their monitor and hand it back to the laptop speakers.
- **Assuming the device was in the wrong mode.** It was not; the Classic/HFP
  link was simply down. `system_profiler SPBluetoothDataType` showed the device
  under *Not Connected* while BLE was live. Two separate links to one device.

## Solution

Fix it at the CoreAudio routing layer, not the Bluetooth layer, and make the
correction *standing* rather than one-off:

1. If the mic is not present to CoreAudio at all, open the Bluetooth link.
2. Claim the mic as the default **input**.
3. If the mic has taken the default **output**, hand playback back.
4. Re-check on a timer; each pass is a no-op once things are right.

The decision is pure, so it can be tested without a sound card:

```swift
public static func plan(devices: [AudioDevice],
                        defaultInput: AudioDevice?,
                        defaultOutput: AudioDevice?,
                        micName: String,
                        preferredOutput: String? = nil,
                        rememberedOutput: String? = nil) -> AudioRoutingPlan
```

Which output to restore is **learned, not configured**. Whatever playback was
using before the mic interrupted is what the user wanted:

```swift
// Learn from the present moment: if playback is somewhere sensible right
// now, that is where it should go back to later.
let remember = defaultOutput.flatMap { isMic($0) ? nil : $0.name }
```

Nothing is learned while the mic itself holds the output — there is nothing good
to learn in that moment, and recording it would teach the app to "restore"
playback to the mic. The learned value is persisted, because at login the mic
can connect before playback has ever been observed anywhere sensible.

Output is only ever taken back **when the mic actually holds it**. An output the
user deliberately chose is left alone.

## Why This Works

HFP is bidirectional by design; the `SCO` channel in the Classic service list is
the one actually carrying voice. There is no protocol-level way to ask for half
of it. So the connection layer cannot express the intent, and the routing layer
must. Since macOS reasserts its own preference on every reconnect, the
correction has to be a standing invariant enforced on a timer, not an event
handler that fires once.

BLE and Classic audio are **separate simultaneous links to the same physical
device** — the button events and the microphone audio flow at the same time.
Confirming that required checking both independently rather than reasoning from
one to the other.

## Prevention

- Expect any Bluetooth "microphone" to present as a headset. Design for taking
  the input and returning the output, from the start.
- Make routing corrections idempotent and run them on a timer. Log only on
  change, or a 5-second tick becomes a log spammer.
- Learn user preferences by observation rather than asking them to name devices
  in config; persist what you learn so it survives a restart.
- Diagnose with the platform's own reporting before inferring device state:
  `system_profiler SPBluetoothDataType` distinguishes *Connected* from
  *Not Connected*, and `SPAudioDataType` shows what actually holds default I/O.

## Related

- `docs/solutions/best-practices/verify-the-fix-fails-without-it-2026-08-18.md`
