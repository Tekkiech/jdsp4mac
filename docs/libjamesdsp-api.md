# libjamesdsp API (vendored copy)

Source: `Vendor/libjamesdsp/jamesdsp/jdsp/` (JDSP4Linux `3ea7d73`, see `Vendor/libjamesdsp/UPSTREAM.md`). Paths below are relative to that directory. Read from source on 2026-10-19; nothing here has been run yet.

The whole API is `jdsp_header.h`. There is one state struct, `JamesDSPLib` (`jdsp_header.h:501-575`), which the caller allocates and owns. Everything else is a free function taking `JamesDSPLib *`.

## Lifecycle

| Call | Where | What it does |
|------|-------|--------------|
| `JamesDSPGlobalMemoryAllocation()` | `jdspController.c:228` | Process-wide: `NSEEL_start()` (EEL tables). Starts a benchmark thread only if built with `JAMESDSP_REFERENCE_IMPL` (JDSP4Linux does not define it). Call once per process. |
| `JamesDSPInit(jdsp, blockSizeMax, sampleRate)` | `jdspController.c:1036` | `memset`s the struct, inits `m_in_processing`, mallocs `tmpBuffer`, constructs every effect (all disabled), decodes and resamples the built-in HRTF/crossfeed FLAC blobs (`JamesDSPRefreshBlob`, `:949`). Heavy and allocating. JDSP4Linux calls `JamesDSPInit(dsp, 128, 48000)` then `JamesDSPSetSampleRate`. |
| `JamesDSPGetMutexStatus(jdsp)` | `:1160` | Returns `isMutexSuccess`, i.e. whether `pthread_mutex_init` succeeded in `JamesDSPInit`. That is all it reports. If 0, `jdsp_lock`/`jdsp_unlock` silently do nothing. |
| `JamesDSPSetSampleRate(jdsp, rate, forceRefresh)` | `:1164` | No-op if rate unchanged. Takes the lock, rebuilds ASRC, frees and mallocs `tmpBuffer`, re-decodes blobs; with `forceRefresh` re-designs every effect. Heavy, allocating. |
| `JamesDSPFree(jdsp)` | `:1226` | Takes the lock, frees everything, **destroys the mutex while holding it, then unlocks the destroyed mutex** (`:1228`, `:1257-1264`). Undefined behaviour; harmless only if nothing else touches the instance. Does not free `jdsp` itself. |
| `JamesDSPGlobalMemoryDeallocation()` | `:237` | `NSEEL_quit()`. |
| `JamesDSPReallocateBlock(jdsp, n)` | `:249` | Grows `tmpBuffer`. Called **from inside the process call** if `n > blockSizeMax`. |

## Process call and buffer format

There is no exported `JamesDSPProcess`. Processing goes through function pointers set in `JamesDSPInit` (`:1060-1070`):

```c
jdsp->processFloatDeinterleaved(jdsp, inL, inR, outL, outR, n);   // pfloat32, :881
jdsp->processFloatMultiplexd(jdsp, inLR, outLR, n);               // pfloat32Multiplexed, :909 (interleaved)
// also Int16, Int32, Int8_24, Int24Packed variants of both
```

- **Stereo only.** Exactly two channels; mono must be duplicated by the caller.
- **Float, non-interleaved (planar)** is the variant JDSP4Linux's PipeWire backend uses (`PwJamesDspPlugin.cpp:91`). Range ±1.0. `n` is frames.
- In and out may alias: input is copied into `tmpBuffer[0..1]` first, processed in place, then copied out.
- Order inside (`JamesDSPProcess`, `:313-371`): vacuum tube, compander, bass boost, FIR/IIR EQ, GraphicEQ (arbitrary response), **[lock]** convolver, DDC, liveprog **[unlock]**, crossfeed, stereo widener, reverb, then post gain and the output limiter (always on).
- **Block-size handling on the audio thread** (`:883-889`): if `n > blockSizeMax` it mallocs (`JamesDSPReallocateBlock`); if `n != blockSize` it calls `JamesDSPRefreshConvolutions(jdsp, 1)` (`:277`), which reloads the convolver IR and rebuilds crossfeed, GraphicEQ and EQ convolvers, all with malloc/free. That refresh is skipped only while `benchmarkEnable == 0` (`:280`); `JamesDSP_Load_benchmark` sets it to 1. **The IOProc must call with a constant `n`**, or treat a frame-count change as a rebuild on the worker thread.
- **First-buffer work**: `processInternal` starts as `JamesDSPProcessCheckBenchmarkReady` (`:372`). If benchmark data was loaded, the first call runs `JamesDSPRefreshConvolutions(jdsp, 0)` (allocating) and then switches to `JamesDSPProcess`. Run one warm-up process call on the worker thread before an instance goes live.
- **Internal resampling**: rates outside 44.1–48 kHz are resampled internally to 44.1 or 48 kHz (`:1074-1098`, polyphase ASRC + ring buffer), adding latency. At 44.1/48 kHz there is no ASRC.

## Setters

"Lock" = takes `jdsp_lock` (the same mutex the process call holds around convolver/DDC/liveprog). "Alloc" = mallocs or frees. "Unsafe while live" = mutates state the process call reads **without** holding the lock.

| Function | Params | Lock | Alloc | Unsafe while live |
|----------|--------|------|-------|-------------------|
| `JamesDSPSetPostGain(jdsp, dB)` | clamped −15..15 | no | no | trivially (one float) |
| `JLimiterSetCoefficients(jdsp, thresh_dB, release_ms)` | release ≥1.5 ms | no | no | two floats |
| `BassBoostEnable/Disable`, `BassBoostSetParam(jdsp, maxGain_dB)` | 0–15 dB | no | no | yes (filter state) |
| `CompressorEnable(jdsp, en)` / `Disable` | | no | via SetParam | yes |
| `CompressorSetParam(jdsp, timeconst, granularity, tfresolution, force)` | tfres 0 STFT, 1 CWT, 2 undersampled, 3 time domain | no | yes (`FFTCompanderInit`) | **yes** |
| `CompressorSetGain(jdsp, freq[7], gain[7], cpy)` | 7 bands | no | no | yes |
| `MultimodalEqualizerAxisInterpolation(jdsp, interp, mode, freq[15], gain_dB[15])` | interp 0 pchip, 1 makima; mode 0 FIR min-phase, 1–5 IIR order 4/6/8/10/12 | no | FIR: refreshes convolver IR | **yes** |
| `MultimodalEqualizerEnable(jdsp, en)` / `Disable` | | no | yes on force refresh | **yes** |
| `ArbitraryResponseEqualizerStringParser(jdsp, "GraphicEQ: f g; …")` | AutoEQ GraphicEQ string | no | yes | **yes** |
| `ArbitraryResponseEqualizerEnable(jdsp, en)` / `Disable` | | only around refresh | yes | partly |
| `Reverb_SetParam(jdsp, preset)` | `sf_reverb_preset` 0–18 | no | no | yes |
| `sf_advancereverb(&jdsp->reverb, fs, osf, …17 floats)` | called directly by JDSP4Linux (`DspHost.cpp:322`) | no | no | **yes** |
| `ReverbEnable/Disable` | | no | no | flag only |
| `StereoEnhancementSetParam(jdsp, mix)` | 0..1 | **yes** | no | no (locked, but process is outside the lock) |
| `StereoEnhancementEnable/Disable/Refresh` | | Refresh locks | no | flag only |
| `VacuumTubeEnable` / `Disable`, `VacuumTubeSetGain(jdsp, dB)` | −3..12 dB; Enable re-inits state | no | no | yes |
| `CrossfeedEnable(jdsp, en)` | rebuilds HRTF convolvers | **yes** | yes | **yes**: crossfeed processing runs outside the lock (`:343`), so this frees convolvers the audio thread may be using |
| `CrossfeedChangeMode(jdsp, mode)` | 0–1 BS2B, 2–4 HRTF, 5 long HRTF | no | no | yes |
| `BS2BInit(&jdsp->advXF.bs2b[i], fs, fcut \| feed<<16)` | written directly by JDSP4Linux (`DspHost.cpp:494-496`) | no | no | yes |
| `DDCStringParser(jdsp, vdcText)` / `DDCEnable(jdsp, en)` / `Disable` | ViPER `.vdc` text | Parser locks | yes | Enable: no lock |
| `Convolver1DLoadImpulseResponse(jdsp, irInterleaved, ch, frames, updateOld)` | ch 1, 2 or 4 (true stereo); returns 1 or −2 | **yes, for the whole IR build** | yes | no |
| `Convolver1DEnable/Disable` | | no | no | flag only |
| `LiveProgStringParser(jdsp, eelSource)` | needs `@init` and `@sample`; returns 1, 0, −1, −2, −3 (`checkErrorCode`) | **yes, including compiling and running `@init`** | yes | no |
| `LiveProgEnable/Disable` | | no | no | flag only |
| `JamesDSP_Load_benchmark(c0[10], c1[10])` / `JamesDSP_Start_benchmark()` | convolver partition cost tables (global) | no | Start runs ~20 s of FFTs | global state |

Helpers outside the core, in `Vendor/libjamesdsp/jdsp4linux-glue/` (JDSP4Linux, GPLv3): `ReadImpulseResponseToFloat(path, fs, info[2], optMode, waveEdit[6])` loads, resamples and edits an IR file (WAV/FLAC/MP3 via dr_libs) before `Convolver1DLoadImpulseResponse`; `ComputeEqResponse` etc. produce curves for UI plots; `setStdOutHandler` / `setPrintfStdOutHandler` capture EEL `printf` and library `printf`.

## Threading

- **What `JamesDSPGetMutexStatus` guards:** nothing by itself. It only reports whether `m_in_processing` was created.
- **What `m_in_processing` guards:** convolver, DDC and liveprog. The process call takes it around those three (`:330-341`). `Convolver1DLoadImpulseResponse`, `DDCStringParser`, `LiveProgStringParser`, `CrossfeedEnable`, `StereoEnhancementSetParam/Refresh` and `JamesDSPSetSampleRate` take it too.
- **The process call does take a blocking lock** (`pthread_mutex_lock`, not trylock). A worker loading an IR or compiling a liveprog script holds it for the whole build, so the IOProc blocks for that long. JDSP4Linux accepts this; we cannot (CLAUDE.md hard rule 1).
- **Most setters take no lock** while changing state the process call reads (EQ, GraphicEQ, compander, crossfeed mode, reverb, bass, tube). JDSP4Linux calls them from its control thread while PipeWire processes, which is a data race.
- **Two-stage convolver threads:** when `selectConvPartitions` picks the two-stage scheme (long IRs; also crossfeed mode 5), `TwoStageFFTConvolver*LoadImpulseResponse` spawns a pthread per convolver (`generalDSP/TwoStageFFTConvolver.c:346-417`). During processing, the audio thread hands the tail block to that thread with `task_start*` and later **waits on a condition variable** for it (`task_wait*`, `:86-125`, called at `:1136`, `:1413`, `:1714`, `:1979`). That worker is a normal-priority thread, so the IOProc can be blocked behind it (priority inversion).
- `NSEEL_HOSTSTUB_EnterMutex/LeaveMutex` are empty (`Effects/liveprogWrapper.c:1-2`).
- JDSP4Linux calls `jdsp_unlock` after `LiveProgStringParser` as a "workaround due to library bug" (`DspHost.cpp:763-764`). In this version every path of `LiveProgStringParser` already unlocks (`liveprogWrapper.c:97-146`), so that extra unlock releases a mutex the thread does not hold. Do not copy it.

**Consequence for jdsp4mac (confirms D4):** never call setters on the instance the IOProc is using. Build or modify a standby instance on a worker thread, run one warm-up process call there at the live block size, then swap the pointer at a buffer boundary. The IOProc's own instance is touched only by the IOProc. The remaining in-process hazards are the two-stage convolver's condvar wait (not avoidable by double buffering; measure in Phase 1, and if it glitches, raise the worker thread's priority or force the single-stage path) and the internal `m_in_processing` lock, which becomes uncontended once only the IOProc touches an instance.

## SIMD, assembly and executable memory

- libjamesdsp's own code is plain C. No intrinsics or inline asm outside the dr_libs headers.
- `dr_flac.h` / `dr_mp3.h` / `dr_wav.h` have guarded SSE2/SSE4.1 (x86) and NEON (arm64) paths and some guarded inline asm; they select NEON on `__aarch64__`. dr_wav's asm is x86_64-only (`dr_wav.h:1001`, `:1207`).
- **No executable memory.** No `mmap`, `mprotect`, `MAP_JIT`, `VirtualAlloc` or `PROT_EXEC` anywhere. EEL2 is the portable bytecode build. Evidence is in `docs/findings.md`.
- EEL numbers are `float` in this fork (`nseel_createCompiledValue(…, float value)`, `nseel-compiler.c:4760`), not WDL's `double`.

## Things to expect in Phase 1

- `TwoStageFFTConvolver.c` defines `inline void task_wait1x1(...)` etc. as non-static `inline` in a `.c` file (`:86-125`, `:419-462`). Under C99/C11 inline rules that provides no external definition, so clang at `-O0` may fail to link ("undefined symbol _task_wait1x1"). JDSP4Linux builds with `-std=gnu11 -O2`. **[verify]** by building; root fix is `static inline`.
- JDSP4Linux builds with `-Wno-error=incompatible-pointer-types -Wno-error=implicit-int -Wno-error=implicit-function-declaration` (`jdsp4linux-glue/libjamesdsp.pro:9`). Current clang makes these errors by default, so expect real fixes.
- Required defines from the `.pro`: `LIBJAMESDSP_PLUGIN`, `CUSTOM_CMD`, `printf=redirected_printf`, `ANDROID_LOG_INFO=0`, `DEBUG`. `jdspController.c:13` includes `PrintfStdOutExtension.h` (in the glue directory). `redirected_printf` calls `vasprintf`, which allocates; `DEBUG` turns on `__android_log_print` calls (`:162-164`, `:281-289`, `:1145-1150`), one of which (`:288`) runs inside `JamesDSPRefreshConvolutions`. Build without `DEBUG` and keep `printf` out of the audio path.
- EEL `@sample` code runs with a 32 KB bytecode stack array on the C stack (`glue_port.h:404-412`) per `NSEEL_code_execute`. Fine on a Core Audio IOProc thread, but note it.
