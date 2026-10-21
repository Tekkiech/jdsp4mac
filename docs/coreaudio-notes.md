# Core Audio tap + aggregate notes

Notes for Phase 1–2. Written from reading, not copied. Sources:

- macOS 27.0 SDK headers in Xcode 27.1 (`CoreAudio.framework/Headers/CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`). Treated as the current Apple reference.
- AudioCap `6f609e8` (BSD-2-Clause, Guilherme Rambo): `AudioCap/ProcessTap/ProcessTap.swift`, README.
- FineTune `2285279` (GPLv3, Ronit Singh): `Audio/Engine/ProcessTapController.swift`, `TapResources.swift`, `CrashGuard.swift`, `OrphanedTapCleanup.swift`, `AudioEngine.swift`, `Extensions/AudioObjectID+Readiness.swift`, `FineTuneApp.swift`.

Line numbers refer to those commits.

## API surface (SDK, macOS 27.0)

- `AudioHardwareCreateProcessTap(CATapDescription *, AudioObjectID *)` and `AudioHardwareDestroyProcessTap`: `API_AVAILABLE(macos(14.2))` (`AudioHardwareTapping.h:42-54`).
- **`CATapDescription` is an Objective-C class** (`CATapDescription.h:44`). C cannot build one. So the tap description is created on the control side (Swift), and C gets back plain `AudioObjectID`s and the tap UUID string. This does not break hard rule 1: only the IOProc has to be C.
- Constructors: `initStereoMixdownOfProcesses:`, `initStereoGlobalTapButExcludeProcesses:` (all processes except the listed ones, mono sources duplicated to L and R; the one we want for D1), mono variants, and per-device-stream variants `initWithProcesses:andDeviceUID:withStream:` / `initExcludingProcesses:…`.
- Properties: `name`, `UUID`, `processes`, `mono`, `exclusive`, `mixdown`, `privateTap` (visible only to the creating process), `muteBehavior`, `deviceUID`, `stream`. New in macOS 26: `bundleIDs` (tap or exclude by bundle ID) and `processRestoreEnabled` (re-add tapped processes by bundle ID when they relaunch). We target 14.4, so these need `if #available`. Not needed for v1.
- `CATapMuteBehavior` (`CATapDescription.h:20-34`): `CATapUnmuted` (0), `CATapMuted` (1, never sent to hardware), `CATapMutedWhenTapped` (2, muted only **while the tap is being read**). With `MutedWhenTapped`, if our IOProc stops reading, apps become audible again on their own. That is a safer failure mode than `CATapMuted`.
- Tap object properties: `kAudioTapPropertyUID` `'tuid'`, `kAudioTapPropertyDescription` `'tdsc'`, `kAudioTapPropertyFormat` `'tfmt'` (an ASBD) (`AudioHardware.h:2020-2022`). System: `kAudioHardwarePropertyTapList` `'tps#'`, `kAudioHardwarePropertyProcessObjectList` `'prs#'`, `kAudioHardwarePropertyTranslatePIDToProcessObject` `'id2p'` (`:633-635`).
- Process objects: `kAudioProcessPropertyPID`, `BundleID`, `Devices`, `IsRunning`, `IsRunningInput`, **`IsRunningOutput` `'piro'`** (`:1972-1979`). Use `IsRunningOutput` on the process list to tell "other apps are playing" from real silence for the zero-buffer watchdog (Phase 2).
- Aggregate keys for taps: `kAudioAggregateDeviceTapListKey` `"taps"`, sub-tap dict with `kAudioSubTapUIDKey` `"uid"`, `kAudioSubTapDriftCompensationKey` `"drift"`, `kAudioSubTapDriftCompensationQualityKey`, `kAudioSubTapExtraInputLatencyKey` / `ExtraOutputLatencyKey`.
- **`kAudioAggregateDeviceTapAutoStartKey` `"tapautostart"`** (`AudioHardware.h:1628-1640`): "calling AudioDeviceStart with the aggregate device will wait until a tapped process begins receiving its first audio". It requires the private key. Both AudioCap and FineTune set it. Consequence: `AudioDeviceStart` can block indefinitely when nothing is playing. This may be part of what PLAN.md §2.2b reports as "start blocks while another tap exists". Either way, start IO off the main thread.
- `kAudioAggregateDeviceIsPrivateKey` (`:1598-1609`): private to the creating process, "not persistent across launches of the process that created it".

## Setup sequence (both projects agree)

1. Build the tap description: UUID set explicitly, `muteBehavior` set, `privateTap = true` (FineTune `ProcessTapController.swift:535-538`, `:555-558`; AudioCap uses defaults except mute).
2. `AudioHardwareCreateProcessTap` → tap ID. Read `kAudioTapPropertyFormat` from the tap for the input ASBD (AudioCap `ProcessTap.swift:133`).
3. Read the default output device's UID (`kAudioHardwarePropertyDefaultOutputDevice` → `kAudioDevicePropertyDeviceUID`).
4. Aggregate dictionary:
   - name, a fresh UUID as `kAudioAggregateDeviceUIDKey`
   - `MainSubDevice` = output UID; FineTune also sets `ClockDevice` = output UID (`:398-399`)
   - `IsPrivate = true`, `IsStacked = false` (single device), `TapAutoStart = true`
   - `SubDeviceList` = `[{uid: outputUID, drift: false}]`. The clock device gets no drift compensation; extra sub-devices do (`:378-384`).
   - `TapList` = `[{uid: tapUUID, drift: …}]`
5. `AudioHardwareCreateAggregateDevice`, then **wait until the aggregate is alive**: FineTune polls `kAudioDevicePropertyDeviceIsAlive` while running the CFRunLoop in 10 ms slices, with a 2 s timeout (`AudioObjectID+Readiness.swift:31-43`, `ProcessTapController.swift:618`). Without the run loop the HAL notifications that finish setup are not processed.
6. Read the aggregate's nominal sample rate (FineTune `:629-640`).
7. `AudioDeviceCreateIOProcIDWithBlock` (both projects; dispatch-queue blocks). We will use the C `AudioDeviceCreateIOProcID` with a C function pointer, so no block or Swift closure is on the audio thread.
8. FineTune sets `kAudioDevicePropertyIOProcStreamUsage` to turn off the hardware **input** streams of the wrapped output device (`:460-500`). Otherwise a duplex device (USB interface, some built-ins) has its microphone powered on and macOS shows microphone use. The tap streams are the **last** input streams of the aggregate (`inputStreamUsageFlags`, `:445-452`). Our IOProc should read those, not assume buffer 0.
9. `AudioDeviceStart(aggregate, procID)`.

Teardown order (AudioCap `ProcessTap.swift:54-88`, FineTune `TapResources.swift:9-12`): `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.

## Clocking and drift (FineTune)

- Sub-tap drift compensation is turned **off** when the output is Bluetooth or the tap source is virtual, and **on** for wired/USB (`:386-393`). Their comment says that with BT, tap and output share the BT clock, and enabling drift compensation makes the HAL insert or drop a sample about every 0.7 s (audible crackle). For the M1 Pro built-in speakers/headphones, tap and output are both on the built-in clock, so FineTune's rule turns drift compensation on. **[verify]** in Phase 1 which setting is click-free on the built-in output, and record it in findings.

## Multichannel and user aggregates (FineTune)

- FineTune prefers a per-device-stream tap (`initWithProcesses:andDeviceUID:withStream:`) and falls back to stereo mixdown (`:530-578`). Their comment says this avoids the stereo-matrix attenuation on many-channel interfaces (matches PLAN.md's −12 dB report).
- If the user's default output is itself an aggregate, FineTune flattens it into its hardware sub-devices, because nested aggregates are not supported (`:360-375`; v1.8 release notes say this caused silence). For v1, treat a user aggregate or multichannel output as "pass through, unprocessed" per PLAN.md, and still flatten if we wrap it at all.

## Robustness patterns (FineTune)

- **Crash handler** (`CrashGuard.swift`): a fixed-size C array of live aggregate IDs, written under `os_unfair_lock`, read from a `SIGABRT/SIGSEGV/SIGBUS/SIGTRAP` handler that calls `AudioHardwareDestroyAggregateDevice` (a Mach IPC call) for each, then re-raises. We need the same for SIGTERM/SIGINT, plus the tap ID.
- **Launch sweep** (`OrphanedTapCleanup.swift:13-44`): list devices, destroy aggregates whose name starts with `FineTune-`. Their comment says orphans happen after crash or `kill -9` and leave muted taps. **Conflict:** the SDK says private aggregates are private to the creating process and not persistent across launches, and FineTune creates private ones. Whether a dead process's private aggregate and tap survive, and whether a new process can see them, is **[verify] in Phase 2** with a `kill -9` test. Keep the sweep (cheap) and name ours with a fixed prefix (`jdsp4mac-`).
- **Health monitor** (`AudioEngine.swift:1884-1935`): every 2 s, for taps whose app is actively streaming and that have been active ≥5 s, check that the IOProc ran within the last 3 s (host time stamped in the callback). After 3 misses, recreate the tap. "No callbacks while nothing plays" is treated as normal. This matches the macOS 27 forum note in PLAN.md.
- **Fade-in gate**: the output starts at zero and ramps in over 40 ms on the first non-silent input after ≥200 ms of silence (`advanceOutputGate` `:1275-1310`, set up at `:686-690`). Matches PLAN.md Phase 2 "fade in on first audible buffer".
- **Device switching**: FineTune builds a second tap + aggregate for the new device and crossfades before destroying the old one (`updateDevices` `:715`, `performCrossfadeSwitch` `:876`), and falls back to a destructive switch when the old device is gone. For v1 a destructive rebuild with fade-in is enough (PLAN.md Phase 2). Crossfading is polish.
- **Own aggregates hidden** from the device list by name prefix (`AudioDeviceMonitor.swift:161`).

## What we do differently

- One **global** tap excluding our own process (`initStereoGlobalTapButExcludeProcesses:` with our process object from `TranslatePIDToProcessObject(getpid())`), not per-app taps.
- IOProc in C, registered with `AudioDeviceCreateIOProcID`. AudioCap's IOProc allocates (`AVAudioPCMBuffer`, file writes) and FineTune's is a Swift closure; neither is a model for our audio thread.
- Our IOProc: find the tap input buffer(s) (last input streams), check format (stereo float; else pass through), de-interleave into preallocated planar scratch if needed, run libjamesdsp at a constant frame count, write to the output buffer(s).

## Open questions for Phase 1

- Exact `AudioBufferList` layout the IOProc gets for tap input and built-in output on this machine (interleaved vs not, buffer count, frame count stability). Log once from a probe build and record it in findings.
- Does `AudioDeviceStart` with `tapautostart` block when nothing is playing? Measure; decide whether to keep the key.
- Tap and drift compensation behaviour on built-in output at 44.1 and 48 kHz.
