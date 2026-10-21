# Vendored libjamesdsp

Copied from **JDSP4Linux**, not from James Fung's JamesDSPManager, because the Linux copy is the one tested on desktop with float planar stereo and carries JDSP4Linux's fixes (bitrot cleanup, missing mutex lock, `struct dspsys` ordering, cstdint).

| | |
|---|---|
| Source repo | https://github.com/Audio4Linux/JDSP4Linux |
| Pinned commit | `3ea7d733c090409c00887db3bb3aaf3af79ea692` (2026-10-01) |
| Last commit touching `libjamesdsp/` | `087d4a5b8099b1001e6f41c9396105450b5774bd` (2025-01-09) |
| Subtree origin | `ThePBone/JamesDSPManager` branch `extensions`, last pulled at `1b9f89dbd4b332a07724beb41d58bc2ffcb05395` (JDSP4Linux squash `d60ff20`, 2023-11-24), plus JDSP4Linux's local edits after that |
| Original upstream | https://github.com/james34602/JamesDSPManager (`5aed6a4a9a4cb109e2d8246e103bb1578cb83cfb` checked for comparison) |

## What was copied

| Here | From (in JDSP4Linux) | Licence |
|------|----------------------|---------|
| `jamesdsp/jdsp/` | `libjamesdsp/subtree/Main/libjamesdsp/jni/jamesdsp/jdsp/` (whole directory, unmodified) | `LICENSE` (GPL, version unstated) plus third-party notices in file headers |
| `jamesdsp/cpthread.h` | `libjamesdsp/subtree/Main/libjamesdsp/jni/jamesdsp/cpthread.h` (included by `jdsp_header.h` as `../cpthread.h`) | same |
| `LICENSE` | `libjamesdsp/subtree/Main/LICENSE` | GPLv2 text as shipped upstream |
| `jdsp4linux-glue/*.c,*.h` | `libjamesdsp/{EELStdOutExtension,PrintfStdOutExtension,JdspImpResToolbox}.{c,h}` | JDSP4Linux, GPLv3 (`jdsp4linux-glue/LICENSE`) |
| `jdsp4linux-glue/libjamesdsp.pro` | `libjamesdsp/libjamesdsp.pro` | reference only: the file list and defines JDSP4Linux builds with |

Not copied: the Android entry (`jamesdsp.c`, `essential.h`, `MemoryUsage.h` which is CC BY 3.0, `Android.mk`), the Android GUI, and the rest of the JamesDSPManager tree.

Licence analysis: `docs/licences.md`.

## Local modifications

Record every change to files under this directory here, with the reason.

| Date | File | Change | Why |
|------|------|--------|-----|
| 2026-10-19 | `jamesdsp/jdsp/generalDSP/TwoStageFFTConvolver.c` | `inline void task_wait*` / `task_start*` (8 functions) → `static inline` | C99/C11 `inline` without `static`/`extern` emits no external definition; at `-O0` clang left `_task_wait1x1` etc. undefined at link time. Each is used only in this file. |
| 2026-10-19 | `jamesdsp/jdsp/generalDSP/digitalFilters.c` | `inline void complexMultiplicationj` / `complexDivisionj` → `static inline` | Same link failure (`_complexDivisionj`, `_complexMultiplicationj`). File-local helpers. |
| 2026-10-19 | `jamesdsp/jdsp/jdspController.c` | `JamesDSPFree`: destroy `m_in_processing` after the final unlock instead of before it | It destroyed the mutex while holding it and then unlocked the destroyed mutex (undefined behaviour). |
| 2026-10-20 | `jamesdsp/jdsp/jdspController.c` | `selectConvPartitions` returns 1 (single-stage) when `JD_SINGLE_STAGE_CONVOLUTION` is defined (we define it) | The two-stage convolver makes the caller wait on a condition variable for a normal-priority worker thread; live, the IOProc stalled up to 7.9 ms of a 10.67 ms budget (5 s IR, crossfeed mode 5). Single-stage: 0.33 ms worst block, all on the audio thread. |

## Updating

Re-copy the same paths from a newer JDSP4Linux commit, update the table above, and re-run the licence grep in `docs/licences.md`.
