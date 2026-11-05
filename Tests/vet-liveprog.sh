#!/bin/zsh
# Compiles each liveprog script in a folder and runs 20 s of noise through it at 48 kHz, offline,
# with a 60 s limit per script. A script passes if it compiles and its output stays finite.
#   Tests/vet-liveprog.sh <folder>     results also go to build/liveprog-vet.txt
# No audio device or permission is involved. Needs a Debug build.
set -u
cd "$(dirname "$0")/.."
TOOL=$PWD/build/DerivedData/Build/Products/Debug/jdsp-offline
OUT=build/liveprog-vet.txt
PASS=0; FAIL=0
: > $OUT
for f in "$1"/*.eel; do
  out=$(perl -e 'alarm 60; exec @ARGV' "$TOOL" bench-liveprog "$f" 2>/dev/null)
  code=$?
  line=$(print -r -- "$out" | tail -1)
  if [[ $code == 0 ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); line="FAIL($code) $(basename "$f")  $line"; fi
  print -r -- "$line" | tee -a $OUT
done
print -r -- "$PASS passed, $FAIL failed" | tee -a $OUT
