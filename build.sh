#!/bin/bash
# Picture-Line build.  ./build.sh          dev build, opens the app
#                      ./build.sh test     dev build + self-test
#                      ./build.sh release  signed, notarized DMG in dist/
set -euo pipefail
cd "$(dirname "$0")"
APP="Picture-Line"; EXE="PictureLine"
IDENTITY="Developer ID Application: Kshitij Koranne (AA2WGR36B2)"
KEY_ID="YP8ZJPN5HQ"; KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
ISSUER=$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null || true)   # saved once, never in the repo
MODE="${1:-dev}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="dist/$APP-$VERSION.dmg"; A="build/$APP.app"

FLAGS=(-swift-version 5 -target arm64-apple-macos14.0 -O)
if [ "$MODE" = release ]; then
  [ -n "$ISSUER" ] || { echo "Save your App Store Connect Issuer ID in ~/.appstoreconnect/issuer_id first"; exit 1; }
else FLAGS+=(-D DEBUG); fi

rm -rf build && mkdir -p build
swiftc "${FLAGS[@]}" *.swift -o "build/$EXE"
[ "$MODE" = test ] && "build/$EXE" --selftest

mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "build/$EXE" "$A/Contents/MacOS/"
cp Info.plist "$A/Contents/"
cp AppIcon.icns PrivacyInfo.xcprivacy "$A/Contents/Resources/"
cp -R Fonts Samples Deco "$A/Contents/Resources/"
cp Design/backdrop.jpg "$A/Contents/Resources/Backdrop.jpg"
xattr -cr "$A"

cat > build/app.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.personal-information.photos-library</key><true/>
<key>com.apple.security.personal-information.location</key><true/>
</dict></plist>
PLIST

if [ "$MODE" != release ]; then
  codesign --force -s - --entitlements build/app.entitlements "$A"
  pkill -x "$EXE" 2>/dev/null || true; sleep 0.5; open "$A"; exit 0
fi

notarize() {
  local f="$1"
  if [[ "$f" != *.dmg ]]; then ditto -c -k --keepParent "$f" build/upload.zip; f=build/upload.zip; fi
  out=$(xcrun notarytool submit "$f" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait 2>&1) || true
  echo "$out"
  echo "$out" | grep -q "status: Accepted" || {
    id=$(echo "$out" | awk '/ id:/{print $2; exit}')
    xcrun notarytool log "$id" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER"; exit 1; }
}

codesign --force --options runtime --timestamp --entitlements build/app.entitlements --sign "$IDENTITY" "$A"
codesign --verify --strict --verbose=2 "$A"
notarize "$A"; xcrun stapler staple "$A"

mkdir -p build/dmg dist
ditto "$A" "build/dmg/$APP.app"; ln -s /Applications build/dmg/Applications
rm -f "$DMG"
hdiutil create -volname "$APP" -srcfolder build/dmg -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"; xcrun stapler staple "$DMG"

xcrun stapler validate "$A"; xcrun stapler validate "$DMG"
spctl -a -vv -t exec "$A"
spctl -a -vv -t open --context context:primary-signature "$DMG"
shasum -a 256 "$DMG"
echo "Ready: $DMG"
