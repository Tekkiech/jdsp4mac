#ifndef AUDIOCORE_H
#define AUDIOCORE_H

// Real-time audio plane: IOProc, stream mapping, libjamesdsp instance, counters, crash cleanup.
// Nothing reachable from the IOProc may allocate, lock, log or call into Objective-C/Swift.
// The IOProc is compiled with clang's `nonblocking` effect analysis (-Wfunction-effects as error).
// The tap itself is created on the Swift side because CATapDescription is an Objective-C class.

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

typedef struct JDLive JDLive;
typedef struct JDDsp JDDsp;  // one fully configured libjamesdsp instance

// A complete settings snapshot, already parsed and converted from audio.conf by the Swift side
// (Engine/DSPParams.swift). Strings are borrowed for the duration of jd_dsp_build only.
typedef struct {
    float postGainDb, limThresholdDb, limReleaseMs;
    int bassEnable; float bassMaxGainDb;
    int companderEnable; float companderTimeConstant; int companderGranularity, companderTransforms;
    int companderResponseValid; double companderResponse[14];   // 7 freqs, 7 gains
    int toneEnable, toneFilterType, toneInterpolation;
    int toneEQValid; double toneEQ[30];                        // 15 freqs, 15 gains (dB)
    int graphicEQEnable; const char *graphicEQ;                // "GraphicEQ: f g; ..."
    int reverbEnable, reverbOSF;
    float reverbReflectionAmount, reverbFinalWet, reverbFinalDry, reverbReflectionFactor, reverbReflectionWidth,
          reverbWidth, reverbWet, reverbLFOWander, reverbBassBoost, reverbLFOSpin,
          reverbLPFInput, reverbLPFBass, reverbLPFDamp, reverbLPFOutput, reverbDecay, reverbDelayMs;
    int convolverEnable; const char *convolverPath; int convolverOptimizationMode; int convolverWaveformEdit[6];
    int crossfeedEnable, crossfeedMode, crossfeedFcut, crossfeedFeed;
    int ddcEnable; const char *ddcText;                        // contents of the .vdc file
    int liveprogEnable; const char *liveprogText;              // contents of the .eel file
    int stereowideEnable; float stereowideLevel;               // 0..100
    int tubeEnable; float tubePregain;                         // hundredths of a dB
} JDParams;

// Builds and warms up an instance for `blockFrames` at `sampleRate` (worker thread; heavy: HRTF
// decode, IR load and partitioning, liveprog compile). Never fails for bad settings: an effect
// that cannot be set up is left off and explained in `messages` (newline-separated).
JDDsp *jd_dsp_build(const JDParams *params, uint32_t blockFrames, double sampleRate, char *messages, size_t messagesLen);
void jd_dsp_free(JDDsp *dsp);
// Offline use (tools/tests): process planar stereo, `frames` must equal the build's block size.
void jd_dsp_process(JDDsp *dsp, const float *inL, const float *inR, float *outL, float *outR, uint32_t frames);


typedef struct {
    uint64_t callbacks;
    uint64_t frames;
    uint64_t outputDiscontinuities;   // output sample time did not advance by the previous frame count
    uint64_t inputDiscontinuities;    // same for the tap input
    uint64_t overloads;               // kAudioDeviceProcessorOverload notifications
    uint64_t zeroInputCallbacks;      // callbacks whose tap input was exactly 0.0 throughout
    uint64_t unprocessedCallbacks;    // EQ mode, but passed through dry (frame count != DSP block)
    uint64_t layoutErrors;            // buffer layout did not match setup; output silenced
    uint32_t lastFrames;
    double busySeconds;               // total time spent inside the IOProc
    double maxCallbackSeconds;
    double firstHostSeconds, lastHostSeconds;  // host time of first/last callback
    double lastLatencySeconds, maxLatencySeconds;  // output host time - tap input host time
    float inPeak, outPeak;            // since the previous read
    float maxOutputStep;              // largest |y[n] - y[n-1]| on L or R since the previous read (click detector)
} JDLiveStats;

typedef struct {
    double sampleRate;
    uint32_t bufferFrames;
    uint32_t tapChannels;
    uint32_t inputBuffers, outputBuffers;
    uint32_t outputChannels;
    uint32_t outputLatencyFrames, outputSafetyOffsetFrames;
    uint32_t inputLatencyFrames, inputSafetyOffsetFrames;
} JDLiveInfo;

// Control thread only. `aggregate` must contain `tap` as its sub-tap. `dsp` (may be NULL: plain
// passthrough) must have been built for the aggregate's buffer size and rate; ownership passes to
// the JDLive.
JDLive *jd_live_create(AudioObjectID aggregate, AudioObjectID tap, JDDsp *dsp, char *err, size_t errLen);
OSStatus jd_live_start(JDLive *live);  // may block while kAudioAggregateDeviceTapAutoStartKey waits for audio
OSStatus jd_live_stop(JDLive *live);
void jd_live_destroy(JDLive *live);
void jd_live_get_info(const JDLive *live, JDLiveInfo *out);
void jd_live_read_stats(JDLive *live, JDLiveStats *out);  // also resets the peaks
void jd_live_set_bypass(JDLive *live, int bypass);         // 20 ms crossfade to/from dry
// Hands a new instance to the IOProc, which switches to it at the next buffer with a 40 ms
// crossfade from the current one (or from dry). Takes ownership; frees an earlier instance that
// was posted but not yet picked up. Control thread only.
void jd_live_post_dsp(JDLive *live, JDDsp *dsp);
// Frees an instance the IOProc has finished fading out. Call regularly from the control thread.
// Returns 1 if one was freed.
int jd_live_collect_retired(JDLive *live);
// Output starts silent and fades in over 20 ms on the first audible buffer (avoids a pop after a
// (re)build). jd_live_fade_out ramps to silence over 20 ms; poll jd_live_faded_out before teardown.
void jd_live_fade_out(JDLive *live);
// Test hook (scripted gate only): treat the tap input as exact zeros, as a denied permission does.
void jd_live_set_test_zero_input(JDLive *live, int on);
int jd_live_faded_out(JDLive *live);

// Permission probe. `aggregate` must contain an unmuted tap of *this process only*. The probe
// IOProc plays a -100 dBFS 1 kHz tone (inaudible) and measures what the tap hears. Returns the peak
// heard within `seconds` (stops early once heard); exactly 0 means capture is denied or broken.
// Blocks the calling (control) thread; may block longer on the permission prompt.
float jd_probe_run(AudioObjectID aggregate, double seconds, int testZeroInput, OSStatus *status);

// Drains libjamesdsp / liveprog text output (lock-free ring, see Sources/JamesDSPGlue). Calls
// `sink` per message; returns how many were dropped because the ring was full. Control thread.
uint32_t jd_drain_messages(void (*sink)(const char *text, void *context), void *context);

// Crash cleanup: async-signal-safe registry of the HAL objects we own (several graphs can exist
// briefly during a make-before-break rebuild). On SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGFPE the
// handler destroys them (Mach IPC to coreaudiod) and re-raises.
void jd_cleanup_install(void);
int jd_cleanup_track(AudioObjectID aggregate, AudioObjectID tap);  // returns a slot, or -1 if full
void jd_cleanup_untrack(int slot);
// Panic: destroy every tracked aggregate and tap right now, from any thread or a signal handler.
// Tapped apps go back to playing directly. Owners must treat their objects as gone afterwards.
void jd_panic(void);

#endif
