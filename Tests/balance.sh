#!/bin/zsh
# Balance gate: a 440 Hz tone at 0.1 with the balance stepping through centre, +50, -50 and back
# (test hook). Each channel's measured output must follow, the other must stay untouched, no step
# may rebuild the DSP (that is what lets a slider apply as it moves) or click, and the effects
# switch must take balance off with everything else.
# Needs: Debug build, capture permission granted, no other audio playing. Backs up and restores
# audio.conf, rules.json and excluded-apps.txt.
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
MYPID=""; AFPLAY=""
SAVED=$(defaults read tech.tekkiech.jdsp4mac.dev balance 2>/dev/null)

for f in "$CONF" "$RULES" "$EXCL"; do [[ -f $f ]] && mv "$f" "$TMP/$(basename "$f").backup"; done
cleanup() {
  [[ -n $MYPID ]] && kill -TERM $MYPID 2>/dev/null
  kill $AFPLAY 2>/dev/null
  sleep 1
  for f in "$CONF" "$RULES" "$EXCL"; do rm -f "$f"; [[ -f "$TMP/$(basename "$f").backup" ]] && mv "$TMP/$(basename "$f").backup" "$f"; done
  rm -rf $TMP
}
trap cleanup EXIT

mark() { N=$((N+1)); MARK="=== balance $RUN #$N: $1"; echo "$MARK" >> $LOG; }
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG; }
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); since | grep -v ' stats ' | tail -4 | cut -c1-200 | sed 's/^/      /'; fi; }
wait_log() { local t=0; while (( t < $2 * 10 )); do since | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done; return 1; }
# Median of a stat over this step's lines, skipping the first two (the swap's crossfade).
stat() { since | grep ' stats ' | tail -n +3 | grep -o " $1=[0-9.]*" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : 0)}'; }
in_range() { awk -v v=$1 -v lo=$2 -v hi=$3 'BEGIN { exit !(v >= lo && v <= hi) }'; }
check() {  # <label> <L lo> <L hi> <R lo> <R hi>
  local l=$(stat outL) r=$(stat outR)
  in_range $l $2 $3 && in_range $r $4 $5; result "$1 (L $l, R $r)" $?
}

$BIN/haltest tone $TMP/tone.wav 440 300 0.1 >/dev/null
$BIN/jdspconf defaults "$CONF"
mark "running"
open -n -g "$APP" --args --autostart dsp --stats-every 1 --auto-headroom off --balance 0 --test-balance-cycle 14
wait_log 'state: running' 10 || true
MYPID=$(pgrep -nx jdsp4mac)
afplay $TMP/tone.wav & AFPLAY=$!
sleep 2

mark "centre"; sleep 5
check "centre: both channels at 0.1" 0.095 0.105 0.095 0.105

mark "+50"
wait_log 'TEST MODE: balance 50' 20; result "balance set to +50" $?
mark "+50 measured"; sleep 5
check "+50: left halved, right untouched" 0.045 0.055 0.095 0.105

mark "-50"
wait_log 'TEST MODE: balance -50' 20; result "balance set to -50" $?
mark "-50 measured"; sleep 5
check "-50: left untouched, right halved" 0.095 0.105 0.045 0.055

! awk -v r="=== balance $RUN #2: centre" 'f && /: effects off$/ { exit } f; $0 == r { f = 1 }' $LOG | grep -q 'settings v[0-9]* applied'
result "no DSP rebuild for any balance change" $?

mark "effects off"; $BIN/jdspconf set "$CONF" master_enable=false; sleep 5
check "effects off: balance off too" 0.095 0.105 0.095 0.105
$BIN/jdspconf set "$CONF" master_enable=true

mark "centre again"
wait_log 'TEST MODE: balance 0' 20; result "balance back to centre" $?
mark "centre measured"; sleep 5
check "centre: both channels back at 0.1" 0.095 0.105 0.095 0.105

mark "health"
# The effects-off stretch is left out: it outputs the raw tap input, which at 384 kHz has isolated
# bad samples every 10 s or so even in plain passthrough. Every balance move is still covered.
ALL=$(awk -v r="=== balance $RUN #2: centre" 'f && /^=== /{ off = /: effects off$/ } f && !off; $0 == r { f = 1 }' $LOG | grep ' stats ')
echo "$ALL" | awk '{ for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] }
    p=v["outPeak"]+0; s=v["maxStep"]+0; if (p > 0.01 && s / p > 0.0806) { bad=1; print "      click: maxStep " s " at peak " p } }
  END { printf "      disc %s/%s, overloads %s, max IOProc %s\n", v["outDisc"], v["inDisc"], v["overloads"], v["maxCb"]
        exit bad || (v["outDisc"]+0 > 0) || (v["inDisc"]+0 > 0) || (v["overloads"]+0 > 0) }'
result "no clicks, discontinuities or overloads" $?

[[ $(defaults read tech.tekkiech.jdsp4mac.dev balance 2>/dev/null) == "$SAVED" ]]; result "the test left the saved balance alone" $?

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
