#!/bin/zsh
# Bundled library gate, offline: the app's bundled files reach a new library once, a user's own or
# edited file is never replaced, a deleted one stays deleted, and a file new in a later release
# still arrives. Also checks every bundled preset loads and renders with finite output.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/build/DerivedData/Build/Products/Debug
SRC=Resources/Library
TMP=$(mktemp -d)
ROOT=$TMP/lib
PASS=0; FAIL=0
trap 'rm -rf ${TMP:?}' EXIT
result() { if [[ $2 == 0 ]]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
seed() { $BIN/jdspconf seed "$1" $ROOT; }

COUNT=$(find $SRC/liveprog $SRC/irs $SRC/vdc $SRC/presets -type f | wc -l | xargs)
mkdir -p $ROOT/liveprog; echo "mine" > $ROOT/liveprog/dynamicbass.eel
N=$(seed $SRC | wc -l | xargs)
[[ $N == $((COUNT - 1)) ]]; result "first run copies $N of $COUNT files, skipping the one already there" $?
[[ $(cat $ROOT/liveprog/dynamicbass.eel) == mine ]]; result "the user's file of the same name is untouched" $?
[[ -z $(seed $SRC) ]]; result "second run copies nothing" $?

rm "$ROOT/presets/Bass.conf"; echo "edited" > $ROOT/irs/SwapChannels.wav
[[ -z $(seed $SRC) && ! -e $ROOT/presets/Bass.conf ]]; result "a deleted preset stays deleted" $?
[[ $(cat $ROOT/irs/SwapChannels.wav) == edited ]]; result "an edited file stays edited" $?

cp -R $SRC $TMP/later; echo "new" > $TMP/later/liveprog/newInLaterRelease.eel
[[ $(seed $TMP/later) == liveprog/newInLaterRelease.eel ]]; result "a file new in a later release arrives" $?

$BIN/haltest tone $TMP/t.wav 440 2 0.1 >/dev/null
for p in $SRC/presets/*.conf; do
  out=$($BIN/jdspconf render "$p" $TMP/t.wav --library $SRC 2>/dev/null); code=$?
  [[ $code == 0 && $out != *message:* ]]; result "$(basename "$p" .conf) renders with no problem messages" $?
done

echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
