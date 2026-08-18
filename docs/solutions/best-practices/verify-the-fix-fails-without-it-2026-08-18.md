---
title: A regression test that has never failed proves nothing
date: 2026-08-18
category: docs/solutions/best-practices
module: testing
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - Adding a regression test alongside a bug fix
  - Reviewing your own fixes before shipping
  - Diagnosing a live system with logs and platform tooling available
tags: [testing, regression, verification, code-review, diagnosis]
---

# A regression test that has never failed proves nothing

## Context

A code review of this repo produced one P0 and eight P1 findings. Fixing them
added 87 checks (136 → 223). Every one of those checks passed on first run —
which is exactly the condition under which a test is worthless, because a test
that has never been red has not been shown to detect anything.

## Guidance

### Revert the fix and watch the specific check go red

For each fix, stash the change and run the suite. Name the check that fails.

```
$ git checkout Sources/RambleCore/TriggerMachine.swift   # drop the fix
$ swift run ramble-check
  ✗ and still releases what it held
  ✗ a mismatched onStop cannot strand the held key
  ✗ the take still ends as the hold it began as
FAIL  143/151 checks
```

That output is the evidence the test is real. Restore the fix, confirm green,
move on. It costs a minute per fix.

This caught a genuine defect in a *fix*: `pendingRelease` was a single slot
cleared unconditionally on any successful release, so a later take releasing a
different key silently erased the record of a key that was still physically
down — re-introducing the exact class of bug the fix existed to eliminate. The
test written for it failed against the flawed version and passed against the
corrected one:

```
✗ and fn is still recorded as stuck, not forgotten
FAIL  184/185 checks
```

### Review your own fixes with a fresh pass

Running the review a second time — over the diff that fixed the first review's
findings — surfaced two real defects the fixing work had introduced or missed:

- the `pendingRelease` clobber above (P1)
- `Keystroke.post()` swallowing `CGEvent` creation failure, so `release()` could
  report success without posting the keyUp that the entire stuck-key guarantee
  rests on (P2)

Fix work is normal work. It deserves the same scrutiny as the code it replaces,
and it is written under more time pressure and more confidence.

### Diagnose from the artifact, not from inference

Three wrong guesses in this session, each corrected by looking at something that
was already available:

| Guess | Reality | What answered it |
|---|---|---|
| "The mic is in the wrong mode" | It was in the right mode; the Classic link was down | `system_profiler SPBluetoothDataType` — *Not Connected* |
| "The mic went to sleep" | The user had switched it off | asking, and `blueutil --is-connected` |
| "It's stuck scanning" | It was connected and receiving frames; Accessibility was denied | the app's own log |

In every case the evidence existed before the guess. The project's own
diagnostic CLIs (`ramble-sniff --scan-only`) answered in seconds what inference
got wrong.

Build the tools that make a system explain itself, then actually consult them
first. A log line saying `failed: "Accessibility permission not granted"` ends an
investigation that System Settings would have prolonged indefinitely, because
Settings displayed the permission as enabled.

## Why This Matters

Untested tests, unreviewed fixes, and inferred diagnoses share a failure mode:
they all *look* like the work is done. The cost is paid later, by someone who
trusts a green suite that checks nothing, or follows a confident diagnosis that
was never checked against the machine.

## When to Apply

Every regression test, every time. The revert-and-watch-it-fail loop is cheap
enough that skipping it is never justified by time.

## Examples

The full loop, as run here:

```sh
cp Sources/RambleCore/TriggerMachine.swift /tmp/fixed.swift
git checkout Sources/RambleCore/TriggerMachine.swift
swift run ramble-check            # expect: the new checks fail, by name
cp /tmp/fixed.swift Sources/RambleCore/TriggerMachine.swift
swift run ramble-check            # expect: green
```

For a fix too small to stash, invert the condition in place and confirm the
check bites:

```swift
// deliberately unconditional, to prove the test catches it
pendingRelease = nil
```

## Related

- `docs/solutions/integration-issues/macos-accessibility-bound-to-code-signature-2026-08-18.md`
