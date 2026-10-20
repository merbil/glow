#!/bin/zsh
# End-to-end test of the one-click update, without touching any installed Glow.
#   scripts/test-self-update.sh
# Builds the debug app twice as test copies (9.0.0 and 9.0.1) with their own bundle ID
# (com.merterbil.glow.updatetest), signs them with "Glow Local Signing", then runs the debug-only
# `--install-update` pipeline of a 9.0.0 copy against local DMGs, in a temp folder.
# Each case prints PASS or FAIL. Everything is cleaned up at the end.
set -uo pipefail

cd "$(dirname "$0")/.."
ID="com.merterbil.glow.updatetest"
IDENTITY="Glow Local Signing"
T="$(mktemp -d /tmp/glow-update-e2e.XXXXXX)"
pass=0; fail=0

cleanup() { chmod -R u+w "$T" 2>/dev/null; rm -rf "$T" }
trap cleanup EXIT

if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "Needs the \"$IDENTITY\" signing identity."; exit 2
fi
swift build >/dev/null 2>&1 || { echo "swift build failed"; exit 2 }
BIN="$(swift build --show-bin-path 2>/dev/null)/Glow"

# make_app <dest.app> <version> [bundle id in Info.plist]: a test copy, signed with the identity.
make_app() {
  local app="$1" version="$2" plistid="${3:-$ID}"
  mkdir -p "$app/Contents/MacOS"
  cp "$BIN" "$app/Contents/MacOS/Glow"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $plistid" -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$app/Contents/Info.plist"
  codesign --force --options runtime --sign "$IDENTITY" --identifier "$ID" "$app" 2>/dev/null
}

# make_dmg <dmg> <folder holding Glow.app>
make_dmg() { hdiutil create -quiet -volname GlowTest -srcfolder "$2" -ov -format UDZO "$1" }

version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null }

# install_case <name> <folder> <dmg> <version to announce> → sets $code and $out
install_case() {
  out="$(perl -e 'alarm 120; exec @ARGV' "$2/Glow.app/Contents/MacOS/Glow" --install-update "$3" "$4" 2>&1)"
  code=$?
}

report() { # <name> <ok 0/1>
  if [[ "$2" == 0 ]]; then echo "PASS  $1  [${out##*$'\n'}]"; pass=$((pass + 1)); else echo "FAIL  $1  (exit $code: $out)"; fail=$((fail + 1)); fi
}

# New folder with an installed 9.0.0.
fresh() { rm -rf "$T/$1"; mkdir -p "$T/$1"; cp -R "$T/v900.app" "$T/$1/Glow.app" }

mkdir -p "$T/src900" "$T/src901" "$T/src902" "$T/srcadhoc" "$T/srcid" "$T/srclink"
make_app "$T/v900.app" 9.0.0
make_app "$T/src900/Glow.app" 9.0.0
make_app "$T/src901/Glow.app" 9.0.1
make_app "$T/src902/Glow.app" 9.0.2
make_app "$T/srcid/Glow.app" 9.0.1 "com.merterbil.glow.other"
cp -R "$T/src901/Glow.app" "$T/srcadhoc/Glow.app"
codesign --force --options runtime --sign - "$T/srcadhoc/Glow.app" 2>/dev/null
mkdir -p "$T/real"; cp -R "$T/src901/Glow.app" "$T/real/Glow.app"; ln -s "$T/real/Glow.app" "$T/srclink/Glow.app"
for n in 900 901 902 adhoc id link; do make_dmg "$T/$n.dmg" "$T/src$n"; done

# 1. The good update: replaced, relaunched as 9.0.1 (--print-version), signature of the result intact.
fresh good; install_case good "$T/good" "$T/901.dmg" 9.0.1
ok=1
if [[ $code == 0 && "$(version_of "$T/good/Glow.app")" == 9.0.1 ]]; then
  for _ in {1..75}; do [[ -s "$T/good/printed-version.txt" ]] && break; sleep 0.2; done
  [[ "$(cat "$T/good/printed-version.txt" 2>/dev/null)" == 9.0.1 ]] && codesign --verify --strict "$T/good/Glow.app" 2>/dev/null && ok=0
fi
report "update installs 9.0.1 and relaunches it" $ok

# Refusals: exit 1, the folder still holds 9.0.0 and nothing is left behind.
refused() { # <name> <dmg> <announced version>
  fresh "$1"; install_case "$1" "$T/$1" "$2" "$3"
  local left; left=$(ls -A "$T/$1" | grep -c '^\.Glow-update-')
  [[ $code == 1 && "$(version_of "$T/$1/Glow.app")" == 9.0.0 && $left == 0 ]]; report "$1" $?
}
refused "refuses an ad-hoc signed 9.0.1" "$T/adhoc.dmg" 9.0.1
refused "refuses another bundle ID" "$T/id.dmg" 9.0.1
refused "refuses a version that isn't the announced one" "$T/902.dmg" 9.0.1
refused "refuses the same version" "$T/900.dmg" 9.0.0
refused "refuses a Glow.app that is a symlink" "$T/link.dmg" 9.0.1

# Read-only folder: falls back (exit 3), nothing changes.
fresh ro; chmod 555 "$T/ro"; install_case ro "$T/ro" "$T/901.dmg" 9.0.1
[[ $code == 3 && "$(version_of "$T/ro/Glow.app")" == 9.0.0 ]]; report "read-only folder falls back" $?
chmod 755 "$T/ro"

echo "Total: $pass passed, $fail failed"
[[ $fail == 0 ]]
