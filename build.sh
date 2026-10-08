#!/bin/sh
# Builds Picture-Line.app next to this script and opens it.  ./build.sh test  runs the self-test first.
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 *.swift -o PictureLine
if [ "$1" = "test" ]; then ./PictureLine --selftest; fi
pkill -x PictureLine 2>/dev/null || true
pkill -x Memories 2>/dev/null || true
rm -rf Memories.app Picture-Line.app
mkdir -p Picture-Line.app/Contents/MacOS Picture-Line.app/Contents/Resources
mv PictureLine Picture-Line.app/Contents/MacOS/
cp Info.plist Picture-Line.app/Contents/
cp AppIcon.icns Picture-Line.app/Contents/Resources/
cp -R Fonts Samples Picture-Line.app/Contents/Resources/
codesign --force -s - Picture-Line.app
open Picture-Line.app
