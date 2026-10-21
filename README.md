# jdsp4mac

System-wide JamesDSP audio effects for macOS, as a menu bar app. It runs everything your Mac plays through [libjamesdsp](https://github.com/james34602/JamesDSPManager), the DSP core of JamesDSP for Android and [JamesDSP for Linux](https://github.com/Audio4Linux/JDSP4Linux). It captures audio with a Core Audio process tap: no kernel extension, no virtual audio driver, no reboot.

- **Effects:** bass boost, equalizer (FIR/IIR), AutoEQ arbitrary-response EQ, compander, reverb, convolver (impulse responses), crossfeed (BS2B and HRTF), stereo width, ViPER-DDC, vacuum tube, and liveprog (EEL2 scripts).
- **Presets** in the JamesDSP for Linux `audio.conf` format. Import presets from JamesDSP for Linux, RootlessJamesDSP (`.tar`) and JamesDSP for Android (`james.dsp.*.xml`). Export to Linux and RootlessJamesDSP. Presets can load automatically per output device.
- **AutoEQ:** search [AutoEq](https://github.com/jaakkopasanen/AutoEq)'s headphone profiles and apply one, or import a GraphicEQ / ParametricEQ file.
- **`jdspctl`:** command-line control with JamesDSP for Linux's remote options, for scripts, Shortcuts and Raycast.

Requirements: macOS 14.4 or later on Apple silicon. Tested on macOS 27.0.1 on an M1 Pro MacBook Pro only.

## Install

jdsp4mac is free and distributed only here, so it is not notarised by Apple. macOS blocks it the first time; you allow it once.

1. Download `jdsp4mac-<version>-arm64.zip` from [Releases](../../releases), unzip it, and move `jdsp4mac.app` to Applications.
2. Open it. macOS shows **"jdsp4mac.app" Not Opened** ("Apple could not verify … is free of malware"): click **Done**, not Move to Bin.
3. Open **System Settings › Privacy & Security**, scroll to Security, and click **Open Anyway** next to the jdsp4mac message. Click **Open Anyway** again in the dialog that follows, and confirm with Touch ID or your password.

   (Control-click › Open no longer bypasses this since macOS Sequoia.) Alternatively, in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/jdsp4mac.app
   ```
4. The jdsp4mac icon (a ring with three bars) appears in the menu bar. Click it and switch the power on. macOS asks to let jdsp4mac record system audio: click **Allow**. This is how it hears what your Mac plays; nothing is recorded or sent anywhere.

If you clicked Don't Allow, the panel says there is no audio from the tap. Turn jdsp4mac on under **System Settings › Privacy & Security › Screen & System Audio Recording** ("System Audio Recording Only"), then quit and reopen jdsp4mac.

After an update you may be asked to allow audio recording again, because each release is signed separately.

## Use

Everything is in the menu bar panel: the power switch, the output device, presets, and one row per effect. Click a row to see its settings. The **Output** row's switch turns all effects off and on.

Keyboard, with the panel open: ↑/↓ move between effects, ←/→ adjust the selected one, Space switches it on or off, Return opens its settings, Esc closes the panel.

The settings window (gear icon) has AutoEQ search, the liveprog script editor, apps without effects (they play directly, e.g. for calls), presets per output, open at login, and diagnostics.

Files live in `~/Library/Application Support/jdsp4mac/`:

| | |
|---|---|
| `audio.conf` | current settings (JamesDSP for Linux format; edits are applied live) |
| `presets/` | presets |
| `excluded-apps.txt` | bundle IDs of apps that play without effects, one per line |
| `irs/`, `vdc/`, `liveprog/` | impulse responses, ViPER-DDC files, liveprog scripts |

Presets from Linux refer to files by Linux path; jdsp4mac finds them by file name in these folders.

### jdspctl

`jdspctl` is inside the app. To use it from Terminal:

```sh
sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/jdsp4mac.app/Contents/MacOS/jdspctl /usr/local/bin/jdspctl
```

```sh
jdspctl --status
jdspctl --set bass_enable=true bass_maxgain=8
jdspctl --load-preset "My headphones"
jdspctl --list-devices
jdspctl --set-preset-rule "BuiltInSpeakerDevice=Speakers"
jdspctl --help
```

It changes the same files the app watches, so changes apply immediately while jdsp4mac runs, and also work while it is not running.

## Limitations

- Stereo only. Outputs with more than two channels play unprocessed.
- Apps without effects: an app's helper processes, including the WebKit process that Safari and other web-based apps play through, are found through the app macOS records as responsible for them. That uses a private macOS call; if a future macOS removes it, only the app's own process is excluded (the log says so).
- One process tap at a time is the safe assumption: other tap-based audio apps (for example FineTune) running on the same output reportedly stop each other from starting. Quit them if jdsp4mac stays on "Starting".
- Long convolver impulse responses cost CPU in proportion to their length (about 13 % of a core for 5 s, 25 % for 20 s on an M1 Pro). Typical room and headphone IRs are under 2 s.
- Unnotarised: see Install.

## Build from source

```sh
brew install xcodegen
xcodegen && xcodebuild -scheme jdsp4mac -configuration Debug build
```

Debug builds are ad-hoc signed by default, which makes macOS ask for the audio-recording permission again after every rebuild. To keep it, sign with a free Apple Development certificate: see `xcconfig/Signing.xcconfig`.

Release zip: `scripts/build-release.sh [version]` (ad-hoc signed, with `jdspctl` inside). Checks: `Tests/golden.sh` (offline DSP), and `Tests/phase2.sh`, `phase3.sh`, `phase5.sh` (live; they play a quiet tone and need the permission granted).

## Credits and licence

- libjamesdsp by James Fung ([JamesDSPManager](https://github.com/james34602/JamesDSPManager)), as maintained in [JDSP4Linux](https://github.com/Audio4Linux/JDSP4Linux) by Tim Schneeberger, which also defines the preset format and CLI this app follows.
- Headphone profiles from [AutoEq](https://github.com/jaakkopasanen/AutoEq) by Jaakko Pasanen; measurements by the sources named with each profile.
- Panel layout inspired by [FineTune](https://github.com/ronitsingh10/FineTune) (no code used).

GPL-3.0-or-later. See `LICENSE`, and `docs/licences.md` for the bundled third-party code.
