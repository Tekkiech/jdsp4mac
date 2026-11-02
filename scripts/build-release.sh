#!/bin/sh
# Builds an arm64 Release of jdsp4mac with jdspctl inside the bundle, and zips it for a GitHub
# Release. No Developer ID, no notarisation.
#   scripts/build-release.sh [version]     version defaults to MARKETING_VERSION in project.yml
# Output: build/dist/jdsp4mac-<version>-arm64.zip (+ .sha256)
#
# Signing: with SIGNING_P12_BASE64 and SIGNING_P12_PASSWORD set (CI secrets, made by
# scripts/make-signing-cert.sh) the app is signed with the project's self-signed certificate, so
# every release has the same code identity: macOS keeps the audio recording permission across
# updates, and the in-app updater accepts only builds signed with it. Without them it is ad-hoc.
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)}
BUILD=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
DD=build/Release
OUT=build/dist
NAME=jdsp4mac-$VERSION-arm64

xcodegen -q
# Command-line settings override xcconfig/Signing.local.xcconfig; the bundle is signed below.
xcodebuild -scheme jdsp4mac -configuration Release -derivedDataPath "$DD" -destination 'platform=macOS,arch=arm64' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build -quiet

P=$DD/Build/Products/Release
rm -rf "$OUT" && mkdir -p "$OUT"
ditto "$P/jdsp4mac.app" "$OUT/jdsp4mac.app"
cp "$P/jdspctl" "$OUT/jdsp4mac.app/Contents/MacOS/jdspctl"
if [ -n "${SIGNING_P12_BASE64:-}" ]; then
    # A throwaway keychain, on the search list only while signing (codesign on the CI runners does
    # not find identities elsewhere). The certificate is not trusted on the build machine, which
    # codesign does not need.
    KC=$PWD/build/signing.keychain-db
    KCPW=$(openssl rand -hex 16)
    KEYCHAINS=$(security list-keychains -d user | xargs)
    rm -f "$KC"
    trap 'security list-keychains -d user -s $KEYCHAINS; security delete-keychain "$KC" 2>/dev/null; rm -f "$KC" build/signing.p12' EXIT
    echo "$SIGNING_P12_BASE64" | base64 --decode > build/signing.p12
    security create-keychain -p "$KCPW" "$KC"
    security unlock-keychain -p "$KCPW" "$KC"
    security import build/signing.p12 -k "$KC" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
    security list-keychains -d user -s "$KC" $KEYCHAINS
    IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/"jdsp4mac"/ { print $2; exit }')
    [ -n "$IDENTITY" ] || { echo "no jdsp4mac identity in SIGNING_P12_BASE64"; exit 1; }
    SIGN="--keychain $KC --sign $IDENTITY"
else
    echo "warning: SIGNING_P12_BASE64 not set, signing ad-hoc"
    SIGN="--sign -"
fi
# Sign the nested tool first, then the bundle that seals it.
codesign --force $SIGN "$OUT/jdsp4mac.app/Contents/MacOS/jdspctl"
codesign --force $SIGN "$OUT/jdsp4mac.app"
codesign --verify --strict --verbose=1 "$OUT/jdsp4mac.app"
codesign -d -r- "$OUT/jdsp4mac.app" 2>&1 | grep designated

(cd "$OUT" && ditto -c -k --keepParent jdsp4mac.app "$NAME.zip" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "built $OUT/$NAME.zip"
cat "$OUT/$NAME.zip.sha256"
