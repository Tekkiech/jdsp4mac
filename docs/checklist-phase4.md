# Phase 4 checklist (human)

The gate: run a full session using only the menu bar panel, and review the look on the M1 Pro screen in light and dark. About 15 minutes.

## Setup

1. Quit any running jdsp4mac, then `open build/DerivedData/Build/Products/Debug/jdsp4mac.app`. Nothing starts by itself the first time.
2. The menu bar icon is the ring with three bars (with a slash while off).

## A. A session from the panel only

- [x] Click the icon. Turn the power switch on. Status says "Processing" and the icon loses its slash. Play music.
- [x] Output picker: switch to headphones and back (it changes the Mac's output, as the Sound menu does). Music follows without a long gap.
- [x] Preset menu: load Prime, then **Default Settings**, then Prime again. The rows update each time. Save the current settings as a new preset; it shows as the preset name.
- [x] In the preset menu, tick "Load … on <output>": an **Auto** badge appears. Switch outputs and back: the preset loads.
- [x] Rows: switch Bass boost on and drag its slider; open Equalizer (click the row) and move a few bands; open Reverb and pick a preset, change decay. No clicks or dropouts.
- [x] Convolver / Liveprog / ViPER-DDC: pick a file from the row's menu (the test room IR, a script). "Add File…" copies a file in.
- [x] Output row's switch (all effects off/on): sound goes dry and back, icon shows the slash while off.
- [x] Quit from the panel, reopen: processing starts again by itself if it was on.

## B. Keyboard

- [x] Open the panel, press ↓/↑: an accent outline moves between rows. ←/→ changes the focused row's slider or preset. Space switches it, Return expands it, Esc closes the panel.

## C. Settings window (gear in the panel)

- [x] **AutoEQ**: search your headphones (first load can take a few seconds), click **Apply**. The AutoEQ row turns on and shows the model; the sound changes. Also try **Import File…** with a ParametricEQ.txt or GraphicEQ.txt from autoeq.app.
- [x] **Liveprog**: open a script, change something, Save: the change is heard (or an error shows). **New** makes a script; **Use in Panel** selects it.
- [x] **General**: "Open jdsp4mac at login" toggles (macOS may ask you to allow it in Login Items). Preset rules are listed and can be removed.

## D. Look and feel

- [x] Light and dark (System Settings › Appearance): panel, icon and settings read well in both.
- [x] Anything that looks generic, cramped, misaligned or unclear: note it. Screenshots welcome.

## Report back

For each box: pass, or what you saw.
