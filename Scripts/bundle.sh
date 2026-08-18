#!/bin/bash
# Assemble Ramble.app from the SPM build product.
#
# This machine has Command Line Tools but not Xcode, so there is no xcodebuild
# and no .xcodeproj. SPM produces the executable; everything a bundle needs --
# the directory layout, Info.plist, code signature -- is assembled here.
#
# Usage: Scripts/bundle.sh [--release] [--identity "Ramble Dev"]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
IDENTITY="${RAMBLE_SIGN_IDENTITY:-Ramble Dev}"
# release.sh sets this so a released bundle reports the version being
# released. Left unset, a dev build reports the commit it came from.
VERSION="${RAMBLE_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo 0.1.0)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIG=release; shift ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

APP="build/Ramble.app"
echo "▸ building ($CONFIG)"
swift build -c "$CONFIG" --product Ramble

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Ramble" "$APP/Contents/MacOS/Ramble"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# Ship the CLI tools inside the bundle. A Homebrew cask can expose them with
# `binary` stanzas pointing here, so one artifact covers both the menu bar app
# and the diagnostics -- and the diagnostics are what make a silent failure
# debuggable on someone else's machine.
for tool in ramble-sniff ramble-tap ramble-level ramble-check; do
    swift build -c "$CONFIG" --product "$tool" >/dev/null
    cp ".build/$CONFIG/$tool" "$APP/Contents/MacOS/$tool"
done

# Signing. A stable identity keeps TCC grants across rebuilds; ad-hoc does not.
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "▸ signing with \"$IDENTITY\""
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
    echo "▸ signing ad-hoc (no \"$IDENTITY\" identity — run Scripts/make-signing-cert.sh)"
    echo "  note: Accessibility and Bluetooth will re-prompt after every rebuild"
    codesign --force --deep --sign - "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo
echo "✓ $APP  ($VERSION build $BUILD)"
echo "  run:      open $APP"
echo "  install:  cp -R $APP /Applications/"
