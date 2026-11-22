#!/bin/bash
# Builds the self-contained app and packs it into a disk image for a GitHub release:
#   dist/TetherStudio-<version>.dmg   (the app and a link to /Applications)
#
#   VERSION=1.0.0 scripts/make_dmg.sh
#   VERSION=1.0.0 SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=tether scripts/make_dmg.sh
#       also signs the disk image and has Apple notarize it (NOTARY_PROFILE made once with
#       `xcrun notarytool store-credentials tether`), so it opens without a Gatekeeper warning.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
export VERSION
scripts/make_app.sh

APP="build/Tether Studio.app"
DMG="dist/TetherStudio-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp ../LICENSE "$STAGE/LICENSE.txt"
cp ../THIRD_PARTY_NOTICES.md "$STAGE/Third-party notices.md"
rm -f "$DMG"
hdiutil create -quiet -volname "Tether Studio $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

if [[ -n "${SIGN_ID:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

# The exact sources of the bundled LGPL libraries, to attach to the release (LGPL-2.1 section 6).
SRC="dist/third-party-sources-$VERSION.tar"
if [[ ! -f "$SRC" ]]; then
    files=(); missing=""
    # scripts/build_deps.sh builds from the archives in dist/sources/, so these are exactly the
    # sources of the libraries in the app.
    for f in libgphoto2 libtool libusb; do
        p="$(ls dist/sources/"$f"-[0-9]*.tar.* 2>/dev/null | head -1 || true)"
        if [[ -f "$p" ]]; then files+=("$p"); else
            echo "warning: no source archive of $f in dist/sources/ (run scripts/build_deps.sh)" >&2; missing=1; fi
    done
    [[ -n "${missing:-}" ]] && rm -f "$SRC" && files=()
    if ((${#files[@]})); then
        PACK="$(mktemp -d)/third-party-sources-$VERSION"
        mkdir -p "$PACK"
        for p in "${files[@]}"; do n="$(basename "$p")"; cp "$p" "$PACK/${n#*--}"; done     # drop Homebrew's hash prefix
        tar -cf "$SRC" -C "$(dirname "$PACK")" "$(basename "$PACK")"
        rm -rf "$(dirname "$PACK")"
        echo "==> $SRC (${#files[@]} source archives)"
    fi
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" $([[ -f "$(basename "$SRC")" ]] && basename "$SRC") > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "==> Done: $PWD/$DMG"
