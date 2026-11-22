#!/bin/bash
# Builds the Mac App Store version: the same app, in the App Sandbox
# (Resources/appstore/TetherStudio.entitlements), packaged as an installer for App Store Connect.
#
#   scripts/make_appstore.sh
#       ad-hoc signed sandboxed app in build/, to try the sandbox on this Mac (not uploadable)
#   VERSION=1.0.0 BUILD=2 \
#   SIGN_ID="Apple Distribution: Name (TEAMID)" \
#   INSTALLER_ID="3rd Party Mac Developer Installer: Name (TEAMID)" \
#   PROFILE=~/Downloads/Tether_Studio_Mac_App_Store.provisionprofile \
#   scripts/make_appstore.sh
#       signed app and dist/TetherStudio-<version>-appstore.pkg, ready for Transporter or
#       `xcrun altool --upload-package` (see docs/APP_STORE.md)
set -euo pipefail
cd "$(dirname "$0")/.."

export VERSION="${VERSION:-1.0.0}" BUILD="${BUILD:-1}"
export ENTITLEMENTS="$PWD/Resources/appstore/TetherStudio.entitlements"
# No encryption beyond what macOS provides: no export compliance documents needed.
export EXTRA_PLIST="<key>ITSAppUsesNonExemptEncryption</key><false/>"
if [[ -n "${SIGN_ID:-}" && -z "${PROFILE:-}" ]]; then
    echo "error: an App Store build needs PROFILE (a Mac App Store provisioning profile for io.github.moheshmohan.tetherstudio)" >&2
    exit 1
fi
if [[ -n "${PROFILE:-}" ]]; then
    # The signature must carry the app and team identifiers the provisioning profile names.
    PROF_ENT="$(mktemp -d)/profile.plist"
    security cms -D -i "$PROFILE" | plutil -extract Entitlements xml1 -o "$PROF_ENT" -
    APP_ID="$(plutil -extract com\\.apple\\.application-identifier raw "$PROF_ENT" 2>/dev/null || plutil -extract application-identifier raw "$PROF_ENT")"
    TEAM_ID="$(plutil -extract com\\.apple\\.developer\\.team-identifier raw "$PROF_ENT")"
    MERGED="$(dirname "$PROF_ENT")/TetherStudio.entitlements"
    cp "$ENTITLEMENTS" "$MERGED"
    plutil -insert com\\.apple\\.application-identifier -string "$APP_ID" "$MERGED"
    plutil -insert com\\.apple\\.developer\\.team-identifier -string "$TEAM_ID" "$MERGED"
    export ENTITLEMENTS="$MERGED"
fi
scripts/make_app.sh

APP="build/Tether Studio.app"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    || { echo "error: the app is not sandboxed" >&2; exit 1; }

if [[ -n "${INSTALLER_ID:-}" ]]; then
    mkdir -p dist
    PKG="dist/TetherStudio-$VERSION-appstore.pkg"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
    echo "==> Done: $PWD/$PKG"
else
    echo "==> Sandboxed app (not packaged; set SIGN_ID, INSTALLER_ID and PROFILE for App Store Connect): $PWD/$APP"
fi
