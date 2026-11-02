#!/bin/zsh
# In-app update gate. Signs a release build with a throwaway certificate (as CI does with the real
# one), installs it as version 8.0.0 under a test bundle ID in a scratch folder, and serves a local
# releases/latest feed for 9.0.0. Checks that an ad-hoc signed download and a wrong checksum are
# refused with the app left alone, then that a correctly signed 9.0.0 replaces the app and relaunches.
# The engine stays off (fresh bundle ID), so no audio or permission is involved.
set -u
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
ID=tech.tekkiech.jdsp4mac.updatetest
APP=$TMP/Applications/jdsp4mac.app
LOG=$HOME/Library/Logs/jdsp4mac/live.log
KC=$TMP/test.keychain-db
PASS=0; FAIL=0

cleanup() {
  pkill -f "$APP/Contents/MacOS/jdsp4mac" 2>/dev/null
  sleep 1
  security delete-keychain "$KC" 2>/dev/null
  defaults delete $ID >/dev/null 2>&1
  rm -f ~/Library/Preferences/$ID.plist
  rm -rf $TMP
}
trap cleanup EXIT
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }

# Throwaway certificate, then a release build signed with it.
cat > $TMP/cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = jdsp4mac
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout $TMP/key.pem -out $TMP/cert.pem -days 2 -config $TMP/cert.cnf 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -name jdsp4mac -out $TMP/id.p12 -passout pass:test
SIGNING_P12_BASE64=$(base64 -i $TMP/id.p12) SIGNING_P12_PASSWORD=test scripts/build-release.sh 9.0.0 >/dev/null 2>&1 || { echo "release build failed"; exit 1; }
security create-keychain -p test $KC && security unlock-keychain -p test $KC
security import $TMP/id.p12 -k $KC -P test -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k test $KC >/dev/null

# copy_as <dir> <version> <identity>: a copy of the build under the test bundle ID.
copy_as() {
  mkdir -p $1 && ditto build/dist/jdsp4mac.app $1/jdsp4mac.app
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleShortVersionString $2" $1/jdsp4mac.app/Contents/Info.plist
  if [[ $3 == - ]]; then codesign --force --sign - $1/jdsp4mac.app 2>/dev/null
  else codesign --force --keychain $KC --sign jdsp4mac $1/jdsp4mac.app 2>/dev/null; fi
}
# serve <dir>: zip it and write the feed pointing at it.
serve() {
  (cd $1 && ditto -c -k --keepParent jdsp4mac.app jdsp4mac-9.0.0-arm64.zip && shasum -a 256 jdsp4mac-9.0.0-arm64.zip > jdsp4mac-9.0.0-arm64.zip.sha256)
  cat > $TMP/feed.json <<EOF
{"tag_name": "v9.0.0", "html_url": "https://github.com/Tekkiech/jdsp4mac/releases", "draft": false, "prerelease": false,
 "assets": [{"name": "jdsp4mac-9.0.0-arm64.zip", "browser_download_url": "file://$1/jdsp4mac-9.0.0-arm64.zip"},
            {"name": "jdsp4mac-9.0.0-arm64.zip.sha256", "browser_download_url": "file://$1/jdsp4mac-9.0.0-arm64.zip.sha256"}]}
EOF
}
# attempt <log pattern>: launch the 8.0.0 copy against the feed, wait for the pattern.
attempt() {
  MARK="=== update test $$ $RANDOM"; echo "$MARK" >> $LOG
  open -n -g $APP --args --test-update-feed file://$TMP/feed.json --test-install-update
  wait_log "$1"
}
wait_log() {
  local t=0; while (( t < 300 )); do awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done
  return 1
}

defaults write $ID engineOn -bool false
copy_as $TMP/Applications 8.0.0 jdsp4mac

copy_as $TMP/adhoc 9.0.0 -; serve $TMP/adhoc
attempt 'install of 9.0.0 failed: .*not signed by the jdsp4mac release certificate'; result "ad-hoc signed download refused" $?
[[ $(version $APP) == 8.0.0 ]]; result "app left at 8.0.0" $?
pkill -f "$APP/Contents/MacOS/jdsp4mac"; sleep 1

copy_as $TMP/good 9.0.0 jdsp4mac; serve $TMP/good
echo "0000  jdsp4mac-9.0.0-arm64.zip" > $TMP/good/jdsp4mac-9.0.0-arm64.zip.sha256
attempt 'install of 9.0.0 failed: .*checksum'; result "wrong checksum refused" $?
[[ $(version $APP) == 8.0.0 ]]; result "app left at 8.0.0" $?
pkill -f "$APP/Contents/MacOS/jdsp4mac"; sleep 1

serve $TMP/good
attempt 'update: installed 9.0.0'; result "signed 9.0.0 installed" $?
[[ $(version $APP) == 9.0.0 ]]; result "app at $APP is now 9.0.0" $?
# The relaunched app checks GitHub for real: it reports itself as 9.0.0.
wait_log 'update check: .*this build 9\.0\.0'; result "relaunched as 9.0.0" $?
[[ -z $(xattr -r $APP 2>/dev/null | grep quarantine) ]]; result "no quarantine flag on the installed app" $?
codesign --verify --strict $APP 2>/dev/null; result "installed app's signature valid" $?

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
