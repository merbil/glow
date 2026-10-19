#!/bin/zsh
# Builds Glow.app from the Swift package. Works with or without full Xcode.
#   scripts/build-app.sh            → build/Glow.app
#   scripts/build-app.sh --install  → also copies it to /Applications and opens it
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Glow.app"

# Universal binary (Apple Silicon + Intel): build each architecture, then merge with lipo.
# (Works with the Command Line Tools alone; `--arch arm64 --arch x86_64` would need Xcode.)
# Each architecture gets its own build folder (sharing one confuses SwiftPM's build database).
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/release-arm64
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/release-x86_64
ARM="$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/release-arm64 --show-bin-path)/Glow"
X86="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/release-x86_64 --show-bin-path)/Glow"
BIN="build/Glow-universal"
mkdir -p build
lipo -create "$ARM" "$X86" -output "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp RELEASE_NOTES.md "$APP/Contents/Resources/RELEASE_NOTES.md"   # shown in About Glow
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the local "Glow Local Signing" certificate when it exists. Its identity stays the same
# across builds, so macOS keeps Glow's Local Network and Keychain permissions after updates.
# Without it, fall back to an ad-hoc signature (works, but permissions reset on every rebuild).
IDENTITY="Glow Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --sign "$IDENTITY" --identifier com.merterbil.glow "$APP"
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --options runtime --sign - "$APP"
  echo "Signed ad-hoc (permissions will reset after each rebuild; see README)"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Glow 2>/dev/null || true
  sleep 1   # let the old copy quit before replacing it
  rm -rf /Applications/Glow.app
  cp -R "$APP" /Applications/
  open /Applications/Glow.app
  echo "Installed to /Applications and launched."
fi
