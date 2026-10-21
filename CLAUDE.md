# jdsp4mac — JamesDSP for macOS

System-wide audio effects for macOS using libjamesdsp (the same DSP core used by JamesDSP for Android and JamesDSP for Linux). Menu bar app, no kernel extension, no virtual driver.

Read `PLAN.md` before doing anything. It has the architecture decisions, the phases, and the gate each phase must pass.

## What this project is

- A macOS menu bar app. Control plane in Swift/SwiftUI. Real-time audio plane in C.
- Captures the system mix with a Core Audio process tap, runs it through libjamesdsp, and plays it to the real output device. All of this happens inside one private aggregate device and one IOProc.
- Reuses the Linux app's `audio.conf` key=value format so presets are compatible with JamesDSP for Linux.
- Licence: GPLv3, matching JDSP4Linux and FineTune. Confirm libjamesdsp's own licence in Phase 0 before anything else.

## Hard rules

1. **Nothing in the IOProc may allocate, lock, log, call Objective-C/Swift runtime, or touch ARC.** The IOProc lives in C under `Sources/AudioCore/`. Swift never runs on the audio thread.
2. **Heavy work happens off the audio thread**: convolver IR loading, EEL (liveprog) compilation, sample-rate re-init, EQ filter design. Build a new libjamesdsp instance on a worker thread and swap it in at a buffer boundary.
3. **Always clean up taps and aggregate devices.** A leaked muting tap leaves the user with silence. Destroy on quit, on SIGTERM, and sweep leftovers on launch.
4. **Never process what you cannot verify.** If the tap delivers zeroed buffers (permission missing) show that state in the UI. Do not pretend it is working.
5. **Root-cause problems.** If audio glitches, find why (buffer size, drift, thread priority, lock contention). Do not paper over it with bigger buffers or retries.
6. **Keep it lean.** No edge-case test suites, no optional polish, no speculative features. Only build what the current phase's gate requires.
7. **Do not copy code from sources whose licence you have not checked.** FineTune and AudioCap are references for Core Audio patterns. Write our own code, and note in the commit message what you referenced.

## Stack and decisions

- macOS deployment target 14.4 (process tap API exists from 14.2; AudioCap documents 14.4). **arm64 only** (the test machine is a 14" M1 Pro MacBook Pro). No Intel/universal build.
- Distribution is GitHub only: no Developer ID, no notarisation. Development builds are signed with a free Apple Development certificate; release builds are ad-hoc signed. Do not add notarisation steps.
- Swift 6 + SwiftUI `MenuBarExtra`. C (C11) for `AudioCore`. libjamesdsp vendored as a C target.
- Project generated with XcodeGen (`project.yml`) so everything is text Claude Code can edit. `brew install xcodegen`.
- Build: `xcodegen && xcodebuild -scheme jdsp4mac -configuration Debug build`.
- Mono/stereo only in v1 (libjamesdsp's Linux backend is stereo in/out). Multichannel outputs pass through untouched.

## Layout (target)

```
Vendor/libjamesdsp/        pinned copy of libjamesdsp + its LICENSE files + UPSTREAM.md (repo, commit)
Sources/AudioCore/         C: tap/aggregate/IOProc, planar conversion, instance swap, ring-free passthrough
Sources/Engine/            Swift: device watching, lifecycle, permission state, config -> libjamesdsp params
Sources/Config/            Swift: audio.conf parser/writer, presets
Sources/App/               SwiftUI menu bar + settings window
Tools/jdsp-offline/        CLI: file -> libjamesdsp -> file (used for gate checks and golden tests)
Tests/                     minimal: golden-file DSP checks only
docs/                      notes you write as you learn things (API summary, findings)
```

## Verification

Claude Code cannot hear audio. Every audio phase has objective gates (null test, sweep, underrun counters, CPU) and a short **listening checklist for the human**. Stop and ask the user to run the listening checklist before starting the next phase.

## UI direction

This is a **menu bar app**. Daily use happens in one popup panel (`MenuBarExtra`, `.window` style); a small settings window holds the rest. Full layout is in `PLAN.md` Phase 4.

Take structure and interaction inspiration from FineTune (open source, GPLv3): a vertical list of rows that expand inline, an output device row with a picker, keyboard-drivable popup, a state-aware menu bar icon, system light/dark. Do not copy its code or image assets.

Skin it with the jdsp4mac brand sheet in `Claude Design Branding/` (local only, not in git; macOS system palette, SF fonts, wordmark, app icon, menu bar glyph). Not tekkiech.tech. Native SwiftUI controls. No custom widget toolkit. Avoid generic template-looking UI.
