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
PUBLISH=false
[[ "${2:-}" == "--publish" ]] && PUBLISH=true

REPO="samcolmanetti/ramble"
ZIP="build/Ramble-v${VERSION}.zip"

echo "▸ building release bundle"
./Scripts/bundle.sh --release >/dev/null

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
