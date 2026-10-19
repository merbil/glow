#!/bin/zsh
# Builds Glow.app (universal) and packs it into a drag-to-install DMG:
#   scripts/make-dmg.sh   →   build/Glow-<version>.dmg
# The app is signed with the local "Glow Local Signing" certificate, not an Apple Developer ID,
# so on other Macs the first launch needs System Settings → Privacy & Security → "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Glow-$VERSION.dmg"
STAGE=$(mktemp -d)

cp -R build/Glow.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/First launch – read me.txt" <<'TXT'
Installing Glow

1. Drag Glow onto the Applications folder.
2. Open Glow from Applications.
3. macOS says Glow "can't be opened" (it isn't from an identified developer). Click Done.
4. Open System Settings → Privacy & Security, scroll down, and click "Open Anyway" next to
   the message about Glow. Confirm with your password. You only do this once.
5. A bulb appears in your menu bar. Click it, allow "find devices on your local network",
   and press the round button on your Hue Bridge when Glow asks.

More: https://github.com/merbil/glow
TXT

rm -f "$DMG"
hdiutil create -volname "Glow $VERSION" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
