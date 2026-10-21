# Licence findings (Phase 0)

Checked 2026-10-19 against these clones:

| Repo | Commit | Date |
|------|--------|------|
| Audio4Linux/JDSP4Linux | `3ea7d733c090409c00887db3bb3aaf3af79ea692` | 2026-10-01 |
| james34602/JamesDSPManager | `5aed6a4a9a4cb109e2d8246e103bb1578cb83cfb` | 2025-06-18 |
| james34602/EEL_VM | `284b3da00af91efc3aff6bfc1acefb4e801a8ad6` | 2025-06-18 |

The libjamesdsp candidate for vendoring is `JDSP4Linux/libjamesdsp/subtree/Main/libjamesdsp/jni/jamesdsp/`, a `git subtree` of `ThePBone/JamesDSPManager` branch `extensions` (see `libjamesdsp/update_subtree.sh`). Only the files listed in `JDSP4Linux/libjamesdsp/libjamesdsp.pro` are built.

## libjamesdsp itself: GPL, version not stated

- `Main/LICENSE` is the verbatim GPLv2 text (identical SHA-1 `23a1f87d…` in JDSP4Linux's subtree, JamesDSPManager and EEL_VM). It was added by James Fung in JamesDSPManager commit `ac49e07` (2021-08-23, "Create license for latest release").
- The "How to Apply" appendix at the end of that file is the unfilled GitHub template (`{description}`, `{year}`, `{fullname}`). It is not a notice that applies to the program.
- `Main/README.md` line 3: "Release under GPL license". No version, no "or later".
- **None** of James Fung's own source files carry a licence or copyright header. Files with no header include `jdspController.c`, `jdsp_header.h`, every effect in `Effects/` except `reverb.c`, everything in `generalDSP/`, `liveprogWrapper.c`, and the EEL additions (`numericSys/*`, `s_str.c`, `eelCommon.h`, `glue_port.h`).
- EEL_VM: same LICENSE file, and no source file there says "GPL" or "or later" either (only the bundled LGPL HPA files mention the GNU licences).
- No licence discussion in the JamesDSPManager, EEL_VM, JDSP4Linux or RootlessJamesDSP issue trackers (`gh search issues license`).
- Downstream practice: JDSP4Linux (GPL-3.0) and RootlessJamesDSP (GPL-3.0, per GitHub API) both ship libjamesdsp inside GPLv3 programs.

**Reading:** GPLv2 §9 says that if the Program "does not specify a version number of this License, you may choose any version ever published". Nothing here specifies a version in a notice; the only signal is that the file shipped is the v2 text. The FSF FAQ says a bare licence file in a repo does not clearly state terms. So libjamesdsp is *probably* "GPL, any version" (GPLv3-compatible), but GPLv2-only cannot be ruled out from the sources. This is the case PLAN.md said to stop on.

## Third-party code inside the built file set

| Component | Files | Licence (from headers) | GPLv3 | GPLv2 |
|-----------|-------|------------------------|-------|-------|
| NS-EEL2 (Nullsoft / Cockos WDL) | `eel2/nseel-compiler.c`, `nseel-ram.c`, `ns-eel.h`, `ns-eel-int.h` | zlib | ok | ok |
| WDL FFT (Cockos, after DJB fft) | `eel2/fft.c` | zlib | ok | ok |
| sndfilter reverb (Sean Connelly) | `Effects/reverb.c` | MIT | ok | ok |
| libsamplerate (Erik de Castro Lopo, mods by James Fung) | `numericSys/libsamplerate/*` | BSD-2-Clause | ok | ok |
| HPA (Atkinson, Primi) | `numericSys/HPFloat/*` | LGPL-2.1-or-later | ok | ok |
| dr_wav / dr_flac / dr_mp3 (David Reid) | `eel2/dr_*.h` | public domain or MIT-0 | ok | ok |
| stb_sprintf (Jeff Roberts) | `eel2/stb_sprintf.h` | public domain / MIT | ok | ok |
| dirent (Toni Ronkko) | `eel2/dirent.h` (Windows only) | MIT | ok | ok |

Not built by JDSP4Linux and **will not be vendored**: `MemoryUsage.h` (David Robert Nadeau, CC BY 3.0; only included by the Android entry `jamesdsp.c`), `jamesdsp.c`, `essential.h`, the HPA `cxxsrc/` C++ files.

## Provenance gaps (upstream, not blocking, record attribution when vendoring)

These files look derived from third-party code but the original notices were stripped upstream:

- `Effects/bs2b.c`: Bauer stereo-to-binaural, same API shape as libbs2b (MIT, Boris Mikhaylov). Notice missing.
- `numericSys/MersenneTwister.c`: MT19937 reference code (Matsumoto & Nishimura, BSD-3-Clause). The BSD notice the licence requires is missing.
- `eel2/y.tab.c`: "A Bison parser, made by GNU Bison 2.3". Bison ≥2.2 output carries a special exception allowing any licence; the exception text was stripped.
- `numericSys/solvopt.c`: "SOLVOPT version 1.2 (June, 1997) by Alexei Kuntsevich and Franz Kappel". No licence stated. **[unknown]**
- `numericSys/cpoly.c`: "Jenkins-Traub complex polynomial root finder" (originally ACM TOMS Algorithm 419). Port origin and licence not stated. **[unknown]**

None of these is shown to be GPL-incompatible. `solvopt.c` and `cpoly.c` have unknown terms. `solvopt` is only reached through `quadprog.c` (EEL `quadprog`/`lsqlin`). `cpoly` is called from EEL (`eel_matrix.h`) and from `FilterDesign/generalFdesign.c`, a file the non-EEL effects also link (`dynamic.c`, `vacuumTube.c` and `ArbFIRGen.c` use its tables and crossover), so it cannot be dropped just by disabling liveprog.

## Decision (2026-10-19, user)

jdsp4mac stays **GPL-3.0-or-later**. libjamesdsp is treated as "GPL, any version": no source file or notice specifies a version number, so GPLv2 §9 ("If the Program does not specify a version number of this License, you may choose any version ever published by the Free Software Foundation") lets us take it under GPLv3. JDSP4Linux and RootlessJamesDSP rely on the same reading and ship it inside GPLv3 programs. Everything else in the built file set is permissive or LGPL-2.1-or-later, so nothing else blocks GPLv3.

Residual risk: if James Fung later states the code is GPLv2-only, the combined binary could not be distributed under GPLv3. The fallback would be relicensing our own code GPL-2.0-or-later (we copy no GPLv3-only code, per CLAUDE.md rule 7, which keeps that option open).
