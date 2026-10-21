#!/bin/sh
# Builds an arm64 Release of jdsp4mac, ad-hoc signed (no Developer ID, no notarisation), with
# jdspctl inside the bundle, and zips it for a GitHub Release.
#   scripts/build-release.sh [version]     version defaults to MARKETING_VERSION in project.yml
# Output: build/dist/jdsp4mac-<version>-arm64.zip (+ .sha256)
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)}
BUILD=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
DD=build/Release
OUT=build/dist
NAME=jdsp4mac-$VERSION-arm64

xcodegen -q
# Command-line settings override xcconfig/Signing.local.xcconfig: releases are always ad-hoc.
xcodebuild -scheme jdsp4mac -configuration Release -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build -quiet

P=$DD/Build/Products/Release
rm -rf "$OUT" && mkdir -p "$OUT"
ditto "$P/jdsp4mac.app" "$OUT/jdsp4mac.app"
cp "$P/jdspctl" "$OUT/jdsp4mac.app/Contents/MacOS/jdspctl"
# Sign the nested tool first, then the bundle that seals it.
codesign --force --sign - "$OUT/jdsp4mac.app/Contents/MacOS/jdspctl"
codesign --force --sign - "$OUT/jdsp4mac.app"
codesign --verify --strict --verbose=1 "$OUT/jdsp4mac.app"

(cd "$OUT" && ditto -c -k --keepParent jdsp4mac.app "$NAME.zip" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "built $OUT/$NAME.zip"
cat "$OUT/$NAME.zip.sha256"
