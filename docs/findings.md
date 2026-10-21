# Findings

Observed facts, with evidence. Newest section last.

## Environment (2026-10-19)

- `sw_vers`: macOS 27.0.1, BuildVersion `26A434`. (The build string starts with 26, not 27; recorded as reported.)
- `xcodebuild -version`: Xcode 27.1, build `27A9275`.
- XcodeGen already installed at `/opt/homebrew/bin/xcodegen`.
- Hardware: 14" M1 Pro MacBook Pro, arm64.

## EEL2 / liveprog: portable bytecode interpreter, no JIT (Phase 1 step 0, done early)

Searched `Vendor/libjamesdsp/jamesdsp/jdsp/` (all `.c`/`.h`) on 2026-10-19.

| Pattern | Hits |
|---------|------|
| files `asm-nseel*`, `nseel-cfunc*`, `glue_x86*`, `glue_x64*`, `glue_aarch64*`, `glue_arm*`, `*.s`, `*.S`, `*.asm` | none. The only glue file is `Effects/eel2/glue_port.h` |
| `glue_port` | `Effects/eel2/nseel-compiler.c:28` `#include "glue_port.h"`, unconditional (no `#ifdef` choosing a native glue) |
| `EEL_TARGET_PORTABLE`, `NSEEL_TARGET_PORTABLE` | none (WDL uses these to pick the portable glue; this fork has only the portable one, so no switch is needed) |
| `mmap`, `mprotect`, `VirtualAlloc`, `VirtualProtect`, `MAP_JIT`, `PROT_EXEC`, `pthread_jit_write_protect_np`, `sys_icache_invalidate` | none |
| `__clear_cache` | `nseel-compiler.c:6306` and `:7714`, both inside `#ifdef __arm__` (32-bit ARM only; clang does not define `__arm__` for arm64, so this is dead code on Apple silicon) |

How the "code" is stored and run:

- `glue_port.h:1-` is WDL's portable glue: `DECL_ASMFUNC(x)` is empty and opcodes are an `enum { EEL_BC_NOP=1, EEL_BC_RET, … }` of bytecode instructions (101 `case EEL_BC_*` labels).
- Compiled code goes into blocks from `newCodeBlock` (`nseel-compiler.c:186`), which is `__newBlock_align(…, isForCode=1)` → `__newBlock` (`:4740-4758`), i.e. plain `malloc` into a linked list of `llBlock`s. No page permissions are changed.
- `NSEEL_code_execute` (`:7758-7763`) calls `GLUE_CALL_CODE(...)`, which in `glue_port.h:410-` is a C function: a `for(;;) switch (inst)` interpreter over that bytecode with a 32 KB local stack array (`EEL_BC_STACKSIZE`, `glue_port.h:404`).
- `glue_port.h` is byte-identical to the one in `james34602/EEL_VM` `284b3da`, which also has no `asm-nseel*`/`nseel-cfunc*` files.

**Conclusion:** the vendored EEL2 never generates or executes machine code. D10 rung 1 (MAP_JIT + `allow-jit`) does not apply, and no JIT entitlement is needed. We are on rung 2 by construction: measure CPU of real liveprog scripts in Phase 1.

Other EEL notes:

- Values are `float`, not WDL's `double` (`nseel_createCompiledValue(compileContext*, float)`, `nseel-compiler.c:4760`).
- `LiveProgStringParser` compiles **and runs `@init`** while holding `m_in_processing` (`Effects/liveprogWrapper.c:97-146`). See `docs/libjamesdsp-api.md` threading section.
- The EEL compiler can start its own pthreads for script-created threads (`nseel-compiler.c:3553-3557`) and has a `globalLocker` mutex (`:3604-3610`). Which EEL functions reach these, and whether any `@sample` built-in allocates, is a Phase 3 audit item.

## libjamesdsp threading (from source, see `docs/libjamesdsp-api.md`)

- The process call takes a blocking `pthread_mutex_lock` around convolver/DDC/liveprog (`jdspController.c:330-341`). IR load and liveprog compile hold that lock for their full duration.
- Most parameter setters take no lock while changing state the process call reads.
- The two-stage convolver makes the audio thread wait on a condition variable for a normal-priority worker thread (`generalDSP/TwoStageFFTConvolver.c:86-125`).
- Changing the frame count `n` between process calls triggers allocation and convolver rebuilds on the audio thread (`jdspController.c:883-889`, `:277-301`).

These confirm D4 (double-buffered instances, setters only on the standby instance) and add two requirements for Phase 1: call the process function with a constant frame count, and run one warm-up process call on the worker thread before swapping an instance in.

## Build and signing (Phase 0 scaffold, 2026-10-19)

- SDK: `MacOSX27.0.sdk`, SDK build `26A425`, from Xcode 27.1 (`27A9275`).
- `xcodegen && xcodebuild -scheme jdsp4mac -configuration Debug build`: **BUILD SUCCEEDED**. Product is `arm64` only, `LSMinimumSystemVersion` 14.4, `LSUIElement` true, `Signature=adhoc`. Launched it with `open`: the process starts and exits on an AppleScript quit. The menu bar item itself was not checked by eye.
- Warnings: `libtool: warning: 'AudioCore.o' has no symbols` (placeholder target, goes away in Phase 1), and xcodebuild's "Using the first of multiple matching destinations" note. Nothing else.
- `security find-identity -v -p codesigning`: **0 valid identities found**. Being signed into Xcode with an Apple ID does not create a certificate. To get an Apple Development certificate: Xcode > Settings > Accounts > select the Apple ID > Manage Certificates > + > Apple Development. Then put the team ID in `xcconfig/Signing.local.xcconfig` (untracked; template in `xcconfig/Signing.xcconfig`).
- Tap API is Objective-C (`CATapDescription`), so tap creation lives on the Swift side; see `docs/coreaudio-notes.md`.

## Phase 1.1: offline spike (2026-10-19)

**Build.** All 84 libjamesdsp `.c` files compile with Apple clang 21.0.0 (`clang-2100.3.34.2`), `-std=c11`, arm64, no extra `-Wno-error` flags. 17 warnings, all reviewed and benign: pointer-sign / const-discard mismatches, one unused-expression statement (`FFTConvolver.c:886`), and `-Wreturn-type` in `getOptimalDF` (`polyphaseFilterbank.c:55`, every reachable `m` returns). No x86 intrinsics are built for arm64. One real portability bug: non-static C99 `inline` helpers fail to link at `-O0` (prediction from Phase 0 confirmed). Fixed with `static inline`; see `Vendor/libjamesdsp/UPSTREAM.md`. The core library needs **none** of the JDSP4Linux glue files: `printf` is only redirected when `printf=redirected_printf` is defined, and the Android log calls compile out without `DEBUG`.

**Golden checks** (`Tests/golden.sh` → `jdsp-offline selftest`, block 512):

| Check | 44.1 kHz | 48 kHz |
|-------|----------|--------|
| All effects off vs input, 2 s noise at ±0.5 | bit-exact | bit-exact |
| FIR EQ, +6 dB node at 1 kHz, 1 kHz sine | +6.000 dB | +6.000 dB |
| IIR order 4, same node | +4.101 dB (designed +4.101) | +4.099 (designed +4.099) |
| IIR order 12, same node | +5.952 dB (designed +5.952) | +5.952 (designed +5.952) |
| Reverb (default.conf values), 4 s log sweep + 4 s silence | finite, tail −167 dB | same |

- The IIR modes place shelves at the midpoints between nodes, so a single +6 dB node only reaches +6 dB at high orders. The check compares the measured gain with the library's own designed response (`HSHOResponse`, the same curve JDSP4Linux plots), not with +6 dB.
- "Effects off" is bit-exact because the always-on limiter computes `threshold / envelope` = exactly 1.0 when the signal stays below threshold, and post gain 1.0 is exact. Host bypass (`memcpy`) is exact by construction.
- Reverb at 48 kHz (`jdsp-offline process sweep --reverb`): output RMS −7…−10 dBFS for a −9 dBFS sweep, 482 of 384 000 samples reach the limiter, 0.75 % CPU. The tail falls about 70 dB in the first second after the input stops, faster than the configured `reverb_decay=2.1` (RT60) suggests. The call is identical to JDSP4Linux's, so this is library behaviour; listen for it in the human check.

**Liveprog CPU (D10 rung 2).** `jdsp-offline bench-liveprog` on all 26 scripts JDSP4Linux bundles (`resources/assets/liveprog`, listed in `resources.qrc`), 48 kHz, block 512, 20 s stereo noise, one thread on the M1 Pro:

| Script | compile ms | CPU % of real time |
|--------|-----------:|-------------------:|
| stftDenoise | 1.4 | 9.62 |
| hadamVerb | 0.8 | 6.53 |
| pfb | 0.9 | 5.18 |
| polyphaseFilterbank | 0.9 | 3.66 |
| stftCentreBoost | 1.0 | 3.31 |
| stftCentreCut | 1.0 | 3.12 |
| dynamicbass | 1.0 | 3.11 |
| phaseshifter | 0.8 | 3.08 |
| metallic-reverb | 0.7 | 2.29 |
| autopeakfilter | 0.8 | 1.64 |
| the other 16 | 0.6–5.1 | 0.12–0.87 |

All 26 compile and produce finite output. The interpreter is fast enough: **liveprog stays in v1 on rung 2**, with no JIT and no entitlement. Script `printf` goes straight to C `printf` (the EEL stdout hook `writeCircularStringBuf` is not referenced in this build), which locks and allocates; on the audio thread it must be redirected to a lock-free buffer (Phase 3).

## Phase 1.2: live passthrough spike, first run (2026-10-19)

- **The audio-capture permission check blocks `AudioDeviceCreateIOProcID`**, not only `AudioDeviceStart`. First launch (ad-hoc signed, no prior grant): the main thread sat in `AudioDeviceCreateIOProcID` → `HALC_ProxyObject::SetPropertyData` → `mach_msg` (waiting on coreaudiod) for as long as the prompt was unanswered (`sample` of pid 10072). Clicking Allow on the audio-capture prompt released it. (I first read `UserNotificationCenter`'s PID as evidence that it had just launched; it had been running since 2026-10-14, so that was wrong.) So tap creation and aggregate creation succeed silently without permission, and the first call that waits is IOProc *creation* on an aggregate that contains a tap. Consequence: create the IOProc off the main thread too (Phase 2's "start IO off the main thread with a timeout" must cover IOProc creation), and show "waiting for permission" while it is pending.
- `tccd`/`coreaudiod` wrote nothing matching the app or `kTCCServiceAudioCapture` to the unified log (`log show` without private data).
- After Allow, the first `AudioDeviceStart` (same process, `tapautostart` off) failed after 30.8 s with `268451843` = `0x10004003` = `MACH_RCV_TIMED_OUT`: coreaudiod did not answer. Relaunching (permission already granted) started in 0.061 s. So the run during which permission is granted cannot be trusted to start; Phase 2 should treat a start failure right after a grant as "rebuild everything once".
- **Ad-hoc signing re-prompts after every rebuild** (resolves PLAN.md Phase 6 [verify]): a rebuilt Debug app blocked in `AudioDeviceCreateIOProcID` on a new prompt even though the previous build had been allowed. The grant follows the code hash, which changes on each ad-hoc build. A stable Apple Development signature is needed before Phase 2's iteration loop.
- With `tapautostart` **off**, the IOProc runs continuously at idle (940 callbacks in 10 s at 48 kHz / 512 = 93.75/s), delivering exact zeros. (The macOS 27 forum report that callbacks stop at idle applies to `tapautostart` on, or was a different setup; [verify] with it on.)
- Built-in output, 48 kHz: aggregate buffer 512 frames, tap 2 ch in one interleaved input buffer, output 2 ch in one buffer; output latency 70 + safety offset 74 frames, input latency 57 + safety offset 73 frames. Tap-input to output host-time delay in the IOProc: constant 24.396 ms = 1171 frames (about 2 × 512 + 144 output latency/safety).
- Passthrough with a −20 dBFS 440 Hz tone from `afplay`: input peak 0.100 = output peak 0.100, 0 discontinuities, 0 overloads, IOProc 0.014 % CPU, max 0.006 ms per callback.
- **Zeroed-tap detector false positive:** `com.apple.CoreSpeech` (pid 668) reports `kAudioProcessPropertyIsRunningOutput = 1` permanently while silent, so "another process is running output" does not mean audio is playing. The Phase 1 detector logs `ZEROED` whenever the Mac is quiet. Phase 2's permission state machine needs a different signal.
- The grant-then-timeout reproduced on the second prompt: in the process where Allow was clicked, `AudioDeviceStart` failed with `MACH_RCV_TIMED_OUT` after 60.0 s and `AudioHardwareDestroyAggregateDevice` then took another 60 s. A fresh launch of the same binary started in 0.038 s.

## Phase 1.3: live DSP spike (2026-10-19)

- EQ mode (FIR "V" curve, +5 dB at the 100 Hz node), 48 kHz / 512: a 0.100 peak 100 Hz tone from `afplay` came out at 0.178 = **+5.0 dB**, as designed. IOProc CPU 0.91 % of wall time (DSP included), max callback 0.20 ms of the 10.67 ms buffer period. 0 discontinuities, 0 overloads, 0 unprocessed callbacks (frame count was always 512).

## Phase 1 automatic gate (2026-10-19)

EQ mode (libjamesdsp FIR EQ running in the IOProc every callback) with bypass on, so the output was dry while the full DSP load ran. Built-in speakers, buffer 512, `tapautostart` off, ad-hoc Debug build (libjamesdsp and AudioCore at `-O2`). Each run ended with SIGTERM; the teardown destroyed the aggregate and tap with status 0. The output rate was set with `AudioObjectSetPropertyData(kAudioDevicePropertyNominalSampleRate)` and restored to 48 kHz afterwards.

| | 48 kHz | 44.1 kHz |
|---|---|---|
| Duration | 15:11:22–15:41:27 UTC (30 min 5 s) | 15:41:28–16:11:33 UTC (30 min 5 s) |
| Callbacks | 169 197 (expected 1805 s × 93.75 = 169 219) | 155 452 (expected 1805 s × 86.13 = 155 466) |
| Output / input sample-time discontinuities | 0 / 0 | 0 / 0 |
| `kAudioDeviceProcessorOverload` | 0 | 0 |
| Layout errors / unprocessed callbacks | 0 / 0 | 0 / 0 |
| IOProc CPU (busy / wall), range of 10 s readings | 0.95–1.05 % | 0.96–0.99 % |
| Longest callback | 0.302 ms of 10.67 ms (2.8 %) | 0.265 ms of 11.61 ms (2.3 %) |
| Tap input → output host-time delay | 24.396 ms (constant) | 26.553 ms (constant) |
| Output latency + safety offset (frames) | 70 + 74 | 65 + 74 |

The callback counts match the wall-clock expectation to within the first and last poll interval, so no IO cycles were skipped.

**Caveat:** the Mac was almost silent during both runs (54 callbacks with any non-zero input at 48 kHz, none at 44.1 kHz). The runs prove the IOProc and libjamesdsp keep real-time for 30 minutes at both rates. FIR EQ cost does not depend on the signal, so the CPU figure holds for music too. They do not show behaviour with real programme material; the listening checklist covers that.

**Added latency:** the measured tap-to-output delay is 24.4 ms at 48 kHz (about 2 buffers + output latency and safety offset), 26.6 ms at 44.1 kHz. That is the delay our path adds before the device's own output latency, which normal playback also has.

**CPU threshold (agreed with the user, 2026-10-19):** IOProc CPU at most **5 % average** (busy time / wall time) and no single callback over **25 % of the buffer period**. Phase 1 measured about 1 % and 2.8 %, so it passes.

## Phase 1 human listening check (user, 2026-10-20)

Same Debug build as the gate runs. Wired headphones (KZ Gale, 3.5 mm jack) and the built-in speakers.

| Item | Headphones | Speakers |
|------|-----------|----------|
| Passthrough identical to normal playback (level, noise, distortion, dropouts) | pass | pass |
| Not doubled or echoed (muted at source), no feedback even at high volume | pass | pass |
| EQ audible (bass and treble up), no distortion | pass | pass |
| Bypass toggle: no click, pop or dropout | no click heard; the user was unsure whether they noticed the change at all | pass ("perfect") |
| Reverb tail | dies out in under a second | same |

- **Stop leaves an audible gap**, on both outputs. Expected: Stop tears down the IOProc, aggregate and tap, and the tapped apps then reconnect to the device directly. Not a Phase 1 gate item; moved to Phase 2 (measure the gap, fade out before teardown, keep it short).
- **Reverb tail:** the short decay is upstream behaviour. Our `sf_advancereverb` decay maths (`Effects/reverb.c`, `decay0 = 10^(log10(0.237)/rt60)` and three siblings) is identical to the original sndfilter (`voidqk/sndfilter` `1e45029`, `src/reverb.c:739-743`), and JDSP4Linux passes `reverb_decay` straight through. So `reverb_decay` is not a true RT60 in this algorithm. Kept as is for preset compatibility with JDSP4Linux. (sndfilter is now 0BSD upstream; the vendored file's header still says MIT. Both are GPL-compatible.)

## Dev signing (2026-10-20)

- The user's Apple Development certificate (personal team) is issued by **WWDR G3**. Until the G3 intermediate was in the keychain, `security find-identity -v -p codesigning` listed the identity as invalid ("0 valid identities"), even though `security verify-cert` passed (it fetches missing intermediates; the identity check does not). The machine only had the old WWDR intermediate, which expired in 2023.
- Dev builds now sign with `Apple Development` via the gitignored `xcconfig/Signing.local.xcconfig`. Designated requirement: `identifier "tech.tekkiech.jdsp4mac" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[field.1.2.840.113635.100.6.2.1]`, with no hash in it.
- **The audio-capture grant survives rebuilds**: a rebuild whose CDHash changed (`ddd64a83…` → `32c40d76…`) started with no prompt and the tap delivered the −20 dBFS test tone (peak 0.100). Also observed: the *first* certificate-signed build did not prompt either (the previous grant was for the ad-hoc identity), and it also delivered real audio. Why TCC accepted it is not known; noted as observed.
- XcodeGen's generated Info.plist hard-coded `CFBundleShortVersionString` 1.0 and `CFBundleVersion` 1. They now come from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.

## Phase 2: engine robustness (2026-10-20)

**Root cause found: HAL listener queue must never be the busy engine queue.** First scripted run: after a default-output or sample-rate change, rebuilds failed with "cannot read tap format" (then "tap format not readable after 2 s" once a wait was added). Each failing build succeeded the moment a queued `kAudioHardwarePropertyDevices` notification was delivered. The listener blocks were registered on the engine's serial queue, which is blocked for the whole build; the new tap object only became usable in this process after the HAL had delivered its notifications to our listeners. With listeners on their own queue (forwarding to the engine queue), the same run had **0 failed builds, no tap wait, builds 0.072–0.107 s**.

**Scripted gate** (`Tests/phase2.sh`, built-in speakers, EQ mode with bypass, 23 checks, all pass): launch; switch default output to a public test aggregate wrapping the speakers (our engine unwraps single-output aggregates) and back; destroy the test aggregate while it is the default; 48 → 44.1 → 48 kHz; 12 rapid default switches; SIGUSR1 panic; SIGTERM; `kill -9` then relaunch; SIGABRT then relaunch. After each, a −20 dBFS tone from `afplay` must show ≥ 0.09 peak at tap input **and** output in the 1 s stats.
- 11 builds, mean 0.087 s, max 0.103 s. 8 teardowns: fade-out + IOProc stop mean 35.5 ms (max 49.4), aggregate destroy ~0 ms, tap destroy 1.8 ms. So a device-change rebuild costs about 0.13 s.
- 12 back-to-back default switches ending on the original device caused **0 rebuilds**: the 300 ms debounce plus the "is the graph still valid?" check absorbed them.

**Observations that shaped the tests:**
- Our private aggregate is **not visible to other processes** (`haltest devices` saw 0 `jdsp4mac-` devices while the engine ran). Audio MIDI Setup can therefore never show a leaked private aggregate, so leak checks must run inside our own process. After `kill -9`, the relaunched app's launch sweep found nothing, and capture worked normally.
- Public aggregates made by a process that exits immediately are unreliable: one vanished when its creating `haltest` exited, and destroys from short-lived processes did not always take effect (two test aggregates survived a "destroyed: 0"). `haltest serve` keeps one process owning them; created and destroyed from one long-lived process, everything behaved.
- A first test-script bug: log markers repeated across runs made `since()` match an earlier run's lines. Markers now include a per-run id.

**Not covered by the script** (no hardware for it, or needs a person): wired headphone jack, Bluetooth, sleep/wake, outputs with more than two channels or non-float formats (code path reviewed only, this Mac has no such device), the permission-denied path, and how the stop/rebuild gap sounds. These are in `docs/checklist-phase2.md`.
- **`com.apple.CoreSpeech` starts and stops its (silent) output.** In the zeroed-tap test, the process that tripped the watchdog was CoreSpeech (pid 668), not the `afplay` that was playing. So "a process started output and the tap stayed zero" is not proof of a denied permission. The watchdog now escalates (removes the tap, reports a permission problem) only if this process has **never** received non-zero tap audio since launch. Once audio has been seen, permission is confirmed, and a zero episode only causes one rebuild per minute, never removal. Both paths are covered by `Tests/phase2.sh` (29 checks, all pass) via a test-only zero-input switch (`--test-zero-input`, SIGUSR2).

## Phase 2 human checklist results and fixes (2026-10-20)

User results (wired KZ Gale headphones, built-in speakers, QCY ArcBuds over Bluetooth): headphone plug/unplug works, manual switching works, Bluetooth works with no crackle (44.1 kHz, output latency 1509 frames, drift compensation off), Stop gap "much shorter", no pop on Start, Panic and Quit fine. Three problems, all traced in `live.log`:

1. **Denied capture with music already playing → total silence.** First denied run: the watchdog caught it (Safari's `com.apple.WebKit.GPU` started output, zeros, one rebuild, tap removed, user heard music without EQ). Later denied runs: music was already playing before Start, so no process *started* output, the watchdog never fired, and the denied tap kept apps muted. **A denied tap still mutes apps while it is read** (`mutedWhenTapped`). Fix: a **permission probe** before the real graph whenever permission is not yet confirmed. A private, *unmuted* tap of this process only, a private aggregate, and an IOProc that plays a −100 dBFS 1 kHz tone and measures the tap. Granted: hears exactly 1.0e-5 in 0.18–0.22 s. Denied: exact zeros, reported after 0.63 s; we then never create the muting tap. Cross-checked once with the probe skipped while permission was denied: the main tap delivered only zeros as well.
2. **Headphone plug-in gap ≈ 1 s.** Every speakers → headphones switch logged `teardown: fade+IOProc 1122–1221 ms`: `AudioDeviceStop`/`AudioDeviceDestroyIOProcID` on the speakers blocked for about a second after macOS switched away from them, and the new graph waited for it. (Headphones → speakers: 40–80 ms.) Fix: make before break. The old graph is faded to silence, the new graph is built, and the old one is destroyed on a background reaper queue (22–28 ms there in the gate; the slow speaker case needs the physical jack to reproduce).
3. **Wake gap ≈ 1.5 s.** At sleep entry the engine tore down correctly, but a `kAudioHardwarePropertyDevices` notification 1 s later saw "no graph" and rebuilt while the Mac was going to sleep. On wake that graph had stalled (3 s stall rebuild), and the wake rebuild came 1 s after `didWake`. Fix: an explicit sleeping state that ignores HAL events until wake; wake rebuilds after 0.2 s.

Scripted gate after the fixes: **35/35** on the wired headphones (default output at the time), including: probe hears itself; denied capture detected with audio already playing and the muting tap never built; the new graph runs before the old one is retired; no rebuilds between the (posted) sleep and wake notifications.

**Human re-check after the fixes (user, 2026-10-20):** headphone jack plug/unplug "perfect" (the ~1 s gap is gone); sleep/wake "perfectly" (EQ back without the earlier ~1.5 s of unprocessed audio); permission denied via `tccutil reset` + Don't Allow: the panel showed the permission error **and** music kept playing without EQ, never silence. **Phase 2 gate passed.**

## Phase 3: config and parameter plane (2026-10-20)

**Settings changes while audio plays** (`Tests/phase3.sh`, 17 checks, all pass; built-in output, 440 Hz −20 dBFS tone): every change is built on a worker queue (0.03–0.12 s) and crossfaded in by the IOProc over 40 ms. Measured: EQ +6 dB node at 400 Hz → peak 0.100 → 0.189 and back to 0.100; 10 changes in 1 s → final value applied; `master_enable=false` → dry; liveprog ×0.5 script found by file name → 0.050; broken script → message, audio continues dry; real JDSP4Linux preset applied live. **Click detector** (largest output sample step ÷ peak must stay within a pure 440 Hz tone's slope ×1.4): no click on any EQ, rapid-change or liveprog switch. Whole run: 0 discontinuities, 0 overloads, 0 layout errors, 0 unprocessed buffers.

**Two-stage convolver stalls the IOProc → single-stage forced.** With libjamesdsp's default partitioning, a 5 s IR and crossfeed mode 5 (long HRTF) use `TwoStageFFTConvolver`: the audio thread waits on a condition variable for a normal-priority worker thread. Live the IOProc's longest callback reached **4.6 then 7.9 ms** of the 10.67 ms budget (offline it never showed, because nothing competes there). Fix: `JD_SINGLE_STAGE_CONVOLUTION` (vendored change, `UPSTREAM.md`), all work on the audio thread. Offline single-stage: 5 s IR 1.7 % CPU, worst block 0.33 ms; crossfeed mode 5 0.5 %, 0.17 ms.

**Long-IR cost live** (single-stage, M1 Pro, 48 kHz / 512): the IOProc's wall time is several times the offline cost at light load, and it grows sub-linearly with work: 5 s IR → ~2.2 ms worst callback (~13 % average), 20 s IR (4× the work) → ~4.0 ms (~25 % average), IR→IR crossfade 2.9 ms / 4.4 ms. **0 overloads or discontinuities in every case.** Sub-linear growth means the scheduler raises the core's speed as the load rises; at light load the IOProc runs on a slow core while still meeting its deadline. So long IRs exceed the Phase 1 CPU threshold (5 % average, 25 % per callback), which was set with the EQ only. Typical JamesDSP IRs (HRTF, rooms) are well under 2 s. A lower-CPU option for very long IRs is two-stage partitioning with its worker joined to the device's audio workgroup at real-time priority (not built).

**Settings file watcher:** copying a preset over `audio.conf` with `cp` (in-place write) was not noticed: a folder watcher sees renames (atomic saves), not content writes. Fixed by watching the file too (re-opened after each change).

**Output from scripts and the library:** EEL `printf` and libjamesdsp's own `printf` go to a lock-free ring (`Sources/JamesDSPGlue`), drained into the log and UI. EEL's file-writing built-ins and the HPA print routines still write to files a script opens; a script that does file I/O in `@sample` is the script's problem and cannot be made real-time-safe from outside.

**Presets:** 29 real JDSP4Linux presets round-trip exactly; all 25 build and render offline (0.03–0.15 s, ≤ 3.3 % CPU), missing IR/DDC files reported by name. Rootless export → import changes only what the format cannot hold (custom reverb → nearest preset, paths → names), each reported; the archive reads with the system `tar`, XML validates with `xmllint`. Hand-made Rootless (bsdtar) and Android files import with exact reverb-preset and tube-drive conversions.

**Decision (user, 2026-10-20):** keep single-stage convolution. The Phase 1 CPU threshold (≤ 5 % average, no callback over 25 % of the buffer) applies to typical settings; long impulse responses are allowed to cost more and their cost is documented above (5 s IR ≈ 13 % / 2.2 ms live, 20 s IR ≈ 25 % / 4 ms live, no dropouts). Two-stage partitioning with a workgroup-joined real-time worker stays an option if users need very long IRs cheaply.
- **First real RootlessJamesDSP preset** (user's `Prime.tar`, Rootless 1.6.14 F-Droid, preset version 3, liveprog bundled): imported with no notes; every value matches the archive (post gain +15 dB, bass 8 dB, crossfeed mode 2, GraphicEQ AutoEQ curve, reverb preset 16 → Plate low with decay 1.9 s, liveprog file pointing at the bundled `viper_dynamicbass.eel`, which was saved to the library). Missing keys took Rootless's defaults as intended.
- **Phase 3 checklist, section B (user, 2026-10-20):** EQ, reverb, convolver (synthetic 2.5 s room IR) and liveprog changes while music plays: no clicks or dropouts. Two gaps found and fixed: (1) loading a preset overwrites `audio.conf` and the panel had no way back, so a **Defaults** button now writes the stock `default.conf`; (2) saving an edited liveprog script did nothing until `audio.conf` changed, because only `audio.conf` was watched. `SettingsStore` now also watches the files the enabled effects refer to (liveprog, IR, DDC) and their folders, and asks the engine to rebuild with the same settings when one changes. Live: broken script → rebuild in < 1 s, "Syntax error" message, liveprog off, music continues; fixed script → back on; 0 discontinuities, 0 overloads, max callback 1.8 ms.
- **Rootless export on a device (user, 2026-10-20):** a preset exported as RootlessJamesDSP `.tar` loads in RootlessJamesDSP on the user's Android phone.

## Phase 4: UI (2026-10-21)

- **Branding:** the user supplied a Claude Design export (`Claude Design Branding/jdsp4mac brand.html`, a packed bundle). It defines a macOS-system palette and SF fonts (no custom colours), the lowercase "jdsp4mac" wordmark with a grey 4, an app icon (dark / light / tinted variants, simplified below 64 pt) and an 18 pt menu bar glyph in three states (processing, bypassed/stopped with a slash, problem with "!"). The glyph is drawn from that geometry as a template `NSImage` (`Sources/App/MenuBarIcon.swift`); the icon is rendered by `Tools/make-app-icon.swift` into the asset catalog (dark variant only for now).
- **Settings plumbing:** the panel edits a `DSPSettings` copy, applies it to the engine at once and writes `audio.conf` 0.2 s after the last change (only changed lines). The store records what it wrote, so its own watcher does not echo the change back. Preset save/load flush a pending write first; otherwise a pending UI write could revert a just-loaded preset.
- **AutoEQ source decision:** AutoEq's published results on GitHub (`github.com/jaakkopasanen/AutoEq`, MIT licence) rather than ThePBone's AutoEqApi (`aeq.timschneeberger.me`). Reasons: it is the upstream data AutoEqApi serves, it is hosted by GitHub instead of one person's server, and its layout is stable and machine-readable: `results/INDEX.md` lists every profile (8850 on 2026-10-21) as `- [Name](./source/rig/Name) by source on rig`, and each folder holds `<Name> GraphicEQ.txt`, which `graphiceq_param` takes as is. The measurements belong to their sources (oratory1990, crinacle, Rtings, …); we fetch on user action only, in a free GPL app, and show the source and rig with every profile. AutoEq's README now points normal users at autoeq.app; the results folder is still published and maintained. If the layout changes, the search fails with a visible error and file import still works.
- **ParametricEQ import:** RBJ biquads (PK, LSC, HSC) evaluated at 48 kHz on AutoEq's 127-point GraphicEQ grid, plus preamp. Exact at known points (peak gain at Fc = 6.000 dB, shelf asymptotes 6.498 / 0.000 dB, shelf midpoint 3.250 dB). Against AutoEq's own GraphicEQ for HD 600 (oratory1990): mean difference 0.48 dB; the largest differences (up to 7 dB above 16 kHz) are where AutoEq's 10-filter parametric fit does not follow its graphic curve, not converter error.
- **Network note:** in this environment IPv6 to raw.githubusercontent.com times out (curl -6: 8 s timeout; -4: 0.5 s), so URLSession took 6.6 s for the index where curl took 0.2 s. A network problem, not the app; the tab shows a spinner, and the index is cached for a week.
- **Snapshots without screen recording:** `--snapshot-panel <dir>` renders the panel and the settings tabs to PNGs from inside the app (`cacheDisplay`), so layout can be checked without the screen-recording permission. It must wait with `Task.sleep`, not `RunLoop.run`: a nested run loop inside a main-queue block cannot drain the main queue, so main-actor work (the index download) never resumed. Window vibrancy and the tab bar do not render in these snapshots.
- **Phase 4 review fixes (user, 2026-10-21):** (1) A fixed liveprog error stayed on screen: the engine kept one rolling message list and appended each build's notes, so nothing ever removed them. Build notes are now the live instance's *problems*, replaced by every build that goes live (logged as "problems cleared"); `Tests/phase3.sh` checks that saving a fixed script clears it. One-off messages (applied, saved, failed download) fade after 4 s, errors after 8 s; library printf output goes to Diagnostics only. (2) The row outline shows only after a key press and hides when the mouse moves. (3) The effect list had a fixed 404 pt height, a few points short of its content, hence a scroll bar that barely moved; it now takes its measured height and scrolls only if taller than the screen allows. (4) The scripted gate set the user's new per-output rule aside: a rule loads a preset over the test settings at launch (all levels wrong, 7 false failures).
- **Contrast on the menu bar glass (user, 2026-10-21):** the `MenuBarExtra` window's own material is very transparent on this macOS, so the backdrop set the contrast (dark mode over a light window: white and grey text became unreadable; light mode: lower rows faded). A `.thickMaterial` background behind the panel keeps its own appearance; confirmed readable in both modes by the user.
- **Phase 4 gate passed (user, 2026-10-21).** Everything on `docs/checklist-phase4.md` works, including ParametricEQ import (AutoEq's QCY HT07 Arcbuds file).

## Phase 5: jdspctl (2026-10-21)

- **Options** follow JDSP4Linux's `CliRemoteController.h` (`--is-connected`, `--status`, `--list-keys`, `--get-all`, `--get`, `--set`, `--list-presets`, `--load-preset`, `--save-preset`, `--delete-preset`, `--list-devices`, `--list-preset-rules`, `--set-preset-rule`, `--delete-preset-rule`). `--relink` (PipeWire) has no equivalent. Device ids are Core Audio UIDs; rule commands also accept the device name.
- **No IPC needed for control:** the app already watches `audio.conf` (including referenced script/IR/DDC files), and reads presets and `rules.json` when they are used, so `jdspctl` edits files and the running app follows (`--set` applied and heard in under a second). The same commands work while the app is not running.
- **Status:** the app writes `status.json` (pid, state, detail, output, format, problems) when what it shows changes, and removes it on quit or SIGTERM. `jdspctl` trusts it only if that pid is alive *and* is jdsp4mac (`proc_pidpath`), so a crash-stale file or a reused pid reads as "not running". Snapshot runs (`--snapshot-panel`) never write it.
- **Gate** `Tests/phase5.sh`: 19/19 (connect/status before, during and after, set/get, bypass via `master_enable` reflected in status and at the output, save/load/delete preset, rules on the current output, unknown keys rejected, edits while not running).

## Phase 6: release (2026-10-21)

- **Release build** (`scripts/build-release.sh`): arm64 only, `Signature=adhoc`, no hardened runtime, `LSMinimumSystemVersion` 14.4, version from `project.yml` or the tag, build number = commit count. Command-line build settings override the gitignored `Signing.local.xcconfig`, so a developer's Apple Development identity never ends up in a release. `jdspctl` is copied to `Contents/MacOS/` and signed before the bundle, so the bundle's seal covers it (`codesign --verify --strict` passes). Zip 2.7 MB.
- **Liveprog in Release:** rung 2 (interpreter) needs no JIT entitlement. Release `jdsp-offline`: selftest PASS; bench-liveprog stftDenoise 9.4 % CPU, dynamicbass 3.1 % (same as Debug at -O2). The release app launches (snapshot mode, which never starts capture).
- **CI** (`.github/workflows/build.yml`): first-party actions and `gh` only; newest Xcode on a `macos-26` runner. Unverified until the repo has a GitHub remote; the open question is whether that Xcode's clang knows `-Wfunction-effects` (AudioCore treats warnings as errors).
- **Permission per signature:** each release is ad-hoc signed separately, so macOS asks for the audio-recording permission again after an update (README says so).
- **Release install on macOS 27.0.1 (user, 2026-10-21):** the quarantined zip opens with "“jdsp4mac.app” Not Opened — Apple could not verify … is free of malware" (Done / Move to Bin). Privacy & Security › Open Anyway, a second Open Anyway dialog, then Touch ID. Then the audio-recording prompt (new for this signature). Processing, liveprog, AutoEQ and the bundled `jdspctl --status` all work. README matches this flow.

## Stretch: per-app exclusion (2026-10-21)

- **Live tap changes work:** setting `kAudioTapPropertyDescription` (the original `CATapDescription` with a new `processes` list) on the running tap takes effect in about 1–10 ms with no rebuild, no discontinuity and no overload; the excluded app keeps playing directly. `CATapDescription.bundleIDs` / `processRestoreEnabled` exist only from macOS 26, so we map bundle IDs to process objects ourselves (`kAudioProcessPropertyBundleID`, also `<id>.*` helpers) and follow `kAudioHardwarePropertyProcessObjectList`.
- **Watchdog:** an excluded app playing alone leaves the tap silent by design; the zero-tap watchdog now ignores excluded processes.
- **Test fixture:** a copy of `/usr/bin/afplay` in a throwaway `.app` with its own `CFBundleIdentifier`, ad-hoc signed with a matching identifier, reports that bundle ID to Core Audio. `Tests/exclusion.sh` (8/8) reads membership from the tap's input peak (A 0.1 + B 0.02: 0.12 vs 0.02). It needs no other audio playing: the first run read 1.0 because Safari (`com.apple.WebKit.GPU`) was playing.
- **WebKit:** Safari's audio comes from `com.apple.WebKit.GPU`, shared by all WebKit apps, so Safari cannot be excluded on its own (documented, not worked around).
- **Truncation is .attrib:** `: > file` (truncate in place) raises only a vnode attribute event; both file watchers (excluded-apps.txt, audio.conf and referenced files) now include `.attrib`.
- **One audio-recording grant per bundle ID:** allowing the installed ad-hoc release revoked the Apple Development-signed dev build's grant (same bundle ID, different signature), so the dev build sat in waitingForPermission. Debug builds are now `tech.tekkiech.jdsp4mac.dev` ("jdsp4mac dev") with their own grant; settings stay shared in Application Support.
- **WebKit apps (2026-10-21):** each app gets its own `com.apple.WebKit.GPU` process, and macOS records the app responsible for it (probe on 27.0.1: GPU processes owned by com.officecommun.search, the Share sheet, AirDrop, a Safari extension). Matching an excluded app now also accepts processes it is responsible for, via the private `responsibility_get_pid_responsible_for_pid` (looked up with `dlsym`; logged and skipped if absent), so Safari or the Search browser can be excluded without affecting other WebKit apps. Responsibility follows the launcher: an app started from a shell is attributed to the shell's app (Claude Code in the test), so `Tests/exclusion.sh` starts its WebKit fixture (`Tests/fixtures/WebPlayer.swift`) with `open`, as Dock/Finder do. Gate 11/11.
- **Per-app exclusion passed (user, 2026-10-21).** Everything on `docs/checklist-exclusion.md` works, including Safari and the Search browser. Fixed after review: the Apps tab now follows Core Audio's process list while open (an app that started using audio after the tab opened was missing).
