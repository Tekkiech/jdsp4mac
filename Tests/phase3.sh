#!/bin/zsh
# Phase 3 scripted gate: settings changes while audio plays. Plays a quiet 440 Hz tone and edits the
# live audio.conf like any user or preset load would, then checks the engine's 1 s stats:
#  - the change is built off the audio thread and swapped in ("settings vN applied"),
#  - the output level matches the expected effect,
#  - no click: the largest sample step stays within what a pure 440 Hz tone can produce
#    (step <= peak * 2*pi*440/48000 * 1.4) while the output is still a pure tone,
#  - no discontinuities, overloads, layout errors or unprocessed buffers; IOProc max < 25 % budget.
# Needs: Debug build, capture permission granted. Backs up and restores audio.conf and preset rules.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/build/DerivedData/Build/Products/Debug
APP=$BIN/jdsp4mac.app
CONF_TOOL=$BIN/jdspconf
SUPPORT="$HOME/Library/Application Support/jdsp4mac"
CONF="$SUPPORT/audio.conf"
LOG=$HOME/Library/Logs/jdsp4mac/live.log
TMP=$(mktemp -d)
PASS=0; FAIL=0
RUN="$$-$(date +%s)"
N=0
MYPID=""
AFPLAY=""

cp "$CONF" $TMP/audio.conf.backup 2>/dev/null
# Per-output preset rules would load a user preset over the test settings: set them aside.
RULES="$SUPPORT/rules.json"
[[ -f $RULES ]] && mv "$RULES" $TMP/rules.json.backup
cleanup() {
  [[ -n $MYPID ]] && kill -TERM $MYPID 2>/dev/null
  kill $AFPLAY 2>/dev/null
  sleep 1
  [[ -f $TMP/audio.conf.backup ]] && cp $TMP/audio.conf.backup "$CONF"
  [[ -f $TMP/rules.json.backup ]] && mv $TMP/rules.json.backup "$RULES"
  rm -f "$SUPPORT/irs/jdsptest-long.wav" "$SUPPORT/liveprog/jdsptest-gain.eel" "$SUPPORT/liveprog/jdsptest-broken.eel" \
        "$SUPPORT/presets/jdsptest-preset.conf"
  rm -rf $TMP
}
trap cleanup EXIT

mark() { N=$((N+1)); MARK="=== phase3 $RUN #$N: $1"; echo "$MARK" >> $LOG; }
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' $LOG; }
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); since | grep -v ' stats ' | tail -5 | cut -c1-200 | sed 's/^/      /'; fi; }
wait_log() { local t=0; while (( t < $2 * 10 )); do since | grep -qE "$1" && return 0; sleep 0.1; t=$((t+1)); done; return 1; }
set_conf() { $CONF_TOOL set "$CONF" "$@"; }
# Output peak (median of the stats lines after the marker, skipping the first `skip` lines).
peak_after() { since | grep ' stats ' | tail -n +$(( ${1:-2} + 1 )) | grep -o 'outPeak=[0-9.]*' | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : 0)}'; }
in_range() { awk -v v=$1 -v lo=$2 -v hi=$3 'BEGIN { exit !(v >= lo && v <= hi) }'; }
# Click check over all stats lines since the marker: step / peak within a pure tone's slope.
no_click() {
  since | grep ' stats ' | awk '{ for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] }
    p=v["outPeak"]+0; s=v["maxStep"]+0; if (p > 0.01 && s / p > 0.0806) { bad=1; print "      step " s " peak " p } }
    END { exit bad }'
}

# Test files: a 5 s impulse response, a gain script, a broken script.
python3 -I - $TMP <<'EOF'
import sys, wave, math, array, random
random.seed(5); fs=48000; n=fs*5; a=array.array('h')
for i in range(n):
    env = math.exp(-6.9*i/n)
    a.append(int(32767*0.3*env*random.uniform(-1,1))); a.append(int(32767*0.3*env*random.uniform(-1,1)))
w=wave.open(sys.argv[1]+'/long.wav','wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(fs); w.writeframes(a.tobytes()); w.close()
EOF
mkdir -p "$SUPPORT/irs" "$SUPPORT/liveprog" "$SUPPORT/presets"
cp $TMP/long.wav "$SUPPORT/irs/jdsptest-long.wav"
printf '@init\ng = 0.5;\n@sample\nspl0 = spl0 * g;\nspl1 = spl1 * g;\n' > "$SUPPORT/liveprog/jdsptest-gain.eel"
printf '@init\nx = ;\n@sample\nspl0 = spl0;\n' > "$SUPPORT/liveprog/jdsptest-broken.eel"
$BIN/haltest tone $TMP/tone.wav 440 600 0.1

# Start from the stock settings (all effects off).
$CONF_TOOL defaults "$CONF"
open -n -g "$APP" --args --autostart dsp --stats-every 1
sleep 2; MYPID=$(pgrep -nx jdsp4mac)
mark "running"; wait_log 'state: running' 10 || true
afplay $TMP/tone.wav &
AFPLAY=$!
sleep 3

EQ_FREQS="25.0;40.0;63.0;100.0;160.0;250.0;400.0;630.0;1000.0;1600.0;2500.0;4000.0;6300.0;10000.0;16000.0"

mark "baseline"; sleep 3
P=$(peak_after 1); in_range $P 0.095 0.105; result "baseline, effects off: output = input (peak $P)" $?

mark "EQ +6 dB at 400 Hz"; set_conf tone_enable=true "tone_eq=$EQ_FREQS;0;0;0;0;0;0;6;0;0;0;0;0;0;0;0"
wait_log 'settings v[0-9]+ applied' 3; result "EQ change built off the audio thread and swapped in" $?
sleep 3; P=$(peak_after 2); in_range $P 0.17 0.23; result "EQ +6 dB node at 400 Hz: 440 Hz tone at about 2x (peak $P)" $?
no_click; result "no click while switching EQ on (crossfade)" $?

mark "EQ off"; set_conf tone_enable=false; sleep 3
P=$(peak_after 2); in_range $P 0.095 0.105; result "EQ off: back to 0.100 (peak $P)" $?
no_click; result "no click while switching EQ off" $?

mark "rapid EQ changes"
for g in 1 2 3 4 5 6 5 4 3 2; do set_conf "tone_eq=$EQ_FREQS;0;0;0;0;0;0;$g;0;0;0;0;0;0;0;0" tone_enable=true; sleep 0.1; done
sleep 3
BUILT=$(since | grep -c 'settings v[0-9]* applied')
P=$(peak_after 3); in_range $P 0.115 0.145; result "10 changes in 1 s: $BUILT swaps, final +2 dB applied (peak $P)" $?
no_click; result "no click during rapid changes" $?
set_conf tone_enable=false; sleep 2

mark "master off"; set_conf master_enable=false; sleep 2; set_conf bass_enable=true bass_maxgain=10; sleep 2
P=$(peak_after 2); in_range $P 0.095 0.105; result "master_enable=false bypasses DSP even with bass on (peak $P)" $?
set_conf master_enable=true bass_enable=false; sleep 2

mark "liveprog gain script"; set_conf liveprog_enable=true liveprog_file=/home/someone/.config/jamesdsp/liveprog/jdsptest-gain.eel
sleep 3; P=$(peak_after 2); in_range $P 0.045 0.055; result "liveprog script found by name and running (x0.5, peak $P)" $?
no_click; result "no click while switching liveprog on" $?

mark "broken liveprog script"; set_conf liveprog_file=jdsptest-broken.eel
wait_log 'Liveprog: Syntax error' 4; result "broken script: error reported as a message" $?
sleep 2; P=$(peak_after 1); in_range $P 0.095 0.105; result "broken script: liveprog off, audio continues (peak $P)" $?
mark "script fixed and saved"; printf '@init\nx = 1;\n@sample\nspl0 = spl0;\n' > "$SUPPORT/liveprog/jdsptest-broken.eel"
wait_log 'dsp: problems cleared' 4; result "fixed script: reloaded on save, error cleared" $?
set_conf liveprog_enable=false; sleep 2

mark "long convolver"; set_conf convolver_enable=true convolver_file=jdsptest-long.wav; sleep 4
wait_log 'settings v[0-9]+ applied' 1; result "5 s impulse response loaded and swapped in" $?
set_conf convolver_enable=false; sleep 2

mark "crossfeed mode 5"; set_conf crossfeed_enable=true crossfeed_mode=5; sleep 4
set_conf crossfeed_enable=false; sleep 1
mark "reverb"; set_conf reverb_enable=true; sleep 3; set_conf reverb_enable=false; sleep 2

# A real JDSP4Linux preset, if one is given (JDSP_TEST_PRESET=/path/to/preset.conf).
mark "real Linux preset"
if [[ -f ${JDSP_TEST_PRESET:-} ]]; then
  cp "$JDSP_TEST_PRESET" "$SUPPORT/presets/jdsptest-preset.conf"
  cp "$SUPPORT/presets/jdsptest-preset.conf" "$CONF"; sleep 4
  wait_log 'settings v[0-9]+ applied' 1; result "real JDSP4Linux preset applied live" $?
else
  echo "SKIP  real JDSP4Linux preset (set JDSP_TEST_PRESET=/path/to/preset.conf)"
fi

mark "whole-run health"
ALL=$(awk -v r="=== phase3 $RUN #1: running" 'f; $0 == r { f = 1 }' $LOG | grep ' stats ')
echo "$ALL" | awk '{ for (i=1;i<=NF;i++) { split($i,kv,"="); v[kv[1]]=kv[2] } } END {
  printf "      callbacks %s, disc %s/%s, overloads %s, layout %s, unprocessed %s, max IOProc %s, CPU %s\n", v["cb"], v["outDisc"], v["inDisc"], v["overloads"], v["layoutErr"], v["unprocessed"], v["maxCb"], v["cpu"]
  bad = (v["outDisc"]+0 > 0) || (v["inDisc"]+0 > 0) || (v["overloads"]+0 > 0) || (v["layoutErr"]+0 > 0) || (v["unprocessed"]+0 > 0); exit bad }'
result "no discontinuities, overloads, layout errors or unprocessed buffers" $?
MAXCB=$(echo "$ALL" | grep -o 'maxCb=[0-9.]*' | cut -d= -f2 | sort -n | tail -1)
in_range ${MAXCB%ms} 0 2.667; result "IOProc max ${MAXCB} under 25 % of the 10.67 ms buffer" $?

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
