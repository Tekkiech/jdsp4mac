# Phase 1 listening checklist

For the human (Claude cannot hear). About 10 minutes. Use music you know well, played from any app (Music, Safari, Spotify). Built-in speakers or wired headphones.

## Setup

1. Open the spike build: `open build/DerivedData/Build/Products/Debug/jdsp4mac.app` (do not rebuild first; a rebuild triggers a new permission prompt).
2. Click the waveform icon in the menu bar to open the test panel.
3. If anything goes wrong at any point, click **Quit** in the panel (or `pkill jdsp4mac`). Your Mac's audio returns to normal immediately.

## 1. Passthrough is transparent

- Mode **Passthrough**, untick "Wait for audio on start", click **Start**, play music.
- [ ] Sounds identical to normal playback: same level, no added hiss, no distortion, no dropouts or crackle.
- [ ] Click **Stop** while music plays. Audio carries on from the speakers directly. Is there a gap, click or level jump at that moment? (Note it; not a gate item.)

## 2. Muted at source, no feedback

- Start passthrough again with music playing.
- [ ] You hear the music once, not doubled or echoed (the original app is muted and only our copy plays).
- [ ] No howl or rising feedback, even with the volume turned up.

## 3. EQ works

- **Stop**, select **EQ**, **Start**. The test EQ is a "V" curve: about +6 dB below 160 Hz and above 6 kHz, flat in the middle.
- [ ] Bass and treble are clearly stronger than in passthrough.
- [ ] No distortion or pumping at normal listening volume.

## 4. Bypass toggle is click-free

- In EQ mode, with music playing, toggle **Bypass DSP** on and off several times. The change crossfades over 20 ms.
- [ ] No click, pop or dropout at the switch, only the tonal change.

## 5. Optional: reverb tail

The offline check found the reverb tail dies away faster than its 2.1 s decay setting suggests (see `docs/findings.md`). If you want to judge it:

```bash
build/DerivedData/Build/Products/Debug/jdsp-offline process <some.wav> /tmp/reverb.wav --reverb
```

then `afplay /tmp/reverb.wav`. Does it sound like a natural medium-hall reverb, and does it match what you hear from JamesDSP on Linux/Android with the default reverb?

## Report back

For each box: pass, or what you heard. Anything odd that is not on the list is worth mentioning too.
