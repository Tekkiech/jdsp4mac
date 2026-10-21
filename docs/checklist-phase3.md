# Phase 3 checklist (human)

The gate: load a real Linux preset and hear it applied; change settings while music plays and listen for glitches. About 10 minutes. Wired headphones are best for hearing clicks.

## Setup

1. `open build/DerivedData/Build/Products/Debug/jdsp4mac.app`, click the waveform icon, Mode **DSP**, **Start**, play music.
2. Settings file: `~/Library/Application Support/jdsp4mac/audio.conf`. Open it in TextEdit (or any editor). Every save is applied live, the same way loading a preset is.
3. Messages (missing files, liveprog errors) appear in orange in the panel.

## A. A real Linux preset

Real JDSP4Linux presets from GitHub are in `~/scratch/presets/` (e.g. `asus-jamesdsp/jamesdsp/presets/`). If you have your own JamesDSP presets (Linux `.conf`, Rootless `.tar`, Android `james.dsp.headset.xml`), use those.

- [x] Panel, **Import…**, pick a preset. It appears in the preset list; any notes (missing IR/DDC files, things that do not map) show in orange.
- [x] **Load** it. The sound changes to what the preset describes. If you know how it sounds on Linux/Android: does it match?

## B. Changes while music plays (listen for clicks, dropouts, level jumps)

Click **Defaults** in the panel first (all effects off; your presets are untouched). Then in the editor, change one line at a time and save:
- [x] `tone_enable=true`, then change a few gains in `tone_eq` (the last 15 numbers): smooth change, no click.
- [x] `reverb_enable=true`, then `reverb_decay=4.0`, then `reverb_enable=false`.
- [x] Convolver: put a `.wav` impulse response in `~/Library/Application Support/jdsp4mac/irs/`, then `convolver_enable=true` and `convolver_file=<name>.wav`. Toggle it on and off a few times.
- [x] Liveprog: `liveprog_enable=true` and `liveprog_file=` one of the scripts in `~/scratch/JDSP4Linux/resources/assets/liveprog/` (copy it into `~/Library/Application Support/jdsp4mac/liveprog/` first), e.g. `stereowide.eel` or `dynamicbass.eel`. Then a broken edit to the script file: an orange error appears and music continues.
- [x] `master_enable=false` then `true`: effects off/on without a click.

## C. Optional

- [x] Export a preset as RootlessJamesDSP (`.tar`) and load it in RootlessJamesDSP on an Android phone. Does Rootless accept it?
- [x] "Use … on <output>": select a preset, tick the box, switch output (headphones in/out). The preset loads when that output becomes active.

## Report back

For each box: pass, or what you heard. Note anything odd.
