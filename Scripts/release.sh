#!/bin/bash
# Cut a release: build, bundle, zip, checksum, and update the cask.
#
# Usage: Scripts/release.sh 0.1.0 [--publish]
#
# Without --publish it stops after producing the zip and the updated cask so
# you can inspect both. With --publish it creates the GitHub release and
# uploads the artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [--publish]}"
VERSION="${VERSION#v}"

# The version is written into the cask and used as the release tag, so a typo
# here becomes a bad tag and a cask pointing at a URL that does not exist.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "error: '$VERSION' is not a version like 0.1.0" >&2
    exit 2
fi

PUBLISH=false
case "${2:-}" in
    "")        ;;
    --publish) PUBLISH=true ;;
    # Silently ignoring this used to mean a mistyped --publish just did not
    # publish, with a success exit code and no hint why.
    *)         echo "error: unknown option '$2' (expected --publish)" >&2; exit 2 ;;
esac

REPO="samcolmanetti/ramble"
ZIP="build/Ramble-v${VERSION}.zip"

echo "▸ building release bundle"
# Without this the bundle reports `git describe` — a bare commit hash until the
# first tag exists — while the cask advertises the real version.
RAMBLE_VERSION="$VERSION" ./Scripts/bundle.sh --release >/dev/null

echo "▸ packaging $ZIP"
rm -f "$ZIP"
# ditto rather than zip: it preserves the bundle's resource forks and, more
# importantly, the code signature. A plain `zip` can invalidate it.
ditto -c -k --keepParent build/Ramble.app "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"
echo "  $ZIP  ($SIZE)"
echo "  sha256 $SHA"

echo "▸ updating Casks/ramble.rb"
sed -i '' -e "s|^  version \".*\"|  version \"${VERSION}\"|" \
          -e "s|^  sha256 \".*\"|  sha256 \"${SHA}\"|" Casks/ramble.rb

# Verify the substitution actually landed. It silently did not for the whole of
# this cask's life: the file held `sha256 :no_check`, which the quoted pattern
# above can never match, so every release would have shipped unverified while
# this script printed a checksum as if it had written one.
if ! grep -q "^  sha256 \"${SHA}\"$" Casks/ramble.rb; then
    echo "error: failed to write the checksum into Casks/ramble.rb" >&2
    echo "       the cask still reads: $(grep '^  sha256' Casks/ramble.rb)" >&2
    exit 1
fi
if ! grep -q "^  version \"${VERSION}\"$" Casks/ramble.rb; then
    echo "error: failed to write the version into Casks/ramble.rb" >&2
    exit 1
fi

if [[ "$PUBLISH" == true ]]; then
    echo "▸ publishing v${VERSION} to $REPO"
    gh release create "v${VERSION}" "$ZIP" \
        --repo "$REPO" \
        --title "v${VERSION}" \
        --generate-notes
    echo "✓ released"
else
    echo
    echo "Not published (pass --publish to do that)."
fi

cat <<NEXT

Next:
  1. git commit Casks/ramble.rb
  2. copy it into your tap:
       cp Casks/ramble.rb ../homebrew-tap/Casks/ramble.rb
     then commit and push that repo
  3. test the install:
       brew install --cask samcolmanetti/tap/ramble
NEXT
