# PLAN — JamesDSP for macOS (jdsp4mac)

Date of research: 2026-10-19. Everything marked **[verify]** was not confirmed from a source and must be checked in the phase that names it.

## Kickoff prompt (paste into Claude Code in an empty repo containing CLAUDE.md and this file)

> Read CLAUDE.md and PLAN.md. Start Phase 0. Do not start Phase 1 until Phase 0's deliverables exist and I have confirmed the licence finding. Keep commits small and per-task. Update the checklist in PLAN.md as you go.

---

## 1. Goal and non-goals

**Goal (v1):** system-wide JamesDSP processing on macOS with: bypass, auto bass boost, compander, reverb, FIR/IIR EQ, GraphicEQ (AutoEQ), convolver, crossfeed, stereo widener, ViPER-DDC, limiter, and liveprog (EEL2 scripts). Presets compatible with the Linux `audio.conf` format.

**Non-goals** (v1 and later for AUv3, Intel and notarisation, decided 2026-10-21): per-app effect chains, per-app volume (FineTune already does this), multichannel processing, AUv3/VST plugin, Mac App Store, macOS older than 14.4, Intel Macs (arm64 only, the only test machine is an M1 Pro MacBook Pro), Developer ID signing and notarisation (distribution is GitHub only).

## 2. Research findings that drive the design

### 2.1 libjamesdsp
- JamesDSP Android's repo describes the library as cross-platform, and JDSP4Linux uses its core library. The Linux app is a wrapper (PipeWire filter, or GStreamer for PulseAudio) around it. Sources: JamesDSPManager README; JDSP4Linux README.
- Init sequence seen in the RootlessJamesDSP wrapper: `JamesDSPGlobalMemoryAllocation()`, then `JamesDSPInit(jdsp, blockSizeMax, sample_rate)` (Phase 0 correction: the second argument is the maximum block size, not a device id; JDSP4Linux passes 128), then check `JamesDSPGetMutexStatus(jdsp)`. Effect setters include `CompressorSetParam(...)` and `CompressorSetGain(...)`. Function signatures change between versions, so **read `jdsp_header.h` in the vendored copy and write `docs/libjamesdsp-api.md`**.
- Process-call format (checked in Phase 0, `docs/libjamesdsp-api.md`): stereo only, via function pointers on the instance. The PipeWire backend calls `processFloatDeinterleaved(dsp, inL, inR, outL, outR, n)` (planar float). Correction: the GStreamer (PulseAudio) wrapper does **not** deinterleave; it calls the interleaved `process*Multiplexd` variants (`gstjamesdsp.c:271-301`). We use planar float.
- The Linux `DspHost` class (`src/audio/base/DspHost.cpp`, with `updateLimiter()`, `updateReverb()` etc.) maps config keys to libjamesdsp calls. That mapping is the reference for our `Config -> params` layer. It uses Qt (`QMetaEnum`), so it must be rewritten, not copied. GitHub tree pages were blocked for automated fetch; read the code by cloning.
- Linux config is a plain `key=value` file (`~/.config/jamesdsp/audio.conf`), e.g. `reverb_enable=true`. The foobar2000 plugin notes `.jdsp` presets are the same plain text. Reusing this format gives free preset compatibility.
- Liveprog is EEL2 (from Cockos WDL). The Android README says EEL code is compiled to "opcode". WDL's own EEL2 has native x86/x64 code generation. A jsusfx project notes native ARM support and native x86/x86_64 on OS X. (Phase 0 result: libjamesdsp's EEL build does not generate machine code; see the next bullet. The rest of this bullet only applies to a native build.) Whether libjamesdsp's EEL build generates machine code, and whether it has an arm64 code generator: if it does, macOS arm64 needs the executable memory allocated with `MAP_JIT` and `pthread_jit_write_protect_np` toggled around code writes (MAP_JIT alone is not sufficient on Apple silicon). Under the hardened runtime, `MAP_JIT` also needs the `com.apple.security.cs.allow-jit` entitlement. An Apple Developer Forums thread shows this entitlement working on an ad-hoc signed app, so **no paid account or notarisation is needed** to use it. The jsusfx note also mentions a "portable" (non-native) EEL build that is about 10x slower than native, which is a possible fallback. See decision D10.
- Evidence from James Fung's standalone `EEL_VM` repo ("EEL2 compiler and execution VM", the engine JamesDSP uses): its file list has `nseel-compiler.c`, `nseel-ram.c`, `ns-eel-int.h` and `glue_port.h`, and **no `asm-nseel-*` files and no `nseel-cfunc.c`**, which are what WDL's native x86/x64 code generation relies on (per the EEL2 CMake write-up). That points to the portable, non-native variant. It is only a pointer: it is the standalone repo, not libjamesdsp's vendored copy, and I could not read the source. **Confirmed in Phase 0** on the vendored copy: only `glue_port.h` (a bytecode `switch` interpreter over malloc'd blocks), no mmap/mprotect/MAP_JIT, and `__clear_cache` only under `#ifdef __arm__`. See `docs/findings.md`.
- A third-party foobar2000 plugin (Windows) runs libjamesdsp in a separate host process over IPC for crash isolation. Useful precedent: if EEL scripts crash the engine, a separate helper process is the fallback design.
- libjamesdsp's licence: GPL with no version stated anywhere (bare GPLv2 text, no file headers). Treated as "any version" per GPLv2 §9; see `docs/licences.md`. JDSP4Linux is GPLv3. The Android README says the engine frame is based on Antti Lankila's DSPManager.

### 2.2 Core Audio taps (macOS)
- `AudioHardwareCreateProcessTap(CATapDescription, &tapID)` exists from macOS 14.2. A tap is used as an input in an aggregate device, like a microphone. Taps can be private, can mix down to mono/stereo, and can **mute the process output** so audio only goes to the tap. Source: Apple's "Capturing system audio with Core Audio taps".
- Requires `NSAudioCaptureUsageDescription` in Info.plist. The permission prompt appears when IO **starts** on an aggregate device containing the tap, not when the tap is created. (Phase 1 observation on macOS 27.0.1: the prompt already blocks `AudioDeviceCreateIOProcID` on that aggregate, before `AudioDeviceStart`. See `docs/findings.md`.) If the key is missing or access is denied, the tap still "succeeds" and delivers **zeroed buffers**. Sources: AudioCap README, catap docs, the "2000 buffers of nothing" post. → We must detect silence-with-activity and show a permission state.
- A global tap that excludes your own process avoids feedback loops (`CATapDescription(monoGlobalTapButExcludeProcesses:)` and the stereo equivalent). Source: same post. Our output goes through our own process, so we must exclude it.
- The tap lives in a private aggregate device together with the real output device. When the default output device changes, recreate everything against the new device. After `AudioHardwareCreateAggregateDevice` the device may not be ready immediately. Source: Mimir write-up.
- Aggregate devices need matching sample rates and drift correction on non-clock-source devices. Source: Apple Audio MIDI Setup docs.
- FineTune v1.8 notes: routing to a user-made aggregate device produced silence until it flattened them into sub-devices; the first audible buffer after silence fades in. Worth knowing as failure modes. Source: FineTune v1.8.0 release notes.
- A small tap-based mixer ("Fader") does crash-safe cleanup of leftover aggregate devices on next launch. We must do the same. Source: Fader case study.
- Comparison table from another project: process-tap apps vs virtual-driver apps (BackgroundMusic, SoundSource). Taps need no driver install. Source: Fabar README.

### 2.2b Findings on macOS 27 (the user's OS is 27.0.1; this is newer than most model knowledge, so verify against current Apple docs)
- An Apple Developer Forums post tested on macOS 27.0 confirms our exact design works with public API: a tap that excludes the app's own process and uses `CATapMutedWhenTapped`, a private aggregate with the tap as a sub-tap and the real device as main sub-device, and an IOProc that processes tap input into device output. Source: Apple Developer Forums thread 848578.
- Same post: the tap delivers IOProc callbacks **only while some process is rendering audio**; at idle there are none. Our code must not assume a steady callback stream.
- Same post: **two process taps on the same device from different processes interfere**; `AudioDeviceStart` blocks until the other tap is torn down. So running FineTune, SoundSource-style tap apps or any other tap-based app at the same time as jdsp4mac may hang our start. Start IO off the main thread with a timeout and show a clear status. Also note (SDK header, Phase 0): with `kAudioAggregateDeviceTapAutoStartKey` set, `AudioDeviceStart` deliberately waits until a tapped process starts playing, so a "hang" at idle may be that key rather than tap interference. Distinguish the two in Phase 1.
- Apple forums report taps delivering **all-zero buffers while system audio is audible**, linked to output sample-rate renegotiation (44.1 <-> 48 kHz) and Bluetooth state changes. The reported workaround is a **full teardown and rebuild of both the tap and the aggregate device**; restarting only the IOProc or only the aggregate was not reliable. Source: Apple Developer Forums, Core Audio tag.
- Another forum report: tap level scales down with the number of stereo output pairs on multi-output devices (about -12 dB on an 8-output interface). The MacBook's built-in 2-channel output should not be affected, but multichannel devices are passed through unprocessed in v1 anyway.
- Gatekeeper: since macOS Sequoia the old Control-click > Open bypass is gone. An ad-hoc signed, unnotarised app is approved once via System Settings > Privacy & Security > Open Anyway (recorded per app), or by removing the quarantine attribute. Sources: inventivehq guide, Godot macOS docs.

### 2.3 What FineTune gives us
- Swift, GPLv3, macOS 15+, menu bar app, per-app taps, 10-band EQ, AutoEQ import (EqualizerAPO ParametricEQ.txt), URL schemes. Source: FineTune README.
- Its design is **per-app taps with per-app chains**. JamesDSP on Linux is a **single global chain**. A single global instance is simpler and cheaper (the convolver is heavy). So we do not fork FineTune.

## 3. Architecture decisions

| # | Decision | Choice | Why / alternative rejected |
|---|----------|--------|----------------------------|
| D1 | Capture | One global process tap (stereo mixdown, excluding our process), muted at source | Per-app taps = many libjamesdsp instances. Virtual driver = signing/install friction. |
| D2 | IO model | Tap + real output device in one private aggregate, **one IOProc** reads tap input, writes processed output | No ring buffer, no second clock. Drift correction handled by aggregate settings. |
| D3 | Language split | Audio plane in C; control plane in Swift | Swift on the audio thread risks ARC/allocation. |
| D4 | DSP instances | Double-buffered: active + standby instance. Re-init happens on a worker thread; swap pointer at buffer boundary | Avoids locks in the IOProc. Phase 0 audit (`docs/libjamesdsp-api.md`): the process call takes a blocking mutex around convolver/DDC/liveprog, IR load and liveprog compile hold it for their whole duration, and most setters change live state with no lock. So D4 is required, not optional. Also: call process with a constant frame count, and run one warm-up process call on the worker before swapping. |
| D5 | Param updates | Control thread publishes immutable param snapshot; IOProc applies if version changed | Lock-free. |
| D6 | Config | Linux `audio.conf` compatible parser/writer in Swift | Preset compatibility. |
| D7 | Project | XcodeGen `project.yml`, SwiftPM-style C targets | Text-only project files Claude Code can edit. |
| D8 | Min OS / arch | macOS 14.4, arm64 only | API since 14.2, AudioCap documents 14.4. Only Apple Silicon hardware available to test on, so no universal build. |
| D9 | Distribution | GitHub Releases, unsigned/ad-hoc signed zip or DMG, plus build-from-source instructions. No notarisation. | No paid Apple Developer account needed. Users approve the app once in System Settings. |
| D10 | Liveprog (EEL2) strategy | **Decided.** Keep liveprog in v1, in-process. Evidence so far suggests the engine is the portable (non-native) variant; if the Phase 1 grep confirms it, rung 1 is moot and no JIT entitlement is needed. Fallback ladder, time-boxed: (1) native arm64 EEL with `MAP_JIT` + `pthread_jit_write_protect_np`, app ad-hoc signed with hardened runtime + `allow-jit`; (2) if libjamesdsp's EEL has no working arm64 codegen, build the portable (non-JIT) EEL variant, accepting a slowdown; (3) if neither works within the time-box, ship v1 with liveprog hidden behind a feature flag. **No XPC helper in v1.** | An XPC helper means real-time audio over IPC (shared-memory ring, extra latency, a second clock domain) to protect one feature out of about twelve. The M1 Pro has headroom for a slower interpreter on modest scripts. |

## 4. Phases

Each phase ends with a **gate**. Do not start the next phase until the gate passes. Tick boxes as you go.

### Phase 0 — Recon and vendoring (no audio code)
- [x] Clone `Audio4Linux/JDSP4Linux` and `james34602/JamesDSPManager` into a scratch dir.
- [x] Decide which `libjamesdsp` to vendor. Default: the copy in JDSP4Linux (desktop-tested, float/planar). Record commit hash in `Vendor/libjamesdsp/UPSTREAM.md`.
- [x] Find and record libjamesdsp's licence and any third-party licences (EEL2/WDL, dr_libs, etc.). **Stop and report to the user** if anything is incompatible with GPLv3. Note: GitHub reports James Fung's `EEL_VM` repo (the EEL2 engine used by JamesDSP) as GPL-2.0. Check whether the file headers say "or later", because GPL-2.0-only is not compatible with GPLv3. JDSP4Linux ships as GPL-3.0-or-later with libjamesdsp inside, so it is likely fine, but verify.
  - **Result:** no file says "or later" because no file has a licence header at all; the repo has the bare GPLv2 text and a README saying "GPL". Decided with the user to treat it as "GPL, any version" under GPLv2 §9 and keep jdsp4mac GPLv3. See `docs/licences.md`.
- [x] Write `docs/libjamesdsp-api.md`: init/teardown, process call(s) and their buffer format, every `*SetParam`-style function, threading notes (what `JamesDSPGetMutexStatus` guards, whether the process call takes a lock), SIMD/asm/JIT usage.
- [x] Write `docs/dsphost-map.md`: table of every `audio.conf` key -> libjamesdsp call(s), derived from JDSP4Linux `DspHost.cpp`.
- [x] Skim FineTune's tap/aggregate code and AudioCap for patterns. Write `docs/coreaudio-notes.md` (do not copy code).
- [x] Scaffold: `project.yml`, empty targets, `.gitignore`, GPLv3 `LICENSE`.

**Gate:** the three docs exist, licence finding reported, `xcodegen && xcodebuild` builds an empty app.

### Phase 1 — Prove it (spikes)
1. **Offline spike.** Build libjamesdsp for arm64 as a C target. Write `Tools/jdsp-offline`: read WAV, run chosen effects, write WAV.
   - [x] Builds on Apple Silicon with no x86-only intrinsics leaking in. Fix portability issues at the root.
   - [x] **Liveprog / EEL2 (D10), time-boxed to a few focused sessions.**
     - [x] Step 0 (done in Phase 0; result in `docs/findings.md`: portable interpreter, no JIT, so go straight to rung 2): grep the vendored libjamesdsp EEL sources for `asm-nseel`, `glue_x64`/`glue_aarch64`-style files, `EEL_TARGET_PORTABLE`/`NSEEL_TARGET_PORTABLE`, `glue_port.h`, `mmap`, `mprotect`, `VirtualAlloc`, `MAP_JIT`, `__clear_cache`, `sys_icache_invalidate`. Write down what is found, with file and line references, in `docs/findings.md`. Do not rely on any chatbot's description of the engine, including earlier notes in this plan.
     - If it is the portable (non-native) variant: no executable memory is allocated, so skip rung 1 and the `allow-jit` entitlement. Just measure CPU on real scripts (rung 2) and move on.
     - Otherwise find out whether it has an arm64 code generator, then:
     - Rung 1: if it does, allocate its code memory with `MAP_JIT`, wrap code writes in `pthread_jit_write_protect_np(0/1)`, and compile only on the worker thread (never the audio thread). Sign the dev build ad-hoc or with the free dev cert, with hardened runtime and an `allow-jit` entitlements file. Run a few scripts from JDSP4Linux's examples for 10+ minutes.
     - Rung 2: if there is no arm64 codegen (or it crashes), build the portable (non-JIT) EEL variant and measure CPU on the same scripts.
     - Rung 3: if neither works inside the time-box, put liveprog behind a feature flag, hide it in the UI, and continue. Do not build an XPC helper.
     - Record the outcome and measurements in `docs/findings.md`.
   - [x] Golden checks: bypass is bit-exact; a 1 kHz sine through a +6 dB EQ band comes out ~+6 dB; sweep through reverb is stable (no NaN/Inf).
2. **Live passthrough spike.** Minimal C code: create global tap (exclude self), private aggregate with the default output device, IOProc copies input to output.
   - [x] `NSAudioCaptureUsageDescription` set; permission prompt appears on first IO start. (Observed: it blocks `AudioDeviceCreateIOProcID`.)
   - [x] Detect zeroed-buffer state (sustained exact zeros while other processes are running) and log it. (Logged, but false-positives: `com.apple.CoreSpeech` keeps output running while silent. Phase 2 needs a better signal.)
   - [x] Original app audio is muted at source and heard only through us. (Human check: not doubled, no feedback, headphones and speakers.)
3. **Live DSP spike.** Insert libjamesdsp (EQ only) between input and output in the IOProc via planar conversion with preallocated scratch.
   - [x] Done: FIR EQ in the IOProc, +5.0 dB measured at the 100 Hz node; 20 ms bypass crossfade; IOProc compiled with `nonblocking` effect checks.

**Gate (automatic):** 30 minutes at 44.1 and 48 kHz with 0 underruns/xruns counted by the IOProc; added latency measured and recorded; IOProc CPU under a threshold the user agrees (record the number in `docs/findings.md`).
- Result (2026-10-19): 0 discontinuities and 0 overloads in 30 min at each rate; added latency 24.4 ms (48 kHz) / 26.6 ms (44.1 kHz); IOProc CPU about 1 %, longest callback 0.30 ms. Threshold agreed: ≤5 % average, no callback over 25 % of the buffer period. **Automatic gate passed.** Mostly silent input; see `docs/findings.md`.
**Gate (human listening, ask the user):** passthrough is transparent with effects off; EQ audibly works; no clicks when toggling bypass; no feedback howl.
- Result (2026-10-20): **passed** on wired headphones and built-in speakers. Noted for Phase 2: an audible gap when Stop tears down. Reverb tail is short, but that is upstream sndfilter behaviour (`docs/findings.md`).

### Phase 2 — Robust engine
- [x] Device-change handling: default output changes, headphones plug/unplug, Bluetooth, sample-rate change. Tear down and rebuild, restoring state. (Scripted gate passes for default-output switches, a vanishing output, rate changes and flapping. Headphones/Bluetooth: human checklist.)
- [x] Sleep/wake and app quit: always destroy tap + aggregate (including on SIGTERM). On launch, sweep any leftover aggregate devices we created (tag them with a recognisable name/UID prefix). **[verify]** with `kill -9` whether a dead process's private aggregate and muting tap survive at all: the SDK says private aggregates are not persistent across launches, while FineTune's comments say orphans leave apps muted. (Done: teardown on sleep, quit, SIGTERM/INT/HUP, crash signals; sleeping state ignores HAL events; wake rebuilds after 0.2 s. kill -9: relaunch works; private aggregates are invisible to other processes, so leftovers cannot be seen or swept from outside.)
- [x] Fade in on first audible buffer after rebuild (avoids pops).
- [x] Stop/teardown gap (heard in the Phase 1 listening check): measure it, fade out before destroying the tap, and keep the handover to direct playback short. (Done: 20 ms fade-out before teardown; make-before-break rebuilds with the old graph destroyed in the background. Human re-check 2026-10-20: plug-in gap gone.)
- [x] Permission state machine surfaced to the app: `unknown / granted / denied-or-zeroed`. (Done: waitingForPermission while the prompt blocks IOProc creation; a self-tap probe confirms or denies before the muting tap is built; permissionProblem state with the tap absent.)
- [x] Zero-buffer **watchdog**: if the IOProc sees sustained exact zeros while the system reports other processes rendering to the output device, do a full teardown and rebuild of tap and aggregate (not just the IOProc). Do not trigger on genuine silence. Rebuild also on output sample-rate change and Bluetooth state change. (Done: rebuild once; escalate to tap removal + permission problem only if no audio has ever been seen since launch. Rate-change rebuilds are handled by the change listeners. Tested with a simulated zero tap.)
- [x] Do not assume a steady callback stream: no callbacks at idle is normal. (We run with `tapautostart` off, so the IOProc runs continuously; a 3 s stall is treated as a fault and rebuilds.)
- [x] Start IO off the main thread with a timeout. If it does not start (another app's tap on the same device blocks `AudioDeviceStart`), show "another audio app is using system audio capture" instead of hanging. (All HAL lifecycle work on the engine queue; IOProc creation and start report "waiting" states after 1 s / 5 s.)
- [x] Output with more than 2 channels or non-float formats: pass through unprocessed, mark in status. (Implemented: no tap for such outputs, status "Not processing: …". Not exercised on hardware: this Mac has no such output.)
- [x] Add a "panic bypass": one call that unmutes the tap path (destroy tap) from any thread/signal. (`jd_panic()`, Panic button, SIGUSR1.)

**Gate:** unplug/replug headphones, switch output in System Settings, sleep/wake the Mac: audio always returns, no leaked aggregate devices (check with Audio MIDI Setup). Human confirms.
- Result (2026-10-20): **passed.** Scripted gate `Tests/phase2.sh` 35/35; human checklist (`docs/checklist-phase2.md`) and re-check passed on wired headphones, speakers and Bluetooth. Note: our aggregates are private, so Audio MIDI Setup cannot show them either way; leak handling is verified in-process instead (`docs/findings.md`).

### Phase 3 — Config and parameter plane
- [x] `Sources/Config`: parse/write `audio.conf` (key=value). Round-trip an existing Linux preset without loss. (Done: line-preserving; 29 real presets round-trip exactly.)
- [x] Implement every mapping from `docs/dsphost-map.md` in Swift, producing an immutable param snapshot. (Done: `DSPSettings` (Swift) → `JDParams` → `jd_dsp_build` (C) in DspHost order and clamps.)
- [x] Audit libjamesdsp threading (done in Phase 0, `docs/libjamesdsp-api.md`): the process call takes the internal mutex, and setters race with it. Decision: D4, never call setters on the live instance.
- [x] Two-stage convolver: the audio thread waits on a condvar for a normal-priority worker thread (`TwoStageFFTConvolver.c`). Measure with long IRs and crossfeed mode 5; if it glitches, fix at the root (worker priority or forcing the single-stage path). (Done: it stalled the IOProc up to 7.9 ms; single-stage forced. Long-IR CPU cost recorded in findings.)
- [x] Heavy updates (convolver IR load, liveprog compile, GraphicEQ design, sample-rate change) go to the standby instance on a worker thread; swap at a buffer boundary. (Done: builder queue + lock-free hand-over + 40 ms crossfade; no clicks measured.)
- [x] Liveprog: compile errors are returned to the UI as messages, never crash the engine. (Done.)
- [x] Presets: save/load/list, per-output-device preset rules (mirrors Linux `--set-preset-rule`). (Done; rules in rules.json.)
- [x] One key-mapping table (our canonical keys = JDSP4Linux `audio.conf`) shared by every import/export format below. Read each app's source for its keys before writing a mapping; record the tables in `docs/preset-formats.md`. (Done: docs/preset-formats.md.)
- [x] Import JDSP4Linux presets (`.conf`/`audio.conf`, also foobar2000 `.jdsp`). Referenced files (convolver IR, DDC `.vdc`, liveprog `.eel`) are Linux paths: resolve by file name in our library folders, otherwise ask the user to locate them. Never fail silently. (Done.)
- [x] Export JDSP4Linux presets (`audio.conf` format, same key order and float formatting as `ConfigIO.cpp`). (Done.)
- [x] Import RootlessJamesDSP presets: `.tar` with metadata (`version`, `app_version`, `app_flavor`, `liveprog_included`, `min_version_code`) plus `dsp_*.xml` SharedPreferences and an optional bundled `liveprog` script (`model/preset/Preset.kt`, preset version 3). (Done; hand-made archives, then the user's real Rootless 1.6.14 preset `Prime.tar` imported exactly.)
- [x] Export RootlessJamesDSP presets in the same `.tar` layout, matching the metadata its loader checks, so Rootless accepts them. Verify by loading an exported preset in RootlessJamesDSP (human check, needs an Android device). (Done: an exported preset loads in RootlessJamesDSP on the user's Android phone, 2026-10-20.)
- [x] Import original JamesDSP for Android (root) presets: a folder of SharedPreferences XML (`james.dsp.speaker.xml`, `headset.xml`, `bluetooth.xml`, `settings.xml`; `DSPManager.java:476-`). Ask which profile (speaker/headset/bluetooth) to import. Import only; no export (legacy, root-only app). (Done; tested with a hand-made file.)
- [x] Settings the target format cannot express are reported on export (no silent drops). (Done.)

**Gate:** load a real Linux preset, hear the same settings applied; changing any parameter while audio plays causes no glitch (human check on reverb, convolver, liveprog).

**Gate result (2026-10-20): passed.** Scripted gate `Tests/phase3.sh` 17/17, re-run after the last two fixes: 17/17, 0 discontinuities, 0 overloads, max IOProc 1.93 ms. Human checklist: a real RootlessJamesDSP preset imported, loaded and applied, and the per-output rule worked; live changes to EQ, reverb, convolver, liveprog (including a broken script) and the master switch had no clicks or dropouts. Two gaps found and fixed along the way: a Defaults button (there was no way back from a loaded preset), and reloading a liveprog script, IR or DDC file when it is saved. Details in `docs/findings.md`.

### Phase 4 — UI (menu bar first, FineTune-inspired)

The app is a menu bar app. Day-to-day use happens entirely in a popup panel; a separate settings window only holds things that do not fit in the panel.

**Design reference:** FineTune (GPLv3, open source). Take its structure and interaction ideas, not its code or image assets. What FineTune does that we borrow (from its README and screenshots):
- One popup panel hanging off the menu bar icon, with a vertical list of rows. Each row has a name, a control, and expands inline into a detail panel (FineTune expands a per-app row into its EQ panel).
- An output device row at the top with a picker popover.
- Keyboard-drivable popup: up/down to move between rows, left/right to adjust the focused control, Return/Space to activate, Esc to close. A bindable global hotkey to open/close the popup is optional.
- A menu bar icon that reflects state. FineTune offers several icon styles; we only need one SF Symbol with three states (on, bypassed, permission/engine problem).
- Follows system light/dark appearance.

**Panel layout (top to bottom):**
1. Header: master on/off toggle, bypass toggle, one-line status (running / bypassed / permission needed / device unsupported).
2. Output device row: current device and picker. Shows a note if the device is multichannel and passed through.
3. Preset row: picker, save, rename. Per-device preset rule shown as a small badge when active.
4. Effect rows, each with an enable toggle and one primary control, expanding inline for details:
   - Bass boost, Compander, Reverb (preset + size/decay), EQ (FIR bands; GraphicEQ/AutoEQ import), Convolver (IR picker, gain), Crossfeed, Stereo width, ViPER-DDC, Limiter, Liveprog (script list, enable per script).
5. Footer: settings gear, quit.

**Tasks:**
- [x] `MenuBarExtra` with the `.window` style for the panel. One SwiftUI view per effect row, shared row/expander components. (Done: `Sources/App/Panel/`.)
- [x] Keyboard navigation and Esc to close. (Done: ↑/↓ rows, ←/→ inline control, Space switch, Return expand, Esc close. Human check.)
- [x] Menu bar icon with the three states. (Done: the brand sheet's glyph as a template image.)
- [x] Settings window (small): Liveprog editor (plain text + error output; syntax highlighting is optional), AutoEQ file import, per-device preset rules, launch at login (`SMAppService`), hotkeys if implemented. (Done; no hotkeys.)
- [x] AutoEQ: import `GraphicEQ`/ParametricEQ text files. (Done; parametric converted with RBJ biquads, checked in findings.)
- [x] AutoEQ download: search headphone models and fetch their GraphicEQ into the arbitrary-response EQ (`graphiceq_param`). Source: decide in Phase 4 between the AutoEq project's published results on GitHub (no third-party server) and ThePBone's AutoEqApi (`aeq.timschneeberger.me`, what JDSP4Linux and RootlessJamesDSP use). Check the data licence and the service's terms first. Network access only on explicit user action; cache downloaded profiles; show the source and the measurement rig/target in the UI. (Done: AutoEq's published results on GitHub, MIT; decision and reasons in findings.)

**Visual skin:** structure from FineTune, identity from the user's jdsp4mac brand sheet (`Claude Design Branding/`, decided 2026-10-21; tekkiech.tech is not used): macOS system palette and SF fonts, the lowercase wordmark, the app icon and the three-state menu bar glyph. Native controls. No generic template look. Do not build a custom control toolkit.

As built: the header holds the power switch (start/stop capture, remembered across launches); the bypass is the Output row's switch, which is `master_enable` (so it is saved in presets, as on Linux).

**Gate:** user can run a full session using only the menu bar panel. Human review of look and feel on the M1 Pro screen, light and dark.

**Gate result (2026-10-21): passed.** The user ran the Phase 4 checklist on the M1 Pro: a full session from the panel (power, output picker including Bluetooth, presets and per-output rules, every effect row), keyboard navigation, Settings (AutoEQ search and Apply, GraphicEQ and ParametricEQ import, liveprog editor, open at login), sleep/wake, light and dark. Fixed during review: liveprog errors that stayed after the fix, the keyboard outline showing without keyboard use, a needless scroll bar, notices that never faded, and poor contrast on the transparent menu bar glass. Scripted gate `Tests/phase3.sh` 18/18 after the changes.

### Phase 5 — CLI and automation (small)
- [x] `jdspctl` mirroring the Linux CLI: `--get/--set key=value`, `--load-preset`, `--list-presets`, `--status`, `--list-devices`. IPC via a local XPC/distributed notification or Unix socket (pick the simpler). (Done: all of JDSP4Linux's remote options except `--relink`. Simpler than any IPC: settings, presets and rules are files the app already watches; status is a `status.json` the app keeps current. Gate `Tests/phase5.sh` 19/19, 2026-10-21.)
- [ ] ~~URL scheme for Shortcuts/Raycast~~ Not built (2026-10-21): Shortcuts ("Run Shell Script") and Raycast (script commands) can call `jdspctl` directly, so a URL scheme would duplicate it.

### Phase 6 — Ship on GitHub (no notarisation)
- [x] Signing for local development: sign with a free "Apple Development" certificate (Xcode > Settings > Accounts, personal team) so the audio-capture permission grant survives rebuilds. Verified 2026-10-19/20: ad-hoc builds re-prompt after every rebuild; Apple Development-signed builds keep the grant across rebuilds. Needs the WWDR G3 intermediate in the keychain. Set up via the gitignored `xcconfig/Signing.local.xcconfig`. (Done in Phase 2.)
- [x] Release builds: ad-hoc signed. Use whatever Phase 1 settled for liveprog (D10): if rung 1, sign with hardened runtime and an entitlements file containing `com.apple.security.cs.allow-jit`; if rung 2 or 3, no JIT entitlement is needed. Confirm the signed release build still runs liveprog. (Done: liveprog is rung 2, the interpreter, so no hardened runtime or JIT entitlement. The ad-hoc Release build runs liveprog: Release `jdsp-offline bench-liveprog` ok; in the app: human check.)
- [x] `scripts/build-release.sh`: builds arm64 Release, zips the `.app` (or makes a DMG). Ship `jdspctl` inside the bundle (e.g. `Contents/MacOS/jdspctl`) and document a symlink into the PATH. (Done: zip + sha256, 2.7 MB.)
- [x] GitHub Actions on an Apple Silicon macOS runner: build, run the golden checks from Phase 1, attach the zip/DMG to a GitHub Release on tag. (Written: `.github/workflows/build.yml`. Not run yet: no GitHub remote. **[verify]** on first push that the runner's Xcode supports `-Wfunction-effects` and Swift 6.)
- [x] README: install steps for an unnotarised app (download, move to Applications, open it once, then approve it under System Settings > Privacy & Security > Open Anyway; Control-click > Open no longer works since Sequoia; alternative is `xattr -dr com.apple.quarantine /Applications/jdsp4mac.app`; **[verify]** the exact flow on macOS 27.0.1), the audio-capture permission steps, build-from-source steps (`xcodegen && xcodebuild`), the "another tap-based app running" limitation, and the tested-on line (macOS 27.0.1, M1 Pro). (Done; install flow confirmed by the user on macOS 27.0.1: "Not Opened" dialog → Done → Privacy & Security › Open Anyway → Open Anyway again → Touch ID.)

**Gate result (2026-10-21): passed**, except CI, which runs on the first push to GitHub. The user installed the release zip as a downloaded (quarantined) file on macOS 27.0.1, approved it, allowed audio recording, and confirmed processing, liveprog, AutoEQ search/Apply and the bundled `jdspctl --status`.

### Stretch (only if asked)
Update feed: waits until the GitHub repo exists (user, 2026-10-21); then a "new version available" check against its Releases. (Online AutoEQ moved into Phase 4 on 2026-10-20.)

**Per-app exclusion** (asked for 2026-10-21). Excluded apps are left out of the tap, so they play directly and unprocessed (e.g. calls, a DAW).
- [x] Engine: excluded bundle IDs → their audio process objects (`kAudioProcessPropertyBundleID`, also matching helpers `<id>.*`), plus our own process, form the tap's exclusion list. Follow `kAudioHardwarePropertyProcessObjectList` as apps start and quit. Change the live tap through `kAudioTapPropertyDescription` (the header says it can be set on an existing tap); **[verify]** it takes effect without a gap or discontinuity, otherwise rebuild. `CATapDescription.bundleIDs` exists only from macOS 26, so not used. (Done: the live description change works, about 1–10 ms, no rebuild, no discontinuity. `Tests/exclusion.sh` 8/8.)
- [x] Settings: an "Apps" tab listing excluded apps; add from apps currently playing audio or by choosing an .app; remove. (Done.)
- [x] Known limit to check: apps whose audio comes from a process with another bundle ID (Safari plays through `com.apple.WebKit.GPU`) cannot be singled out by bundle ID. (Documented in the Apps tab and README; not worked around.)
- [x] WebKit apps (asked 2026-10-21): match a process also by the app *responsible* for it (each app has its own `com.apple.WebKit.GPU` process; probe on macOS 27: every GPU process maps to its host app). Uses the private `responsibility_get_pid_responsible_for_pid`, looked up with `dlsym`; without it, matching falls back to bundle IDs. Gate: scripted, a throwaway app with a WKWebView playing a tone is excluded by its bundle ID (its GPU process leaves the tap) while another player stays in; human: Safari excluded alone. (Done: `Tests/exclusion.sh` 11/11.)

**Gate:** scripted: two players with their own bundle IDs play different tones; excluding one removes it from the tap input (and it keeps playing), the other is still processed, no discontinuities or overloads; quitting and relaunching the excluded player keeps it excluded; removing the exclusion brings it back. Human: exclude a real app and hear it unprocessed while others are processed.

**Gate result (2026-10-21): passed.** `Tests/exclusion.sh` 11/11 (including a WebKit app). The user confirmed by ear: excluded apps (including Safari and the Search browser) play without effects while others keep them, across app relaunches; the Apps tab now lists apps as they start using audio.

Removed permanently (user, 2026-10-21): AUv3 wrapper, Intel/universal build, notarised releases. Do not propose them again; they stay non-goals (see the non-goals above, D8, D9).

## 5. Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| EEL2 is the portable interpreter (confirmed Phase 0); may be too slow for heavy scripts | Medium | Medium | Phase 1 CPU measurement on real scripts (D10 rung 2), then liveprog off in v1 if needed (rung 3). |
| libjamesdsp licence conflicts with GPLv3 (checked Phase 0: unversioned GPL, taken as any version) | Low | High | Fallback: relicense our code GPL-2.0-or-later. Copy no GPLv3-only code so that stays possible. |
| libjamesdsp internal mutex blocks the IOProc (confirmed by Phase 0 audit) | High | High | D4 double buffering: only the IOProc touches the live instance. |
| Two-stage convolver: IOProc waits on a normal-priority worker thread | Medium | High | Measure in Phase 1/3; raise worker priority or force single-stage partitions. |
| Permission denied/missing yields silent zeros | High | Medium | Zero-buffer detection and UI state (Phase 1–2). |
| Muting tap left behind after crash = silent Mac | Medium | High | Panic bypass, signal handlers, launch-time sweep. |
| Device changes / sample-rate mismatches | High | Medium | Phase 2 rebuild logic; aggregate drift correction. |
| Tap goes silent (zeros) mid-session after rate/Bluetooth change | Medium | High | Zero-buffer watchdog and full tap+aggregate rebuild (Phase 2). |
| Another tap-based app (FineTune, SoundSource etc.) running on the same device blocks start | Medium | Medium | Timeout, clear status message, document in README. |
| macOS 27 behaviour differs from older docs and from model knowledge | Medium | Medium | Read current Apple docs and Xcode release notes before Phase 1; record observed behaviour in `docs/findings.md`. |
| Convolver CPU load at low buffer sizes | Medium | Medium | Measured in Phase 3: single-stage (decided 2026-10-20) costs CPU in proportion to IR length (5 s ≈ 13 %, 20 s ≈ 25 % IOProc time live, no dropouts). The 25 % per-callback limit applies to typical settings; show long-IR cost in the UI (Phase 4). Fallback: two-stage with a workgroup-joined RT worker. |
| Apple changes tap behaviour in a point release | Low | Medium | Keep tap code isolated in `AudioCore`; record the macOS version tested in `docs/findings.md`. |
| Unnotarised app is blocked or re-prompts for permission after each build **[verify]** | Medium | Low | Dev-sign with a free Apple Development cert; clear README steps for users. |
| Cannot verify audio quality without ears | Certain | Medium | Objective gates plus mandatory human listening checkpoints. |

## 6. Prerequisites on the user's side

- The user's 14" M1 Pro MacBook Pro (Apple Silicon) on **macOS 27.0.1** with the latest Xcode and Command Line Tools, plus `brew install xcodegen`.
- A free Apple ID added to Xcode for development signing. No paid Developer Program membership is needed.
- Someone to run the listening checklists at the end of Phases 1, 2, 3 and 4 (the user).

## 7. Open questions for the user (answer before Phase 1 ends)

**Decided:**
- Test machine: 14" M1 Pro MacBook Pro, macOS 27.0.1, latest Xcode. Deployment target stays 14.4, but only macOS 27.0.1 is ever tested. Say so in the README.
- Project name: `jdsp4mac`. A web search on 2026-10-19 found no existing project with this name (only unrelated "J-DSP"/"JDSP" projects). GitHub's own search could not be queried, so check `github.com/search?q=jdsp4mac` and that the repo name is free when you create it. Bundle ID suggestion: `tech.tekkiech.jdsp4mac`.

- Liveprog / EEL2: decision D10 above (in-process, fallback ladder, no XPC helper in v1).

**Still open:** none.

## 8. Sources

- Apple: Capturing system audio with Core Audio taps — https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- Apple: AudioHardwareCreateProcessTap — https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- Apple: aggregate device settings (sample rate, drift correction) — https://support.apple.com/guide/audio-midi-setup/ams094c7edb4/mac
- AudioCap (reference sample) — https://github.com/insidegui/AudioCap
- catap (tap behaviour, zeroed buffers when permission missing) — https://pypi.org/project/catap/
- "2000 buffers of nothing" (TCC/permission pitfalls, exclude self) — https://dev.to/nickdelv/2000-buffers-of-nothing-3i8
- Mimir write-up (tap + aggregate, recreate on device change) — https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp
- Apple Developer Forums: tap + muted + private aggregate + IOProc on macOS 27.0; two-tap interference — https://developer.apple.com/forums/thread/848578
- Apple Developer Forums, Core Audio tag (zeroed buffers, rebuild workaround) — https://developer.apple.com/forums/tags/core-audio
- Apple Developer Forums, Core Audio Types tag (multi-pair attenuation) — https://developer.apple.com/forums/tags/core-audio-types
- Opening unnotarised apps (Sequoia and later) — https://inventivehq.com/knowledge-base/macos/mac-developer-cannot-be-verified-fix ; https://docs.godotengine.org/pl/stable/tutorials/export/running_on_macos.html
- Fader case study (crash-safe cleanup) — https://hatimelhassak.is-a.dev/work/fader
- Fabar comparison table (taps vs drivers) — https://awesome.ecosyste.ms/projects/github.com%2Fgigaptera%2Ffabar
- FineTune — https://github.com/ronitsingh10/FineTune ; v1.8.0 notes — https://sourceforge.net/projects/finetune.mirror/files/v1.8.0/
- JDSP4Linux — https://github.com/Audio4Linux/JDSP4Linux ; releases — https://github.com/Audio4Linux/JDSP4Linux/releases
- JDSP4Linux backend architecture (DeepWiki) — https://deepwiki.com/Audio4Linux/JDSP4Linux/2.2-audio-backend-integration
- JamesDSPManager (libjamesdsp origin) — https://github.com/james34602/JamesDSPManager
- RootlessJamesDSP commit showing init/compander calls — https://github.com/timschneeb/RootlessJamesDSP/commit/f70c836209be160262528928d30b3773bf068318
- Foobar2000-JamesDSP (libjamesdsp in an IPC host process) — https://github.com/ctzjj/Foobar2000-JamesDSP
- jsusfx (EEL2 native ARM / x86 on OS X note, portable build about 10x slower) — https://github.com/Sneffel/jsusfx
- Apple Developer Forums: `allow-jit` with ad-hoc signing; MAP_JIT necessary but not sufficient on Apple silicon — https://developer.apple.com/forums/thread/764282
- macOS JIT memory overview (hardened runtime, MAP_JIT, entitlements) — https://www.outflank.nl/blog/2026/02/19/macos-jit-memory/
- EEL_VM (James Fung's EEL2 engine; file list and GPL-2.0 licence) — https://github.com/james34602/EEL_VM
- Building EEL2 from WDL — https://www.neilbickford.com/blog/?p=1113
