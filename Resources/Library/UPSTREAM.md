# Bundled library

`liveprog/`, `irs/` and `vdc/` are copied unchanged from JDSP4Linux's `resources/assets/`.

| | |
|---|---|
| Source repo | https://github.com/Audio4Linux/JDSP4Linux (GPL-3.0) |
| Pinned commit | `3ea7d733c090409c00887db3bb3aaf3af79ea692` (2026-10-01) |

Some scripts carry their own notices (GPL, Cockos); those stay in the files. `presets/` is ours: starter presets composed from JDSP4Linux's EQ curves and libjamesdsp's reverb table.

Before adding a script, read its header. `Tests/vet-liveprog.sh` compiles and runs a folder of them.
