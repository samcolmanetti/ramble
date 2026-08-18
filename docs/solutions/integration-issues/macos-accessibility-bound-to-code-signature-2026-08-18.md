---
title: Accessibility permission survives in Settings but stops working after every rebuild
date: 2026-08-18
category: docs/solutions/integration-issues
module: macos-permissions
problem_type: integration_issue
component: authentication
severity: high
symptoms:
  - "App log reads `failed: \"Accessibility permission not granted\"` while System Settings shows the app enabled"
  - "Synthesized keystrokes silently do nothing after an upgrade or rebuild"
  - "Toggling the Accessibility switch off and back on changes nothing"
  - "Restarting the app changes nothing"
root_cause: missing_permission
resolution_type: code_fix
tags: [tcc, accessibility, code-signing, ad-hoc, cgevent, macos, tccutil]
---

# Accessibility permission survives in Settings but stops working after every rebuild

## Problem

An ad-hoc signed macOS app that synthesizes keystrokes loses its Accessibility
grant on every rebuild or upgrade, but System Settings keeps showing it as
enabled — so the app looks broken with no visible cause.

## Symptoms

- The app's own log says the permission is missing:
  `RECORD START → failed: "Accessibility permission not granted"`
- System Settings → Privacy & Security → Accessibility lists the app, switch **on**
- Toggling the switch off and back on does not help
- Quitting and relaunching does not help
- A user following the documented advice concludes the app is simply broken

## What Didn't Work

- **Toggling the switch off and on.** This is the advice almost everyone gives,
  including our own cask caveats. It does not work, because the row is bound to
  a code signature, not to a path. Flipping the switch re-enables a binding that
  still points at the old signature.
- **Restarting the app.** `AXIsProcessTrusted()` returns the true current state,
  so the app was reporting the situation correctly all along.
- **Reinstalling on top.** A fresh ad-hoc build has a fresh hash, so this
  produces yet another identity TCC does not recognise.

## Solution

Delete the TCC record so macOS is forced to bind to the binary actually
installed, then grant again:

```sh
tccutil reset Accessibility io.ramble.Ramble
```

Then relaunch and allow the app when it asks.

Because a user cannot be expected to know this, put it in the app. Ramble adds
a menu item under the Accessibility warning — *"Already enabled? Repair it…"* —
which runs the reset, re-requests trust, and opens the settings pane:

```swift
let reset = Process()
reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
reset.arguments = ["reset", "Accessibility", id]
try reset.run()
reset.waitUntilExit()

Keystroke.requestTrust()          // prompts properly now the record is gone
NSWorkspace.shared.open(Self.accessibilitySettingsURL)
```

## Why This Works

macOS ties a TCC grant to the requesting binary's **code signature**, not to its
path or bundle identifier alone. An ad-hoc signature (`codesign --sign -`) is a
content hash, so **every build is a different application as far as TCC is
concerned**. After an upgrade the stored record still exists and still reads as
approved, but it authorises a signature that no longer exists on disk. The
switch in Settings edits that stale record rather than rebinding it.

`tccutil reset` removes the record entirely, so the next request creates a new
one bound to the installed binary.

A stable Developer ID signature avoids the whole problem — the signature is
identical across builds, so grants survive upgrades. That costs an Apple
Developer Program membership; the repair path above is the free alternative.

Homebrew itself notices, and prints a hint worth trusting:

```
Warning: ramble's signer changed so macOS may prompt at next launch.
```

## Prevention

- **Never document "toggle it off and back on"** for an ad-hoc signed app. It is
  wrong and it costs users the most time of anything in the install flow.
- **Ship a repair affordance in the UI.** The failing state is invisible from
  Settings, so the app is the only place that can explain it.
- **Have the app report the permission in its own log**, so the diagnosis is one
  `tail` away rather than a guess.
- **Treat a permission failure as a first-class outcome**, not a silent no-op.
  Ramble's trigger machine returns `.failed(reason:)` and logs it; that log line
  is what identified this in seconds once we looked.
- If the app is worth distributing to people who will not tolerate re-granting,
  a Developer ID and notarisation is the real fix.

## Related

- `docs/solutions/workflow-issues/shipping-an-ad-hoc-signed-mac-app-2026-08-18.md`
