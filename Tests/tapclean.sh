#!/bin/zsh
# Tap input gate: a steady 440 Hz tone in plain passthrough for 45 s must reach the output with no
# sample-to-sample jump beyond 1.5x the tone's own slope. Guards against bad samples in the raw tap
# stream, which the DSP path can hide (docs/findings.md). Run it on the output you care about.
# Needs: Debug build, capture permission granted, no other audio playing. Backs up and restores
# audio.conf, rules.json and excluded-apps.txt.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/build/DerivedData/Build/Products/Debug
APP=$BIN/jdsp4mac.app
SUPPORT="$HOME/Library/Application Support/jdsp4mac"
CONF="$SUPPORT/audio.conf"; RULES="$SUPPORT/rules.json"; EXCL="$SUPPORT/excluded-apps.txt"
LOG=$HOME/Library/Logs/jdsp4mac/live.log
TMP=$(mktemp -d)
MYPID=""; AFPLAY=""
for f in "$CONF" "$RULES" "$EXCL"; do [[ -f $f ]] && mv "$f" "$TMP/$(basename "$f").backup"; done
cleanup() {
  [[ -n $MYPID ]] && kill -TERM $MYPID 2>/dev/null
  kill $AFPLAY 2>/dev/null
  sleep 1
  for f in "$CONF" "$RULES" "$EXCL"; do rm -f "$f"; [[ -f "$TMP/$(basename "$f").backup" ]] && mv "$TMP/$(basename "$f").backup" "$f"; done
  rm -rf ${TMP:?}
}
trap cleanup EXIT

$BIN/haltest tone $TMP/tone.wav 440 120 0.1 >/dev/null
$BIN/jdspconf defaults "$CONF"
afplay $TMP/tone.wav & AFPLAY=$!
sleep 1
open -n -g "$APP" --args --autostart passthrough --stats-every 1 --auto-headroom off --balance 0
sleep 5; MYPID=$(pgrep -nx jdsp4mac)
MARK="=== tapclean $$-$(date +%s)"; echo "$MARK" >> $LOG
sleep 45
awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG | grep ' stats ' | awk '{
    for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] }
    limit = 2 * 3.14159265 * 440 / v["fs"] * 0.1 * 1.5
    s = v["maxStep"] + 0; n++; if (s > worst) worst = s; if (s > limit) { bad++; print "      jump " s " at " $1 } }
  END { printf "%s  %d s at %s Hz: worst step %.4f, limit %.4f, %d seconds with a jump\n", bad ? "FAIL" : "PASS", n, v["fs"], worst, limit, bad
        exit bad > 0 || n < 30 }'
