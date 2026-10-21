# Phase 2 checklist (human)

Everything the scripted gate (`Tests/phase2.sh`, 29 checks) cannot do: physical devices, sleep, the permission-denied path, and how the gaps sound. About 15 minutes, plus 5 if you do the optional permission test.

## Setup

1. Open the app (do not rebuild first): `open build/DerivedData/Build/Products/Debug/jdsp4mac.app`
2. Click the waveform icon in the menu bar. Mode **EQ**, **Bypass DSP** off, click **Start**.
3. Play music you know from any app. You should hear the "V" EQ (more bass and treble).
4. The status line in the panel names the output in use. Glance at it after each step.
5. If anything gets stuck: **Panic** (or **Quit**) and your audio plays directly again.

## A. Headphone jack (KZ Gale)

- [ ] Music playing on the speakers, plug the headphones in. Music moves to the headphones within about a second, still with the EQ. Status names the headphone output.
- [ ] Unplug. Music moves back to the speakers, still with the EQ.
- [ ] Any pop, click, or a gap longer than a blink at either moment? (Expected: a short gap, around a tenth of a second, no pop.)

## B. Switching output by hand

- [ ] With headphones plugged in, switch output in Control Centre (Sound) between the speakers and the headphones a few times, quickly. It ends up on the one you picked last, with the EQ, no stuck silence.

## C. Sleep and wake

- [ ] Music playing, close the lid. Wait about 30 seconds. Open it and log in.
- [ ] Play music again (most players pause on sleep). It comes back with the EQ within a couple of seconds. Status says running.

## D. Stop, Start, Panic, Quit (all while music plays)

- [ ] **Stop**: music carries on directly. Compared with Phase 1, is the gap shorter or the same? Any click? (There is now a 20 ms fade-out before the tap is removed.)
- [ ] **Start**: the EQ comes back. Any pop when it starts? (There is now a 20 ms fade-in.)
- [ ] **Panic**: music carries on directly at once. Status says "Stopped (panic)".
- [ ] **Start** again, then **Quit**: music carries on directly.

## E. Bluetooth (only if you have Bluetooth headphones)

- [ ] Connect them while music plays: music moves to them with the EQ.
- [ ] Disconnect: back to speakers or headphones, with the EQ.
- [ ] Any crackle on Bluetooth? (Drift compensation is switched off for Bluetooth on purpose.)

## F. Optional: permission denied (about 5 minutes)

This tells us what macOS does when capture is denied, which I cannot find out without a person clicking "Don't Allow".

1. Quit jdsp4mac.
2. Reset its audio-capture permission:
   ```bash
   tccutil reset AudioCapture tech.tekkiech.jdsp4mac.dev
   ```
   (If `tccutil` rejects the service name, skip this section and tell me.)
3. Open the app, click **Start**, and click **Don't Allow** on the prompt.
4. Play music for about 20 seconds.
   - [ ] What do you hear: the music normally, the music without EQ, or silence?
   - [ ] What does the panel's status line say after 20 seconds?
5. Turn the permission back on: System Settings, Privacy & Security, Screen & System Audio Recording, allow jdsp4mac (under "System Audio Recording Only" if there are two lists). Quit and reopen the app, Start, and confirm the EQ works again.

## Report back

For each box: pass, or what you heard and saw. For F, the answers to the two questions. Anything else odd is useful too.

## Re-check after the fixes (2026-10-20)

Only the parts that changed. Same setup (EQ, Start, music playing).

- [ ] **A again:** plug the headphones in while music plays on the speakers. Is the gap shorter than the "bit over 1 s" from before? Unplug: still fine?
- [ ] **C again:** close the lid ~30 s, open, play music. Does the EQ'd sound come back sooner than before (previously about 1.5 s of un-EQ'd playback first)?
- [ ] **F again (optional, 3 min):** run `tccutil reset AudioCapture tech.tekkiech.jdsp4mac.dev`, open the app, Start, click **Don't Allow**, play music. Expected now: you hear the music normally (no EQ, never silence) and the status says there is no audio from the tap. Then re-enable jdsp4mac under Privacy & Security, Screen & System Audio Recording, quit and reopen, Start, and confirm the EQ works.
