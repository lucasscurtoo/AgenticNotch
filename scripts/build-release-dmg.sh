#!/usr/bin/env bash
# Builds AgenticNotch (Release), signs it, and packages a DMG in dist/.
#
# Why the re-sign: the project signs ad-hoc ("-") and turns on hardened runtime.
# The bundled MediaRemoteAdapter.framework then has a different Team ID than the
# app, and dyld kills the app at launch. Signing every nested bundle with one
# real certificate fixes it. Any free "Apple Development" cert works — the DMG
# still isn't notarized, so users need to clear the quarantine flag once.
#
# Usage: ./scripts/build-release-dmg.sh [signing-identity-hash]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IDENTITY="${1:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Develop(ment|er ID Application)/ {print $2; exit}')"
fi
[ -n "$IDENTITY" ] || { echo "No codesigning identity found. Create a free one in Xcode > Settings > Accounts." >&2; exit 1; }

DD="${DERIVED_DATA:-build/dd}"
APP="$DD/Build/Products/Release/AgenticNotch.app"
VERSION="$(awk -F' = ' '/MARKETING_VERSION/ {gsub(/;/,"",$2); print $2; exit}' boringNotch.xcodeproj/project.pbxproj)"
# Unversioned name on purpose: the README's download button points at
# releases/latest/download/AgenticNotch.dmg, which only resolves if every release
# ships an asset with this exact name.
DMG="dist/AgenticNotch.dmg"

echo "==> Building (identity $IDENTITY, version $VERSION)"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$DD" build | tail -3

echo "==> Signing"
ENT="$(mktemp -t agenticnotch-ent).plist"
codesign -d --entitlements "$ENT" --xml "$APP"
for nested in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/XPCServices/*.xpc; do
  [ -e "$nested" ] || continue
  codesign --force --sign "$IDENTITY" -o runtime --timestamp=none "$nested" >/dev/null 2>&1
done
codesign --force --sign "$IDENTITY" -o runtime --timestamp=none --entitlements "$ENT" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"

echo "==> Packaging $DMG"
# ponytail: plain hdiutil, no custom background/icon layout. Configuration/dmg/create_dmg.sh
# does the pretty version but needs dmgbuild from pip.
mkdir -p dist
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "AgenticNotch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE" "$ENT"

echo "==> Done: $DMG"
echo "    Install: open the DMG, drag to /Applications, then"
echo "    xattr -dr com.apple.quarantine /Applications/AgenticNotch.app"
echo "    Publish:  gh release create v$VERSION -R lucasscurtoo/AgenticNotch $DMG"
