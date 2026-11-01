#!/bin/zsh
# Automatic headroom gate: with --auto-headroom on, a +6 dB EQ node is offset by 6 dB of lower post
# gain, so a 440 Hz tone at 0.1 leaves at about 0.1 instead of 0.2 and stays out of the limiter.
# Checks the level, the logged headroom, that a cut-only curve needs none, and the usual health.
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

for f in "$CONF" "$RULES" "$EXCL"; do [[ -f $f ]] && mv "$f" "$TMP/$(basename "$f").backup"; done
cleanup() {
  [[ -n $MYPID ]] && kill -TERM $MYPID 2>/dev/null
  kill $AFPLAY 2>/dev/null
  sleep 1
  for f in "$CONF" "$RULES" "$EXCL"; do rm -f "$f"; [[ -f "$TMP/$(basename "$f").backup" ]] && mv "$TMP/$(basename "$f").backup" "$f"; done
  rm -rf $TMP
}
trap cleanup EXIT

mark() { N=$((N+1)); MARK="=== headroom $RUN #$N: $1"; echo "$MARK" >> $LOG; }
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG; }
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); since | grep -v ' stats ' | tail -4 | cut -c1-200 | sed 's/^/      /'; fi; }
wait_log() { local t=0; while (( t < $2 * 10 )); do since | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done; return 1; }
peak_after() { since | grep ' stats ' | tail -n +$(( ${1:-2} + 1 )) | grep -o 'outPeak=[0-9.]*' | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : 0)}'; }
in_range() { awk -v v=$1 -v lo=$2 -v hi=$3 'BEGIN { exit !(v >= lo && v <= hi) }'; }
set_conf() { $BIN/jdspconf set "$CONF" "$@"; }
EQ_FREQS="25.0;40.0;63.0;100.0;160.0;250.0;400.0;630.0;1000.0;1600.0;2500.0;4000.0;6300.0;10000.0;16000.0"

$BIN/haltest tone $TMP/tone.wav 440 300 0.1 >/dev/null
$BIN/jdspconf defaults "$CONF"
open -n -g "$APP" --args --autostart dsp --stats-every 1 --auto-headroom on
sleep 2; MYPID=$(pgrep -nx jdsp4mac)
mark "running"; wait_log 'state: running' 10 || true
afplay $TMP/tone.wav & AFPLAY=$!
sleep 3

mark "baseline"; sleep 3
P=$(peak_after 1); in_range $P 0.095 0.105; result "effects off: output = input (peak $P)" $?

mark "EQ +6 dB at 400 Hz"; set_conf tone_enable=true "tone_eq=$EQ_FREQS;0;0;0;0;0;0;6;0;0;0;0;0;0;0;0"
wait_log 'applied: .*headroom -6.0 dB' 3; result "headroom of 6.0 dB applied with the +6 dB node" $?
sleep 3; P=$(peak_after 2); in_range $P 0.085 0.115; result "440 Hz tone back near 0.1 instead of 0.2 (peak $P)" $?

mark "cut-only EQ"; set_conf "tone_eq=$EQ_FREQS;0;0;0;0;0;0;-6;0;0;0;0;0;0;0;0"
wait_log 'settings v[0-9]+ applied' 3
! since | grep -q 'headroom -'; result "a cut-only curve gets no headroom" $?
sleep 3; P=$(peak_after 2); in_range $P 0.04 0.06; result "-6 dB node: tone at about 0.05 (peak $P)" $?

mark "health"
ALL=$(awk -v r="=== headroom $RUN #1: running" 'f; $0 == r { f = 1 }' $LOG | grep ' stats ')
echo "$ALL" | awk '{ for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] } } END {
  printf "      disc %s/%s, overloads %s, max IOProc %s\n", v["outDisc"], v["inDisc"], v["overloads"], v["maxCb"]
  exit (v["outDisc"]+0 > 0) || (v["inDisc"]+0 > 0) || (v["overloads"]+0 > 0) }'
result "no discontinuities or overloads" $?

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
