#!/bin/zsh
# Phase 5 scripted gate: jdspctl drives the running app (settings, presets, rules, status) and works
# while it is not running. Plays a quiet 440 Hz tone; checks the engine's log and 1 s stats.
# Needs: Debug build, capture permission granted. Backs up and restores audio.conf and rules.json.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/build/DerivedData/Build/Products/Debug
APP=$BIN/jdsp4mac.app
CTL=$BIN/jdspctl
SUPPORT="$HOME/Library/Application Support/jdsp4mac"
CONF="$SUPPORT/audio.conf"
RULES="$SUPPORT/rules.json"
LOG=$HOME/Library/Logs/jdsp4mac/live.log
TMP=$(mktemp -d)
PASS=0; FAIL=0
RUN="$$-$(date +%s)"
N=0
MYPID=""
AFPLAY=""

cp "$CONF" $TMP/audio.conf.backup 2>/dev/null
[[ -f $RULES ]] && mv "$RULES" $TMP/rules.json.backup
cleanup() {
  [[ -n $MYPID ]] && kill -TERM $MYPID 2>/dev/null
  kill $AFPLAY 2>/dev/null
  sleep 1
  [[ -f $TMP/audio.conf.backup ]] && cp $TMP/audio.conf.backup "$CONF"
  rm -f "$RULES"; [[ -f $TMP/rules.json.backup ]] && mv $TMP/rules.json.backup "$RULES"
  rm -f "$SUPPORT/presets/jdsptest-cli.conf"
  rm -rf $TMP
}
trap cleanup EXIT

mark() { N=$((N+1)); MARK="=== phase5 $RUN #$N: $1"; echo "$MARK" >> $LOG; }
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG; }
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); since | grep -v ' stats ' | tail -4 | cut -c1-200 | sed 's/^/      /'; fi; }
wait_log() { local t=0; while (( t < $2 * 10 )); do since | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done; return 1; }
peak_after() { since | grep ' stats ' | tail -n +$(( ${1:-2} + 1 )) | grep -o 'outPeak=[0-9.]*' | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : 0)}'; }
in_range() { awk -v v=$1 -v lo=$2 -v hi=$3 'BEGIN { exit !(v >= lo && v <= hi) }'; }

$BIN/haltest tone $TMP/tone.wav 440 300 0.1
$BIN/jdspconf defaults "$CONF"

$CTL --is-connected; [[ $? == 1 ]]; result "--is-connected: exit 1 while the app is not running" $?

open -n -g "$APP" --args --autostart dsp --stats-every 1
sleep 2; MYPID=$(pgrep -nx jdsp4mac)
mark "running"; wait_log 'state: running' 10 || true
afplay $TMP/tone.wav &
AFPLAY=$!
sleep 2

$CTL --is-connected; result "--is-connected: exit 0 while running" $?
$CTL --status | grep -q '^State:   processing'; result "--status: processing ($($CTL --status | grep -m1 Output))" $?

mark "set"; $CTL --set tone_enable=true "tone_eq=25.0;40.0;63.0;100.0;160.0;250.0;400.0;630.0;1000.0;1600.0;2500.0;4000.0;6300.0;10000.0;16000.0;0;0;0;0;0;0;6;0;0;0;0;0;0;0;0"
wait_log 'settings v[0-9]+ applied' 3; result "--set: applied by the running app" $?
sleep 3; P=$(peak_after 2); in_range $P 0.17 0.23; result "--set: +6 dB EQ node heard at the output (peak $P)" $?
[[ $($CTL --get tone_enable) == true ]]; result "--get returns the new value" $?

$CTL --save-preset jdsptest-cli && $CTL --list-presets | grep -qx jdsptest-cli; result "--save-preset / --list-presets" $?

mark "bypass"; $CTL --set master_enable=false; sleep 2
$CTL --status | grep -q '^State:   bypassed'; result "--status follows: bypassed" $?
P=$(peak_after 1); in_range $P 0.095 0.105; result "master_enable=false: dry output (peak $P)" $?

mark "load preset"; $CTL --load-preset jdsptest-cli; sleep 3
wait_log 'settings v[0-9]+ applied' 1; result "--load-preset: applied by the running app" $?
P=$(peak_after 2); in_range $P 0.17 0.23; result "--load-preset: saved EQ back (peak $P)" $?
$CTL --status | grep -q '^Preset:  jdsptest-cli'; result "--status names the loaded preset" $?

DEV=$($CTL --list-devices | awk -F'\t' '/^\*/ { sub(/^\* /, "", $1); print $1 }')
$CTL --set-preset-rule "$DEV=jdsptest-cli" && $CTL --list-preset-rules | grep -q "jdsptest-cli"; result "--set-preset-rule on the current output ($DEV)" $?
$CTL --delete-preset-rule "$DEV" && ! $CTL --list-preset-rules | grep -q "jdsptest-cli"; result "--delete-preset-rule" $?
$CTL --delete-preset jdsptest-cli && ! $CTL --list-presets | grep -qx jdsptest-cli; result "--delete-preset" $?

$CTL --set no_such_key=1 2>/dev/null; [[ $? == 1 ]]; result "--set rejects unknown keys" $?

mark "quit"; kill -TERM $MYPID; sleep 2; MYPID=""
$CTL --is-connected; [[ $? == 1 ]]; result "after quit: --is-connected exit 1" $?
[[ ! -f "$SUPPORT/status.json" ]]; result "after quit: status.json removed" $?
$CTL --set bass_enable=true && [[ $($CTL --get bass_enable) == true ]]; result "--set while not running edits audio.conf" $?

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
