---
title: Five ways a Homebrew cask for an unsigned Mac app breaks, and how each was found
date: 2026-08-18
category: docs/solutions/workflow-issues
module: distribution
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - Distributing a macOS .app through a Homebrew cask
  - Signing ad-hoc rather than with a Developer ID
  - The cask installs a LaunchAgent
  - A release script rewrites the cask's version and checksum
tags: [homebrew, cask, gatekeeper, launchagent, launchctl, codesign, release, macos]
---

# Five ways a Homebrew cask for an unsigned Mac app breaks, and how each was found

## Context

Ramble went from an unpublished repo to a public GitHub release installable via
`brew install --cask` in a single session. Every one of the problems below was
found by *actually installing and upgrading it* — none were visible from reading
the cask, and a 12-reviewer code review caught only the first.

## Guidance

### 1. `sha256 :no_check` plus a quoted-only sed can never write a checksum

The cask shipped `sha256 :no_check`. The release script substituted with:

```sh
sed -i '' -e "s|^  sha256 \".*\"|  sha256 \"${SHA}\"|" Casks/ramble.rb
```

That pattern requires quotes, so it never matches `:no_check`. The script
printed a checksum as though it had written one, and **every release would have
installed unverified, forever**.

Seed a quoted placeholder the substitution can find, and make the script prove
the write landed:

```sh
if ! grep -q "^  sha256 \"${SHA}\"$" Casks/ramble.rb; then
    echo "error: failed to write the checksum into Casks/ramble.rb" >&2
    exit 1
fi
```

The general rule: **a script that reports success it did not achieve is worse
than one that fails.** Verify the side effect, not the exit status of the tool
that was supposed to produce it.

### 2. `uninstall delete:` runs under sudo

```ruby
uninstall launchctl: "io.ramble.Ramble",
          delete:    "#{Dir.home}/Library/LaunchAgents/io.ramble.Ramble.plist"
```

`delete:` is for privileged paths. Pointed at a LaunchAgent in the user's own
home it makes `brew upgrade` stop and ask for a password; non-interactively it
hard-fails and leaves the install half-removed — plist gone, job unregistered,
old app still in `/Applications`. Use `trash:` for anything the user owns.

### 3. A postflight that only bootstraps is a no-op on upgrade

`launchctl bootstrap` does nothing when the job already exists, so after an
upgrade the **old binary keeps running** and the upgrade appears to have done
nothing until the next login. Tear it down first:

```ruby
system_command "/bin/launchctl",
               args: ["bootout", "gui/#{Process.uid}/io.ramble.Ramble"],
               sudo: false, must_succeed: false
system_command "/bin/launchctl",
               args: ["bootstrap", "gui/#{Process.uid}", plist_path],
               sudo: false, must_succeed: false
```

Verify by comparing the PID before and after `brew upgrade`.

### 4. Gatekeeper blocks first launch, and the fix starts a second instance

An ad-hoc signed app arrives quarantined, so launchd's copy is blocked and
*nothing appears to happen*. The user then finds **Privacy & Security → Open
Anyway**, which launches the app through LaunchServices — alongside the copy
launchd is still trying to run. Both survive.

For a device that accepts one connection this is actively harmful: two instances
fight over it, and an event reaching both fires the action twice. Guard at
startup:

```swift
let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
    .filter { $0.processIdentifier != mine }
if let first = others.first { exit(0) }   // the newcomer yields
```

And document the Gatekeeper step as the **first** thing a user meets, not a
footnote — it is the first thing that happens to them.

### 5. `git describe` is not a version

```sh
VERSION="$(git describe --tags --always --dirty)"
```

Before the first tag exists this yields a bare commit hash, so a 0.1.0 release
shipped an app whose `CFBundleShortVersionString` read `da56ec7` while the cask
advertised `0.1.0`. Have the release script pass the version it was given:

```sh
RAMBLE_VERSION="$VERSION" ./Scripts/bundle.sh --release
```

Dev builds still report their commit, which is what you want there.

## Why This Matters

None of these produce an error at build time, and only one was caught by review.
They surface as *the app silently doing nothing*, *the upgrade appearing to work
while running old code*, or *a checksum that was never verified* — failure modes
that look like user error and erode trust in the tool.

## When to Apply

Any time a cask ships an app that is ad-hoc signed, installs a LaunchAgent, or
has its version and checksum rewritten by a script. Install it, upgrade it, and
uninstall it on a real machine before believing any of it works.

## Examples

The verification that mattered, in each case:

```sh
# checksum: compare the cask against the artifact downloaded back from GitHub
gh release download v0.1.2 --dir /tmp/r && shasum -a 256 /tmp/r/Ramble-v0.1.2.zip

# upgrade restarts the app: PID must change
OLD=$(pgrep -f '/Applications/Ramble.app/Contents/MacOS/Ramble')
brew upgrade --cask ramble
NEW=$(pgrep -f '/Applications/Ramble.app/Contents/MacOS/Ramble')

# uninstall needs no password
brew uninstall --cask ramble    # must exit 0 with no sudo prompt

# single instance: launching a second copy must exit
build/Ramble.app/Contents/MacOS/Ramble    # "already running as pid N; exiting"
```

## Related

- `docs/solutions/integration-issues/macos-accessibility-bound-to-code-signature-2026-08-18.md`
