#!/bin/bash
# One-time setup: create a stable self-signed code signing identity.
#
# Why this matters more than it sounds: macOS ties Accessibility and Bluetooth
# grants to a binary's code signature. Ad-hoc signing (`codesign -s -`) keys them
# to the cdhash, which changes on every single build -- so every rebuild
# re-prompts for permission and leaves a stale entry in System Settings that has
# to be removed by hand. A stable identity means you grant once.
set -euo pipefail

NAME="${1:-Ramble Dev}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "✓ signing identity \"$NAME\" already exists"
    exit 0
fi

cat <<INSTRUCTIONS
No signing identity named "$NAME" found.

Creating one requires Keychain Access, which has no scriptable equivalent:

  1. Open Keychain Access
  2. Menu: Keychain Access → Certificate Assistant → Create a Certificate…
  3. Name:              $NAME
     Identity Type:     Self Signed Root
     Certificate Type:  Code Signing
  4. Create, then Done
  5. Re-run this script to confirm

Then build with:  Scripts/bundle.sh

Without it, bundle.sh falls back to ad-hoc signing, which works but re-prompts
for Accessibility and Bluetooth after every rebuild.
INSTRUCTIONS
exit 1
