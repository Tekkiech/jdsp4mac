# Phase 6 checklist (human)

The gate: a release zip installs and runs the way the README says, on macOS 27.0.1. About 10 minutes.

The release zip is `build/dist/jdsp4mac-0.0.1-arm64.zip` (built by `scripts/build-release.sh`). A file you build yourself is not marked as downloaded, so first mark it the way Safari would, then install it as a stranger would.

## Setup

1. Quit jdsp4mac if it is running.
2. In Terminal, from the repo folder:
   ```sh
   cp build/dist/jdsp4mac-0.0.1-arm64.zip ~/Downloads/
   xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" ~/Downloads/jdsp4mac-0.0.1-arm64.zip
   ```

## A. Install (README "Install" section)

- [x] Double-click the zip in Downloads, move `jdsp4mac.app` to Applications, open it.
- [x] macOS blocks it. What exactly does the dialog say, and which buttons does it have?
- [x] System Settings › Privacy & Security › **Open Anyway** works. Note every step and prompt (password? a second Open Anyway?), so the README matches macOS 27.0.1 exactly.
- [x] The menu bar icon appears. Power on: the audio-recording prompt appears (this build is signed differently from the dev builds); Allow. Music is processed.

## B. Release build works like the dev build

- [x] Load a preset with liveprog on (e.g. Prime, or switch Liveprog on with dynamicbass.eel): the script is heard.
- [x] Settings › AutoEQ search and Apply work.
- [x] `jdspctl`: run `/Applications/jdsp4mac.app/Contents/MacOS/jdspctl --status` in Terminal: it shows "processing" and your output.

## C. Afterwards

- [x] Quit the release app. Decide whether to keep `/Applications/jdsp4mac.app` (it and the dev build share settings, but each has its own audio-recording permission).

## Report back

For each box: pass, or what happened. For A, the exact dialog text and steps.
