#!/bin/zsh
# Per-app exclusion gate (stretch). Two throwaway player apps with their own bundle IDs play tones
# (A at 0.1, B at 0.02). The tap's input peak shows who is in the tap: both ~0.12, B only ~0.02.
# Checks: exclusion applies live (no rebuild), follows A quitting and relaunching, and is undone
# live; then the same for an app whose audio comes from its WebKit GPU process (like Safari's);
# no discontinuities or overloads. Whether excluded apps are still heard is the human check.
# Other audio must be paused (it adds to the tap's input).
# Needs: Debug build, capture permission granted. Backs up and restores audio.conf, rules.json and
# excluded-apps.txt.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/build/DerivedData/Build/Products/Debug
APP=$BIN/jdsp4mac.app
SUPPORT="$HOME/Library/Application Support/jdsp4mac"
CONF="$SUPPORT/audio.conf"
RULES="$SUPPORT/rules.json"
EXCL="$SUPPORT/excluded-apps.txt"
LOG=$HOME/Library/Logs/jdsp4mac/live.log
TMP=$(mktemp -d)
PASS=0; FAIL=0
RUN="$$-$(date +%s)"
N=0
MYPID=""; PA=""; PB=""

for f in "$CONF" "$RULES" "$EXCL"; do [[ -f $f ]] && mv "$f" "$TMP/$(basename "$f").backup"; done
cleanup() {
  [[ -n $MYPID ]] && kill -TERM $MYPID 2>/dev/null
  kill $PA $PB $PW 2>/dev/null
  sleep 1
  for f in "$CONF" "$RULES" "$EXCL"; do rm -f "$f"; [[ -f "$TMP/$(basename "$f").backup" ]] && mv "$TMP/$(basename "$f").backup" "$f"; done
  rm -rf $TMP
}
trap cleanup EXIT

mark() { N=$((N+1)); MARK="=== exclusion $RUN #$N: $1"; echo "$MARK" >> $LOG; }
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG; }
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); since | grep -v ' stats ' | tail -4 | cut -c1-200 | sed 's/^/      /'; fi; }
wait_log() { local t=0; while (( t < $2 * 10 )); do since | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done; return 1; }
# Median tap input peak over the stats lines after the marker, skipping the first `skip`.
in_peak() { since | grep ' stats ' | tail -n +$(( ${1:-1} + 1 )) | grep -o 'inPeak=[0-9.]*' | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : 0)}'; }
in_range() { awk -v v=$1 -v lo=$2 -v hi=$3 'BEGIN { exit !(v >= lo && v <= hi) }'; }

# Two player apps: a copy of afplay in a bundle with its own bundle ID, ad-hoc signed.
for X in a b; do
  A=$TMP/jdsptest-player-$X.app; mkdir -p $A/Contents/MacOS; cp /usr/bin/afplay $A/Contents/MacOS/player
  cat > $A/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>tech.tekkiech.jdsptest.player-$X</string>
<key>CFBundleExecutable</key><string>player</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
EOF
  codesign --force -s - -i tech.tekkiech.jdsptest.player-$X $A 2>/dev/null
done
# WebKit app: Tests/fixtures/WebPlayer.swift in a bundle of its own.
W=$TMP/jdsptest-webplayer.app; mkdir -p $W/Contents/MacOS
swiftc -O -o $W/Contents/MacOS/webplayer Tests/fixtures/WebPlayer.swift 2>/dev/null
cat > $W/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>tech.tekkiech.jdsptest.webplayer</string>
<key>CFBundleExecutable</key><string>webplayer</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force -s - -i tech.tekkiech.jdsptest.webplayer $W 2>/dev/null
PW=""
$BIN/haltest tone $TMP/a.wav 440 120 0.1 >/dev/null
$BIN/haltest tone $TMP/b.wav 660 120 0.02 >/dev/null
play_a() { $TMP/jdsptest-player-a.app/Contents/MacOS/player $TMP/a.wav & PA=$!; }

$BIN/jdspconf defaults "$CONF"   # all effects off: output = input
open -n -g "$APP" --args --autostart dsp --stats-every 1
sleep 2; MYPID=$(pgrep -nx jdsp4mac)
mark "running"; wait_log 'state: running' 10 || true
play_a
$TMP/jdsptest-player-b.app/Contents/MacOS/player $TMP/b.wav & PB=$!
sleep 3

mark "both"; sleep 3
P=$(in_peak 1); in_range $P 0.10 0.13; result "both players in the tap (in peak $P)" $?

mark "exclude A"; echo "tech.tekkiech.jdsptest.player-a" > "$EXCL"
wait_log 'exclusions applied live' 3; result "excluding A applied live" $?
sleep 3; P=$(in_peak 2); in_range $P 0.015 0.025; result "A left the tap, B still in it (in peak $P)" $?
! since | grep -q 'rebuild #'; result "no rebuild for the exclusion" $?

mark "A quits and relaunches"; kill $PA; sleep 1; play_a
sleep 4; P=$(in_peak 2); in_range $P 0.015 0.025; result "relaunched A is still excluded (in peak $P)" $?

mark "include A again"; : > "$EXCL"
wait_log 'exclusions applied live in [0-9.]+ ms: none' 3; result "removing the exclusion applied live" $?
sleep 3; P=$(in_peak 2); in_range $P 0.10 0.13; result "A back in the tap (in peak $P)" $?

mark "WebKit app plays"; kill $PA; PA=""
# Through Launch Services, as real apps start: then the app is responsible for its WebKit GPU
# process. Started from this shell, whatever launched the shell would be responsible instead.
open -n -g $W --args $TMP/a.wav; sleep 1; PW=$(pgrep -n webplayer)
sleep 5; P=$(in_peak 2); in_range $P 0.10 0.13; result "WebKit app in the tap (in peak $P)" $?

mark "exclude the WebKit app"; echo "tech.tekkiech.jdsptest.webplayer" > "$EXCL"
wait_log 'exclusions applied live in [0-9.]+ ms: com.apple.WebKit.GPU for tech.tekkiech.jdsptest.webplayer' 3
result "its WebKit GPU process is excluded by the app's bundle ID" $?
sleep 3; P=$(in_peak 2); in_range $P 0.015 0.025; result "WebKit app left the tap, B still in it (in peak $P)" $?

mark "health"
ALL=$(awk -v r="=== exclusion $RUN #1: running" 'f; $0 == r { f = 1 }' $LOG | grep ' stats ')
echo "$ALL" | awk '{ for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] } } END {
  printf "      disc %s/%s, overloads %s, max IOProc %s\n", v["outDisc"], v["inDisc"], v["overloads"], v["maxCb"]
  exit (v["outDisc"]+0 > 0) || (v["inDisc"]+0 > 0) || (v["overloads"]+0 > 0) }'
result "no discontinuities or overloads through every change" $?

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
