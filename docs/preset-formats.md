# Preset formats

Our canonical format is JDSP4Linux's `audio.conf` (51 keys, `docs/dsphost-map.md`). Every other format maps to and from it through the tables below. Sources read on 2026-10-20: JDSP4Linux `3ea7d73`, RootlessJamesDSP `60d25ae`, JamesDSPManager `5aed6a4`. RootlessJamesDSP pins libjamesdsp at `1b9f89db`, the same commit JDSP4Linux's copy was last pulled from, so the DSP is identical and only the settings layer differs.

## JDSP4Linux (`.conf`, `audio.conf`; foobar2000 `.jdsp` is the same text)

Native. Import keeps the file text exactly (`Sources/Config/AudioConf.swift`). Referenced files are Linux paths (`/home/<user>/.config/jamesdsp/{irs,vdc,liveprog}/<name>`): resolved by file name in our `irs/`, `vdc/`, `liveprog/` folders; anything missing is listed, never silently dropped. Export writes the same format.

## RootlessJamesDSP (`.tar`)

Container (`utils/storage/Tar.kt`, `model/preset/Preset.kt`): an uncompressed tar with
- `dsp_<group>.xml`: Android SharedPreferences files (`<map><boolean|float|int|long|string name=… value=…/></map>`), one per effect group;
- `liveprog`: the selected liveprog script, if any (metadata `liveprog_included=true`);
- `metadata`: `key=value` lines: `version=3`, `app_version`, `app_flavor`, `liveprog_included`, `min_version_code=26`.

Rootless's loader rejects backups (`is_backup=true`) and files whose `min_version_code` is above its own version code; it copies every `dsp_*.xml` into its settings and extracts `liveprog` into `Liveprog/<name>` unless a file of that name exists. File paths are relative to its external files folder: `Convolver/<name>`, `DDC/<name>`, `Liveprog/<name>` (`FileLibraryPreference.createFullPathCompat`).

| audio.conf key | Rootless file / key | Rootless type | Conversion |
|---|---|---|---|
| master_postgain | dsp_output_control / output_postgain | float | 1:1 dB |
| master_limthreshold | dsp_output_control / limiter_threshold | float | 1:1 (Rootless does not clamp; Linux clamps ≤ −0.09 when applying) |
| master_limrelease | dsp_output_control / limiter_release | float | 1:1 (Linux clamps ≥ 0.15) |
| bass_enable, bass_maxgain | dsp_bass / bass_enable, bass_max_gain | bool, float | 1:1 |
| compander_enable | dsp_compander / compander_enable | bool | 1:1 |
| compander_timeconstant | dsp_compander / compander_timeconstant | float | 1:1 |
| compander_granularity | dsp_compander / compander_granularity | float | 1:1 (int ⇄ float) |
| compander_time_freq_transforms | dsp_compander / compander_tftransforms | string | 1:1 |
| compander_response | dsp_compander / compander_response | string | same 14-value layout |
| tone_enable, tone_eq | dsp_equalizer / eq_enable, eq_bands | bool, string | same 30-value layout |
| tone_filtertype, tone_interpolation | dsp_equalizer / eq_filter_type, eq_interpolation | string | 1:1 |
| graphiceq_enable, graphiceq_param | dsp_graphiceq / geq_enable, geq_nodes | bool, string | same `GraphicEQ:` text |
| reverb_enable | dsp_reverb / reverb_enable | bool | 1:1 |
| reverb_* (17 keys) | dsp_reverb / reverb_preset | string | Rootless calls `Reverb_SetParam(preset)`, which expands to the 19-row table in `Effects/reverb.c` `sf_presetreverb`. Import: write that row's values into the 17 `reverb_*` keys (delay s → ms). Export: the preset whose row matches exactly; otherwise the closest row, reported. |
| stereowide_enable, stereowide_level | dsp_stereowide / stereowide_enable, stereowide_mode | bool, float | 1:1 (both ÷100 in the wrapper) |
| crossfeed_enable, crossfeed_mode | dsp_crossfeed / bs2b_crossfeed_enable, bs2b_crossfeed_mode | bool, string | 1:1 for 0–5. Linux 99 (custom fcut/feed) has no Rootless key: exported as 1, reported. |
| crossfeed_bs2b_fcut, crossfeed_bs2b_feed | — | — | not in Rootless presets; reported on export when mode is 99 |
| tube_enable, tube_pregain | dsp_tube / tube_enable, tube_drive | bool, float | 1:1 (both ÷100 in the wrapper) |
| ddc_enable, ddc_file | dsp_ddc / ddc_enable, ddc_file | bool, string | path ⇄ `DDC/<name>` |
| liveprog_enable, liveprog_file | dsp_liveprog / liveprog_enable, liveprog_file | bool, string | path ⇄ `Liveprog/<name>`; script bundled as `liveprog` |
| convolver_enable, convolver_file | dsp_convolver / convolver_enable, convolver_file | bool, string | path ⇄ `Convolver/<name>` (IR not bundled; Rootless presets never carry IRs) |
| convolver_optimization_mode, convolver_waveform_edit | dsp_convolver / convolver_mode, convolver_adv_imp | string | 1:1 |
| master_enable | — (app setting `powered_on`, not in presets) | — | not exported; reported if off |

Rootless-only, reported on import: `dsp_parametriceq` (parametric EQ: `peq_enable`, `peq_bands`, `peq_preamp`), `liveprog_params`, `convolver_sample_rate_files`, `convolver_processing_rate`, and any unknown keys.

## JamesDSP for Android, root (`DSPManager`), import only

A preset is a folder with SharedPreferences files `james.dsp.speaker.xml`, `james.dsp.headset.xml`, `james.dsp.bluetooth.xml` (one per output) and `james.dsp.settings.xml` (`DSPManager.java:476-`). The user picks which output profile to import. Values are stored as strings unless noted. Native scaling from `jamesdsp.c` (JamesDSPManager `Main/libjamesdsp`).

| audio.conf key | Android key | Conversion |
|---|---|---|
| master_enable | dsp.masterswitch.enable (bool) | 1:1 |
| master_limthreshold, master_limrelease, master_postgain | dsp.masterswitch.limthreshold, .limrelease, .postgain | 1:1 (same clamps natively) |
| bass_enable, bass_maxgain | dsp.bass.enable (bool), dsp.bass.maxgain | 1:1 |
| compander_enable | dsp.compression.enable (bool) | 1:1 |
| compander_timeconstant, compander_granularity, compander_time_freq_transforms | dsp.compression.timeconstant, .granularity, .tfresolution | 1:1 |
| compander_response | dsp.compression.eq.custom | same 14-value layout |
| tone_enable, tone_eq | dsp.tone.enable (bool), dsp.tone.eq.custom | same 30-value layout |
| tone_filtertype, tone_interpolation | dsp.tone.filtertype (default 3), dsp.tone.interpolation | 1:1 |
| graphiceq_enable, graphiceq_param | dsp.streq.enable (bool), dsp.streq.stringp | 1:1 |
| reverb_enable, reverb_* | dsp.headphone.enable (bool), dsp.headphone.preset | preset row → 17 keys, as for Rootless |
| stereowide_enable, stereowide_level | dsp.stereowide.enable (bool), dsp.stereowide.mode | 1:1 (÷100 natively) |
| crossfeed_enable, crossfeed_mode | dsp.bs2b.enable (bool), dsp.bs2b.mode | 1:1 |
| tube_enable, tube_pregain | dsp.analogmodelling.enable (bool), dsp.analogmodelling.tubedrive | drive is dB (×1000/1000 natively); `tube_pregain = drive × 100` |
| convolver_enable, convolver_file | dsp.convolver.enable (bool), dsp.convolver.files | path → file name lookup |
| convolver_optimization_mode, convolver_waveform_edit | dsp.convolver.mode, dsp.convolver.advimp | 1:1 |
| ddc_enable, ddc_file | dsp.ddc.enable (bool), dsp.ddc.files | path → file name lookup |
| liveprog_enable, liveprog_file | dsp.liveprog.enable (bool), dsp.liveprog.files | path → file name lookup |

Not imported (reported): `dsp.convolver.resampler`, app/UI keys.
