#!/bin/sh
# Screenshots for the README and posts: builds the Debug app, renders its panel and settings tabs
# while processing for real (demo settings in memory only: audio.conf, presets, rules, the
# exclusion list and preferences are not changed), then frames them.
#   scripts/screenshots.sh [out dir]      default: build/screenshots
# Needs the audio-recording permission for "jdsp4mac dev" and no other jdsp4mac running. Audio
# playing during the ~15 s capture gets the demo effects.
set -eu
cd "$(dirname "$0")/.."
OUT=${1:-build/screenshots}
if pgrep -x jdsp4mac >/dev/null; then echo "quit jdsp4mac first" >&2; exit 1; fi

xcodegen -q
xcodebuild -scheme jdsp4mac -configuration Debug -derivedDataPath build/DerivedData build -quiet
RAW=$(mktemp -d)
build/DerivedData/Build/Products/Debug/jdsp4mac.app/Contents/MacOS/jdsp4mac --screenshots "$RAW" >/dev/null 2>&1
swift Tools/frame-screenshots.swift "$RAW" "$OUT"
rm -rf "$RAW"
