#!/bin/zsh
# Phase 2 scripted gate. Drives the real app through output switches, a vanishing output, sample-rate
# changes, rapid flapping, panic, SIGTERM, kill -9 and a crash; after each event checks that a
# -20 dBFS test tone reaches the tap and the output (app stats, 1 s interval).
# Needs: a Debug build (xcodegen && xcodebuild ... -derivedDataPath build/DerivedData) and the
# audio-capture permission already granted to that build. Plays short quiet tones on the speakers.
set -u
cd "$(dirname "$0")/.."
BIN=build/DerivedData/Build/Products/Debug
APP=$PWD/$BIN/jdsp4mac.app
H=$PWD/$BIN/haltest
LOG=$HOME/Library/Logs/jdsp4mac/live.log
TMP=$(mktemp -d)
TONE=$TMP/tone.wav
$H tone $TONE 440 2.5 0.1
PASS=0; FAIL=0
# One long-lived helper owns the test aggregates and does all device switching (see haltest serve).
coproc $H serve
hs() { print -p -- "$*"; local line out=""; while read -p line; do [[ $line == ok ]] && break; out=$line; done; print -r -- "$out"; }
ORIG_DEFAULT=$(hs default); ORIG_RATE=$(hs rate)
SPEAKERS_NAME=$($H devices | awk -F'\t' -v id="$ORIG_DEFAULT" '{ sub(/^[* ] /, "", $1); if ($1 == id) print $2 }')

cleanup() {
  pkill -TERM -x jdsp4mac 2>/dev/null; sleep 1
  hs default $ORIG_DEFAULT >/dev/null; hs rate $ORIG_RATE >/dev/null; hs sweep-test >/dev/null; print -p quit
  rm -rf $TMP
}
trap cleanup EXIT

N=0
RUN="$$-$(date +%s)"  # markers must be unique across runs: since() matches the marker line exactly
mark() { N=$((N+1)); MARK="=== phase2 $RUN #$N: $1"; echo "$MARK" >> $LOG; }
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG; }
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); since | tail -8 | cut -c1-200 | sed 's/^/      /'; fi; }
wait_log() {  # wait_log <regex> <timeout s>
  local t=0; while (( t < $2 * 10 )); do since | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done; return 1
}
audio_ok() {  # tone must show up at tap input and output in the stats
  mark "audio check: $1"; afplay $TONE; sleep 1.5
  since | grep ' stats ' | awk '{ for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] } if (v["inPeak"]+0 >= 0.09 && v["outPeak"]+0 >= 0.09) ok=1 } END { exit ok ? 0 : 1 }'
  result "audio flows after: $1" $?
}
launch() { open -n -g "$APP" --args --autostart eq --bypass --stats-every 1; }
running_on() { wait_log "state: running\\(output: \"$1\"" ${2:-10}; }

echo "default output: $ORIG_DEFAULT ($SPEAKERS_NAME), rate $ORIG_RATE"
pkill -TERM -x jdsp4mac 2>/dev/null; sleep 1

mark "launch"; launch
running_on "$SPEAKERS_NAME"; result "starts on $SPEAKERS_NAME" $?
since | grep -q 'permission probe: .*granted'; result "permission probe hears its own -100 dBFS tone" $?
audio_ok "launch"
echo "      private aggregate visible to other processes while running: $($H devices | grep -c 'jdsp4mac-')"

TEST_OUT=$(hs make-output)
mark "switch to test output"; hs default $TEST_OUT >/dev/null
running_on "jdsptest-output"; result "rebuilds onto a new default output (aggregate unwrapped)" $?
wait_log '^.{20} retired: ' 5
since | grep -nE 'running on "jdsptest-output"|^.{20} retired: ' | head -2 | cut -d: -f2- | head -1 | grep -q 'running on'
result "make before break: new graph runs before the old one is retired" $?
audio_ok "switch to test output"

mark "switch back"; hs default $ORIG_DEFAULT >/dev/null
running_on "$SPEAKERS_NAME"; result "rebuilds when switching back" $?
audio_ok "switch back"

hs default $TEST_OUT >/dev/null; running_on "jdsptest-output" >/dev/null
mark "default output vanishes"; hs destroy $TEST_OUT >/dev/null
running_on "$SPEAKERS_NAME"; result "recovers when the default output disappears" $?
audio_ok "default output vanished"

mark "rate 44100"; hs rate 44100 >/dev/null
wait_log 'running on .*: 44100 Hz' 10; result "rebuilds at 44.1 kHz after a rate change" $?
audio_ok "rate change to 44.1 kHz"
mark "rate 48000"; hs rate 48000 >/dev/null
wait_log 'running on .*: 48000 Hz' 10; result "rebuilds at 48 kHz after a rate change" $?
audio_ok "rate change to 48 kHz"

FLAP=$(hs make-output)
mark "flapping"
for i in 1 2 3 4 5 6; do hs default $FLAP >/dev/null; hs default $ORIG_DEFAULT >/dev/null; done
sleep 3
REB=$(since | grep -c 'rebuild #')
# Debouncing may absorb every switch (the final default equals the starting one), so check the
# engine's latest state rather than waiting for a new "running" line.
LAST_STATE=$(grep 'state: ' $LOG | tail -1)
[[ $LAST_STATE == *"running(output: \"$SPEAKERS_NAME\""* ]] && ! since | grep -q 'build failed'
result "settles on $SPEAKERS_NAME after 12 rapid switches ($REB rebuilds)" $?
hs destroy $FLAP >/dev/null
audio_ok "flapping"

mark "panic"; pkill -USR1 -x jdsp4mac
wait_log 'state: stopped\("panic"\)' 5; result "panic (SIGUSR1) removes the tap" $?
pgrep -qx jdsp4mac; result "app survives panic" $?
pkill -TERM -x jdsp4mac; sleep 1

mark "sigterm"; launch; running_on "$SPEAKERS_NAME" >/dev/null
pkill -TERM -x jdsp4mac
wait_log 'teardown: ' 5; result "SIGTERM tears down" $?
sleep 1; ! pgrep -qx jdsp4mac; result "app exits on SIGTERM" $?

mark "kill -9"; launch; running_on "$SPEAKERS_NAME" >/dev/null
pkill -KILL -x jdsp4mac; sleep 2
mark "relaunch after kill -9"; launch
running_on "$SPEAKERS_NAME"; result "relaunch after kill -9 starts" $?
since | grep -q 'launch sweep: destroyed'; echo "      launch sweep found leftovers after kill -9: $([[ $? == 0 ]] && echo yes || echo no)"
audio_ok "relaunch after kill -9"

mark "crash (SIGABRT)"; pkill -ABRT -x jdsp4mac; sleep 2
! pgrep -qx jdsp4mac; result "crash handler re-raises (process gone)" $?
mark "relaunch after crash"; launch
running_on "$SPEAKERS_NAME"; result "relaunch after crash starts" $?
audio_ok "relaunch after crash"

pkill -TERM -x jdsp4mac; sleep 1
mark "denied capture (simulated)"
LONG=$TMP/long.wav; $H tone $LONG 440 16 0.1
afplay $LONG &
AFPLAY=$!
sleep 1  # music already playing before Start: the case the old watchdog missed
open -n -g "$APP" --args --autostart eq --bypass --stats-every 1 --test-zero-input
wait_log 'permission probe: .*denied' 5; result "probe detects denied capture even with audio already playing" $?
wait_log 'state: permissionProblem' 5; result "denied: no tap, permission problem reported" $?
! since | grep -q 'running on'; result "denied: never builds the muting tap" $?
kill $AFPLAY 2>/dev/null; wait $AFPLAY 2>/dev/null
pkill -TERM -x jdsp4mac; sleep 1

mark "sleep and wake"
open -n -g "$APP" --args --autostart eq --bypass --stats-every 1 --test-sleep-after 3
wait_log 'system did wake' 10
wait_log 'rebuild #[0-9]+: system wake' 3; result "wake rebuilds" $?
awk '/system will sleep/{f=1} /system did wake/{f=0} f' <(since) | grep -q 'rebuild #'; [[ $? != 0 ]]; result "no rebuilds while asleep" $?
WAKE_GAP=$(since | grep -E 'system did wake|running on' | awk '/system did wake/{w=$1} w && /running on/{print $1; exit}')
echo "      wake -> running: $(since | grep -E 'system did wake' | cut -c12-19) -> ${WAKE_GAP:11:8}"
audio_ok "sleep and wake"
pkill -TERM -x jdsp4mac; sleep 1

mark "zeroed tap after permission confirmed"
launch; running_on "$SPEAKERS_NAME" >/dev/null
audio_ok "launch (confirms permission)"
mark "zeros on, with permission confirmed"
pkill -USR2 -x jdsp4mac; sleep 1.5
afplay $LONG &
AFPLAY=$!
wait_log 'rebuild #[0-9]+: tap delivered only zeros for 5 s after .* started output' 10; result "confirmed permission: zeros cause one rebuild" $?
sleep 8
! since | grep -q 'state: permissionProblem'; result "confirmed permission: never escalates to permission problem" $?
pgrep -qx jdsp4mac && [[ $(grep 'state: ' $LOG | tail -1) == *running* ]]; result "confirmed permission: keeps running" $?
kill $AFPLAY 2>/dev/null; wait $AFPLAY 2>/dev/null
pkill -TERM -x jdsp4mac; sleep 1

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
