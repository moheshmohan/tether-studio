#!/bin/bash
# Builds Tether Studio and wraps the release binary into a self-contained .app bundle:
# libgphoto2, its camera and connection plug-ins and every library they need (from Homebrew)
# are copied into Contents/Frameworks, so the app runs on a Mac without Homebrew.
#
#   scripts/make_app.sh                 ad-hoc signed (runs on this Mac; others must allow it once)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" scripts/make_app.sh
#                                       signed for distribution, with the hardened runtime
#   ENTITLEMENTS=file  PROFILE=file.provisionprofile  EXTRA_PLIST="<key>…"
#                                       used by make_appstore.sh (App Sandbox build)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
# libgphoto2 built for macOS 13+ by scripts/build_deps.sh; without it Homebrew's (which runs only on
# the macOS version Homebrew built it for).
if [[ -d .deps/prefix/include/gphoto2 ]]; then LIBS="$PWD/.deps/prefix"; else
    LIBS="$BREW"; echo "warning: using Homebrew's libgphoto2; run scripts/build_deps.sh for a release" >&2; fi
GP_CAMLIBS="$(ls -d "$LIBS"/lib/libgphoto2/*/ | tail -1)"
GP_IOLIBS="$(ls -d "$LIBS"/lib/libgphoto2_port/*/ | tail -1)"

echo "==> swift build (release)"
# Source paths are written into the binary (for error messages); map them to the package root so
# the build machine's folders do not travel with the app.
ROOT="$(cd .. && pwd)"
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." -Xcc -ffile-prefix-map="$ROOT=." \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=~"

APP="build/Tether Studio.app"
FW="$APP/Contents/Frameworks"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FW/libgphoto2/camlibs" "$FW/libgphoto2/iolibs"

cp .build/release/TetherStudio "$APP/Contents/MacOS/TetherStudio"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The same icon as an asset catalog (Assets.car), which App Store validation looks for.
if xcrun --find actool >/dev/null 2>&1; then
    AC="$(mktemp -d)"
    iconutil -c iconset Resources/AppIcon.icns -o "$AC/AppIcon.iconset"
    mkdir -p "$AC/Assets.xcassets/AppIcon.appiconset"
    echo '{"info":{"version":1,"author":"xcode"}}' > "$AC/Assets.xcassets/Contents.json"
    images=""
    for f in "$AC"/AppIcon.iconset/icon_*.png; do
        n="$(basename "$f" .png)"; size="${n#icon_}"; scale=1x
        [[ "$size" == *@2x ]] && { scale=2x; size="${size%@2x}"; }
        cp "$f" "$AC/Assets.xcassets/AppIcon.appiconset/"
        images+="{\"idiom\":\"mac\",\"size\":\"$size\",\"scale\":\"$scale\",\"filename\":\"$n.png\"},"
    done
    echo "{\"images\":[${images%,}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$AC/Assets.xcassets/AppIcon.appiconset/Contents.json"
    xcrun actool "$AC/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 13.0 --app-icon AppIcon --output-partial-info-plist "$AC/partial.plist" >/dev/null
    rm -rf "$AC"
fi
cp -R Resources/firmware "$APP/Contents/Resources/firmware"     # the board's bridge program
cp -R Resources/licenses "$APP/Contents/Resources/licenses"     # licences of the bundled libraries
cp ../THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/licenses/"

# The camera driver and the connection drivers the app uses (Wi-Fi PTP/IP, USB, card as disk).
cp "$GP_CAMLIBS/ptp2.so" "$FW/libgphoto2/camlibs/"
for io in ptpip usb1 disk; do cp "$GP_IOLIBS/$io.so" "$FW/libgphoto2/iolibs/"; done

# Copy every non-system library these load, then point them all at the copies.
is_brew() { [[ "$1" == "$LIBS"/* || "$1" == "$BREW"/* || "$1" == /usr/local/* ]]; }
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }
queue=("$APP/Contents/MacOS/TetherStudio" "$FW"/libgphoto2/camlibs/*.so "$FW"/libgphoto2/iolibs/*.so)
done_list=" "
while ((${#queue[@]})); do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    for dep in $(deps "$f"); do
        is_brew "$dep" || continue
        name="$(basename "$dep")"
        if [[ "$done_list" != *" $name "* ]]; then
            done_list+="$name "
            cp "$(realpath "$dep")" "$FW/$name"
            chmod u+w "$FW/$name"
            install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
            queue+=("$FW/$name")
        fi
    done
done
for f in "$APP/Contents/MacOS/TetherStudio" "$FW"/*.dylib "$FW"/libgphoto2/*/*.so; do
    chmod u+w "$f"
    for dep in $(deps "$f"); do
        is_brew "$dep" || continue
        install_name_tool -change "$dep" "@executable_path/../Frameworks/$(basename "$dep")" "$f" 2>/dev/null
    done
done
if otool -L "$APP/Contents/MacOS/TetherStudio" "$FW"/*.dylib "$FW"/libgphoto2/*/*.so | grep -E "$LIBS|$BREW|/usr/local/"; then
    echo "error: a library still points outside the app" >&2; exit 1
fi
echo "    bundled:$done_list"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Tether Studio</string>
    <key>CFBundleDisplayName</key>       <string>Tether Studio</string>
    <key>CFBundleIdentifier</key>        <string>io.github.moheshmohan.tetherstudio</string>
    <key>CFBundleVersion</key>           <string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>TetherStudio</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIconName</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.photography</string>
    <key>NSHumanReadableCopyright</key>  <string>MIT License. Not affiliated with or endorsed by Sony.</string>
    ${EXTRA_PLIST:-}
    <key>NSLocalNetworkUsageDescription</key>
    <string>Tether Studio looks for your camera on the Wi-Fi network and controls it there.</string>
</dict>
</plist>
PLIST

[[ -n "${PROFILE:-}" ]] && cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
ENT=()
[[ -n "${ENTITLEMENTS:-}" ]] && ENT=(--entitlements "$ENTITLEMENTS")
if [[ -n "${SIGN_ID:-}" ]]; then
    echo "==> signing with $SIGN_ID (hardened runtime)"
    for f in "$FW"/*.dylib "$FW"/libgphoto2/*/*.so; do
        codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$f"
    done
    codesign --force --timestamp --options runtime ${ENT[@]+"${ENT[@]}"} --sign "$SIGN_ID" "$APP"
else
    echo "==> ad-hoc code sign"
    for f in "$FW"/*.dylib "$FW"/libgphoto2/*/*.so; do codesign --force --sign - "$f"; done
    codesign --force ${ENT[@]+"${ENT[@]}"} --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> Done: $PWD/$APP"
