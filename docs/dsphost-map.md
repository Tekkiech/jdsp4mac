# audio.conf → libjamesdsp map

Derived from JDSP4Linux `3ea7d73`: `src/audio/base/DspHost.cpp` (`update()` at `:509`, helpers above it), key list `src/config/DspConfig.h` (`enum Key`), defaults `resources/assets/default.conf`, file I/O `src/config/ConfigIO.cpp`, enum labels `src/MainWindow.ui` and `src/data/PresetProvider.cpp`. Function behaviour (locks, allocation) is in `docs/libjamesdsp-api.md`.

This is a description for writing our own Swift mapping, not code to port (DspHost uses Qt and is GPLv3; we rewrite it).

## File format (`ConfigIO.cpp`)

- One `key=value` per line. Lines that are empty or start with `#` or `[` are skipped, as are lines with no `=`.
- Everything after the first `#` on a line is dropped as an inline comment (`:101`). So a file path containing `#` is truncated. Keep the behaviour for compatibility, but note it.
- Key and value are trimmed. `true`/`false` become booleans; everything else is a string, converted on read.
- String values are written with surrounding double quotes (`"..."`); `chopDoubleQuotes` strips them on read.
- Writer: floats with 5 decimals (`%.5f`), others as text. Key order is the map's (alphabetical), with an optional prefix line.
- Lists inside a value are `;`-separated.

## Key → call table

"Group refresh" means DspHost collects changed keys and calls the helper once after the loop (`DspHost.cpp:668-706`), in this order: reverb, convolver, liveprog, graphiceq, ddc, crossfeed, compander, stereowide.

| Key | Default | Type / range | libjamesdsp call(s) | DspHost ref |
|-----|---------|--------------|---------------------|-------------|
| `master_enable` | `true` | bool | none: host-level bypass (`SwitchPassthrough`; the PipeWire plugin `memcpy`s in→out) | `:629-631` |
| `master_postgain` | `0` | dB, lib clamps −15..15 | `JamesDSPSetPostGain(dsp, v)` | `:636-638` |
| `master_limthreshold` | `0` | dB, clamped to ≤ −0.09 | `JLimiterSetCoefficients(dsp, thresh, release)` (both keys read together) | `updateLimiter` `:129-155` |
| `master_limrelease` | `60` | ms, clamped to ≥ 0.15 (lib then ≥ 1.5) | same call | `:129-155` |
| `bass_enable` | `false` | bool | `BassBoostEnable` / `BassBoostDisable` | `:554-559` |
| `bass_maxgain` | `5` | dB 0–15 | `BassBoostSetParam(dsp, v)` | `:560-562` |
| `compander_enable` | `false` | bool | `CompressorEnable(dsp, 1)` / `CompressorDisable` | `:563-568` |
| `compander_timeconstant` | `0.22` | s, forced ≥ 0.22 | group refresh → `CompressorSetParam(dsp, tc, gran, tf, 0)` then `CompressorSetGain(dsp, resp, resp+7, 1)` | `updateCompander` `:248-279` |
| `compander_granularity` | `2` | int, forced ≥ 2 | same | same |
| `compander_time_freq_transforms` | `0` | 0 STFT, 1 CWT, 2 pseudo-multires (undersampling), 3 time domain zero latency | same | same |
| `compander_response` | `"95;200;400;800;1600;3400;7500;0×7"` | 14 doubles: 7 freqs (Hz) then 7 gains; else ignored with warning | same | same |
| `tone_enable` | `false` | bool | `MultimodalEqualizerEnable(dsp, 1)` / `MultimodalEqualizerDisable` | `:643-648` |
| `tone_eq` | 15 freqs then 15 zeros | 30 doubles: freq[15], gain_dB[15]; else ignored | `MultimodalEqualizerAxisInterpolation(dsp, interp, type, p, p+15)` (immediately, per key) | `updateFirEqualizer` `:157-197` |
| `tone_filtertype` | `0` | 0 FIR minimum phase, 1–5 IIR order 4/6/8/10/12 | same call | same |
| `tone_interpolation` | `0` | 0 pchip, 1 modified Akima (FIR mode only) | same call | same |
| `graphiceq_enable` | `false` | bool | group refresh → if on: `ArbitraryResponseEqualizerStringParser(dsp, param)` then `ArbitraryResponseEqualizerEnable(dsp, 1)`; else `ArbitraryResponseEqualizerDisable` | `updateGraphicEq` `:448-475` |
| `graphiceq_param` | `"GraphicEQ: 25 0; 40 0; …; 16000 0"` | AutoEQ/EqualizerAPO GraphicEQ string | same | same |
| `reverb_enable` | `false` | bool | `ReverbEnable` / `ReverbDisable` | `:600-605` |
| `reverb_osf` | `1` | int oversample factor | group refresh → `sf_advancereverb(&dsp->reverb, dsp->fs, osf, reflection_amount, finalwet, finaldry, reflection_factor, reflection_width, width, wet, lfo_wander, bassboost, lfo_spin, lpf_input, lpf_bass, lpf_damp, lpf_output, decay, delay/1000)` | `updateReverb` `:291-326` |
| `reverb_reflection_amount` | `0.3` | float | ↑ arg `ertolate` | ↑ |
| `reverb_finalwet` | `-9` | dB | ↑ `erefwet` | ↑ |
| `reverb_finaldry` | `-7` | dB | ↑ `dry` | ↑ |
| `reverb_reflection_factor` | `1.0` | float | ↑ `ereffactor` | ↑ |
| `reverb_reflection_width` | `0.7` | float | ↑ `erefwidth` | ↑ |
| `reverb_width` | `1.0` | float | ↑ `width` | ↑ |
| `reverb_wet` | `-8` | dB | ↑ `wet` | ↑ |
| `reverb_lfo_wander` | `0.3` | float | ↑ `wander` | ↑ |
| `reverb_bassboost` | `0.25` | float | ↑ `bassb` | ↑ |
| `reverb_lfo_spin` | `0.7` | float | ↑ `spin` | ↑ |
| `reverb_lpf_input` | `18000` | Hz (int) | ↑ `inputlpf` | ↑ |
| `reverb_lpf_bass` | `600` | Hz (int) | ↑ `basslpf` | ↑ |
| `reverb_lpf_damp` | `9000` | Hz (int) | ↑ `damplpf` | ↑ |
| `reverb_lpf_output` | `17000` | Hz (int) | ↑ `outputlpf` | ↑ |
| `reverb_decay` | `2.1` | s (rt60) | ↑ `rt60` | ↑ |
| `reverb_delay` | `0` | ms, divided by 1000 | ↑ `delay` | ↑ |
| `convolver_enable` | `false` | bool | group refresh → `ReadImpulseResponseToFloat(file, dsp->fs, info, optMode, waveEdit)` (glue), then if enabled: `Convolver1DDisable`, `Convolver1DLoadImpulseResponse(dsp, ir, info[0], info[1], 1)`, `Convolver1DEnable`; else `Convolver1DDisable` | `updateConvolver` `:328-446` |
| `convolver_file` | `""` | path to WAV/FLAC/MP3 IR (1, 2 or 4 ch) | same | same |
| `convolver_optimization_mode` | `0` | 0 original, 1 shrink, 2 minimum-phase + shrink | same (`convMode`) | same |
| `convolver_waveform_edit` | `"-80;-100;0;0;0;0"` | 6 ints; DspHost fallback `-80;-100;23;12;17;28` | same (`javaAdvSetPtr`) | same |
| `crossfeed_enable` | `false` | bool | `CrossfeedEnable(dsp, 1)` / `CrossfeedDisable` | `:581-586` |
| `crossfeed_mode` | `0` | 99 BS2B custom, 0 BS2B weak, 1 BS2B strong, 2 Out of head, 3 Surround 1, 4 Surround 2, 5 Joe0Bloggs realistic surround | group refresh → modes 99 and 0: zero `dsp->advXF.bs2b`, `BS2BInit(&dsp->advXF.bs2b[1], fs, fcut \| feed<<16)`, set `dsp->advXF.mode = 1` (mode 0 forces fcut 700, feed 65); other modes: `CrossfeedChangeMode(dsp, mode)` | `updateCrossfeed` `:477-502` |
| `crossfeed_bs2b_fcut` | `700` | Hz | used for mode 99 | same |
| `crossfeed_bs2b_feed` | `60` | 0.1 dB units (BS2B convention) | used for mode 99 | same |
| `ddc_enable` | `false` | bool | group refresh → if on and file readable: `DDCStringParser(dsp, fileText)`, `DDCEnable(dsp, 1)` (on failure `DDCDisable`); else `DDCDisable` | `updateVdc` `:199-246` |
| `ddc_file` | `""` | path to ViPER `.vdc` | same | same |
| `liveprog_enable` | `false` | bool | group refresh → `LiveProgDisable`, `LiveProgStringParser(dsp, fileText)`, read `NSEEL_code_getcodeerror(dsp->eel.vm)` and `checkErrorCode(ret)`, then `LiveProgEnable` or `LiveProgDisable` | `reloadLiveprog` `:714-790` |
| `liveprog_file` | `""` | path to `.eel` | same | same |
| `stereowide_enable` | `false` | bool | group refresh → `StereoEnhancementEnable` / `Disable`, then `StereoEnhancementSetParam(dsp, level/100)` | `updateStereoWide` `:281-289` |
| `stereowide_level` | `60` | 0–100 | same | same |
| `tube_enable` | `false` | bool | `VacuumTubeEnable` / `VacuumTubeDisable` | `:654-659` |
| `tube_pregain` | `200` | hundredths of a dB (÷100; lib clamps −3..12 dB) | `VacuumTubeSetGain(dsp, v/100)` | `:660-662` |

51 keys in total (`DspConfig::Key`), all listed above.

## Not driven by audio.conf

- **Benchmark data** for convolver partitioning: `JamesDSP_Load_benchmark(c0, c1)` from JDSP4Linux's app config (`BenchmarkCacheC0/C1`, `DspHost.cpp:91-127`), optionally `JamesDSP_Start_benchmark()` on a worker 30 s after boot. Our equivalent belongs in app settings, not presets.
- **Sample rate**: `JamesDSPSetSampleRate(dsp, rate, 0)` on stream setup (`PwJamesDspPlugin.cpp:72`).
- **Liveprog runtime extras**: variable listing/editing by poking `compileContext` tables directly, and freezing via `dsp->eel.active` (`DspHost.cpp:792-855`). Optional; not needed for v1.
- **Reverb presets** in the Linux UI fill the `reverb_*` keys (`PresetProvider::Reverb`); the library's `Reverb_SetParam` is not used.

## Notes for our Swift layer (Phase 3)

- Several Linux behaviours reach into `JamesDSPLib` fields directly (`dsp->advXF.bs2b`, `dsp->advXF.mode`, `dsp->reverb`, `dsp->fs`, `dsp->eel.vm`). Our C side should wrap these in small functions so Swift never touches the struct layout.
- DspHost applies changes key by key with no ordering guarantees beyond the group-refresh list. With D4 we instead build a whole standby instance from a complete snapshot, so ordering only matters inside one build. Apply in the order above to match Linux.
- `tone_eq` and `compander_response` with the wrong field count are silently ignored by Linux (warning only). Do the same on load, but surface it in the UI.
