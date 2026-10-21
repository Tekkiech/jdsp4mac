#include "AudioCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


#define MAX_FRAMES 4096u  // scratch capacity; larger buffers are passed through dry

// Where one channel lives in an AudioBufferList: buffer index, first sample, stride (interleave).
typedef struct {
    uint32_t buffer, offset, stride;
} ChannelRef;

struct JDLive {
    // Setup (control thread), read-only while running.
    AudioObjectID aggregate;
    AudioDeviceIOProcID procID;
    JDLiveInfo info;
    ChannelRef tapL, tapR, outL, outR;
    uint32_t expectInputBuffers, expectOutputBuffers;
    double ticksToSeconds;
    float *dryL, *dryR, *wetL, *wetR, *oldL, *oldR;
    float wetStep;
    uint32_t xfadeLength;

    // Instance hand-over (see jd_live_post_dsp). `dsp` and `fading` belong to the IOProc.
    JDDsp *dsp;
    JDDsp *fading;          // previous instance during a crossfade, or NULL
    int fadingFromDry;      // crossfading from no instance (dry) to `dsp`
    uint32_t xfadeLeft;
    _Atomic(JDDsp *) pending;
    _Atomic(JDDsp *) retired;

    // Control -> IOProc.
    _Atomic int bypass;
    _Atomic int fadeOutRequested;
    _Atomic int testZeroInput;

    // IOProc-private state.
    float wetGain;
    float outGain, fadeStep;  // output fade: 0 until the first audible buffer, then ramps to 1
    int heardAudio;
    double nextOutSample, nextInSample;
    int haveTimes;

    // IOProc -> control (relaxed atomics, all lock-free on arm64).
    _Atomic uint64_t callbacks, frames, outDisc, inDisc, overloads, zeroIn, unprocessed, layoutErrors;
    _Atomic uint32_t lastFrames;
    _Atomic uint64_t busyTicks, maxTicks, firstHost, lastHost, lastLatencyTicks, maxLatencyTicks;
    _Atomic uint32_t inPeakBits, outPeakBits, maxStepBits;
    float lastOutL, lastOutR;  // IOProc-private, for the step measurement
    _Atomic int fadedOut;
};

#define AUDIBLE_PEAK 1.0e-4f  // about -80 dBFS

#define RELAXED memory_order_relaxed

// ---------------------------------------------------------------------------------------------
// Real-time section. Everything here is checked by clang's nonblocking effect analysis.

static inline uint32_t float_bits(float f) CA_REALTIME_API
{
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

static inline void raise_peak(_Atomic uint32_t *slot, float peak) CA_REALTIME_API
{
    // Non-negative floats order the same as their bit patterns.
    uint32_t bits = float_bits(peak);
    if (bits > atomic_load_explicit(slot, RELAXED))
        atomic_store_explicit(slot, bits, RELAXED);
}

static inline uint64_t host_now(void) CA_REALTIME_API
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    // mach_absolute_time reads the commpage timebase: no syscall, no lock, no allocation.
    return mach_absolute_time();
#pragma clang diagnostic pop
}

static inline const float *channel_ptr(const AudioBufferList *abl, ChannelRef c) CA_REALTIME_API
{
    return (const float *)abl->mBuffers[c.buffer].mData + c.offset;
}

static OSStatus jd_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *in,
                          const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime,
                          void *clientData) CA_REALTIME_API
{
    (void)device;
    (void)now;
    JDLive *L = (JDLive *)clientData;
    const uint64_t t0 = host_now();

    // Layout must match what setup saw; otherwise output silence (never garbage) and count it.
    if (in->mNumberBuffers != L->expectInputBuffers || out->mNumberBuffers != L->expectOutputBuffers) {
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
        atomic_fetch_add_explicit(&L->layoutErrors, 1, RELAXED);
        return noErr;
    }
    const AudioBuffer *tapBuf = &in->mBuffers[L->tapL.buffer];
    const AudioBuffer *outBuf = &out->mBuffers[L->outL.buffer];
    const uint32_t frames = outBuf->mDataByteSize / (L->outL.stride * sizeof(float));
    const uint32_t inFrames = tapBuf->mDataByteSize / (L->tapL.stride * sizeof(float));
    if (inFrames != frames || tapBuf->mData == NULL) {
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
        atomic_fetch_add_explicit(&L->layoutErrors, 1, RELAXED);
        return noErr;
    }

    // Timeline continuity and tap-to-output delay.
    const int timesValid = (outTime->mFlags & kAudioTimeStampSampleTimeValid) && (inTime->mFlags & kAudioTimeStampSampleTimeValid);
    if (timesValid) {
        if (L->haveTimes) {
            if (outTime->mSampleTime != L->nextOutSample)
                atomic_fetch_add_explicit(&L->outDisc, 1, RELAXED);
            if (inTime->mSampleTime != L->nextInSample)
                atomic_fetch_add_explicit(&L->inDisc, 1, RELAXED);
        }
        L->nextOutSample = outTime->mSampleTime + frames;
        L->nextInSample = inTime->mSampleTime + frames;
        L->haveTimes = 1;
    }
    if ((outTime->mFlags & kAudioTimeStampHostTimeValid) && (inTime->mFlags & kAudioTimeStampHostTimeValid) &&
        outTime->mHostTime >= inTime->mHostTime) {
        uint64_t lat = outTime->mHostTime - inTime->mHostTime;
        atomic_store_explicit(&L->lastLatencyTicks, lat, RELAXED);
        if (lat > atomic_load_explicit(&L->maxLatencyTicks, RELAXED))
            atomic_store_explicit(&L->maxLatencyTicks, lat, RELAXED);
    }

    const float *inLp = channel_ptr(in, L->tapL), *inRp = channel_ptr(in, L->tapR);
    float *outLp = (float *)channel_ptr(out, L->outL), *outRp = (float *)channel_ptr(out, L->outR);
    const uint32_t is = L->tapL.stride, os = L->outL.stride;

    // Zero any output channels beyond L/R first (multichannel devices are not processed in v1).
    if (L->info.outputChannels > 2 || L->expectOutputBuffers > 1)
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);

    float inPeak = 0.0f, outPeak = 0.0f;
    const float inScale = atomic_load_explicit(&L->testZeroInput, RELAXED) ? 0.0f : 1.0f;
    // Pick up a new instance at this buffer boundary. Only when no crossfade is running and the
    // retired slot is free, so the old instance always has somewhere to go when its fade ends.
    if (L->fading == NULL && !L->fadingFromDry && atomic_load_explicit(&L->retired, memory_order_acquire) == NULL) {
        JDDsp *next = atomic_exchange_explicit(&L->pending, NULL, memory_order_acq_rel);
        if (next) {
            L->fading = L->dsp;
            L->fadingFromDry = (L->dsp == NULL);
            L->dsp = next;
            L->xfadeLeft = L->xfadeLength;
        }
    }
    const int canProcess = L->dsp != NULL && frames == L->info.bufferFrames && frames <= MAX_FRAMES;

    if (!canProcess) {
        for (uint32_t i = 0; i < frames; i++) {
            float l = inLp[i * is] * inScale, r = inRp[i * is] * inScale;
            outLp[i * os] = l;
            outRp[i * os] = r;
            float m = __builtin_fmaxf(__builtin_fabsf(l), __builtin_fabsf(r));
            inPeak = __builtin_fmaxf(inPeak, m);
        }
        outPeak = inPeak;
        if (L->dsp != NULL)
            atomic_fetch_add_explicit(&L->unprocessed, 1, RELAXED);
    } else {
        for (uint32_t i = 0; i < frames; i++) {
            L->dryL[i] = inLp[i * is] * inScale;
            L->dryR[i] = inRp[i * is] * inScale;
            inPeak = __builtin_fmaxf(inPeak, __builtin_fmaxf(__builtin_fabsf(L->dryL[i]), __builtin_fabsf(L->dryR[i])));
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        // libjamesdsp is not annotated. These instances are touched only by this thread, the frame
        // count equals the block size they were built and warmed up with, so the call does not
        // reallocate or rebuild; their internal mutex is uncontended (docs/libjamesdsp-api.md).
        jd_dsp_process(L->dsp, L->dryL, L->dryR, L->wetL, L->wetR, frames);
        if (L->fading)
            jd_dsp_process(L->fading, L->dryL, L->dryR, L->oldL, L->oldR, frames);
#pragma clang diagnostic pop
        if (L->xfadeLeft > 0) {
            // Linear crossfade old -> new over xfadeLength samples (old = previous instance or dry).
            const float *oL = L->fading ? L->oldL : L->dryL, *oR = L->fading ? L->oldR : L->dryR;
            const float inv = 1.0f / (float)L->xfadeLength;
            for (uint32_t i = 0; i < frames; i++) {
                const uint32_t left = L->xfadeLeft > i ? L->xfadeLeft - i : 0;
                const float t = 1.0f - (float)left * inv;
                L->wetL[i] = oL[i] + (L->wetL[i] - oL[i]) * t;
                L->wetR[i] = oR[i] + (L->wetR[i] - oR[i]) * t;
            }
            L->xfadeLeft = L->xfadeLeft > frames ? L->xfadeLeft - frames : 0;
            if (L->xfadeLeft == 0) {
                if (L->fading)
                    atomic_store_explicit(&L->retired, L->fading, memory_order_release);
                L->fading = NULL;
                L->fadingFromDry = 0;
            }
        }
        const float target = atomic_load_explicit(&L->bypass, RELAXED) ? 0.0f : 1.0f;
        float g = L->wetGain;
        for (uint32_t i = 0; i < frames; i++) {
            if (g < target) g = __builtin_fminf(target, g + L->wetStep);
            else if (g > target) g = __builtin_fmaxf(target, g - L->wetStep);
            float l = L->dryL[i] + (L->wetL[i] - L->dryL[i]) * g;
            float r = L->dryR[i] + (L->wetR[i] - L->dryR[i]) * g;
            outLp[i * os] = l;
            outRp[i * os] = r;
            outPeak = __builtin_fmaxf(outPeak, __builtin_fmaxf(__builtin_fabsf(l), __builtin_fabsf(r)));
        }
        L->wetGain = g;
    }

    // Output fade (in after (re)build, out before teardown). Applied in place on L/R.
    if (inPeak > AUDIBLE_PEAK)
        L->heardAudio = 1;
    const int fadeOut = atomic_load_explicit(&L->fadeOutRequested, RELAXED);
    const float gainTarget = (fadeOut || !L->heardAudio) ? 0.0f : 1.0f;
    float og = L->outGain;
    if (og != 1.0f || gainTarget != 1.0f) {
        outPeak = 0.0f;
        for (uint32_t i = 0; i < frames; i++) {
            if (og < gainTarget) og = __builtin_fminf(gainTarget, og + L->fadeStep);
            else if (og > gainTarget) og = __builtin_fmaxf(gainTarget, og - L->fadeStep);
            outLp[i * os] *= og;
            outRp[i * os] *= og;
            outPeak = __builtin_fmaxf(outPeak, __builtin_fmaxf(__builtin_fabsf(outLp[i * os]), __builtin_fabsf(outRp[i * os])));
        }
        L->outGain = og;
    }
    if (fadeOut && og == 0.0f)
        atomic_store_explicit(&L->fadedOut, 1, RELAXED);

    // Click detector: largest sample-to-sample step of the final output.
    float step = 0.0f, pl = L->lastOutL, pr = L->lastOutR;
    for (uint32_t i = 0; i < frames; i++) {
        const float l = outLp[i * os], r = outRp[i * os];
        step = __builtin_fmaxf(step, __builtin_fmaxf(__builtin_fabsf(l - pl), __builtin_fabsf(r - pr)));
        pl = l;
        pr = r;
    }
    L->lastOutL = pl;
    L->lastOutR = pr;
    raise_peak(&L->maxStepBits, step);

    if (inPeak == 0.0f)
        atomic_fetch_add_explicit(&L->zeroIn, 1, RELAXED);
    raise_peak(&L->inPeakBits, inPeak);
    raise_peak(&L->outPeakBits, outPeak);

    const uint64_t t1 = host_now();
    const uint64_t busy = t1 - t0;
    atomic_fetch_add_explicit(&L->busyTicks, busy, RELAXED);
    if (busy > atomic_load_explicit(&L->maxTicks, RELAXED))
        atomic_store_explicit(&L->maxTicks, busy, RELAXED);
    if (atomic_fetch_add_explicit(&L->callbacks, 1, RELAXED) == 0)
        atomic_store_explicit(&L->firstHost, t0, RELAXED);
    atomic_store_explicit(&L->lastHost, t0, RELAXED);
    atomic_fetch_add_explicit(&L->frames, frames, RELAXED);
    atomic_store_explicit(&L->lastFrames, frames, RELAXED);
    return noErr;
}

static OSStatus overload_listener(AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *addrs, void *clientData)
{
    (void)obj;
    (void)n;
    (void)addrs;
    atomic_fetch_add_explicit(&((JDLive *)clientData)->overloads, 1, RELAXED);
    return noErr;
}

// ---------------------------------------------------------------------------------------------
// Control thread.

static const AudioObjectPropertyAddress kOverloadAddr = { kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };

static OSStatus get_u32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, uint32_t *out)
{
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    UInt32 size = sizeof *out;
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, out);
}

static AudioBufferList *get_stream_config(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size == 0)
        return NULL;
    AudioBufferList *abl = malloc(size);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, abl) != noErr) {
        free(abl);
        return NULL;
    }
    return abl;
}

// All streams in this scope must be packed native float32 for the IOProc's direct float access.
static int streams_are_float32(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr)
        return 0;
    UInt32 count = size / sizeof(AudioStreamID);
    AudioStreamID *ids = malloc(size ? size : 1);
    int ok = AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, ids) == noErr;
    for (UInt32 i = 0; ok && i < count; i++) {
        AudioStreamBasicDescription f;
        UInt32 fs = sizeof f;
        AudioObjectPropertyAddress fa = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        ok = AudioObjectGetPropertyData(ids[i], &fa, 0, NULL, &fs, &f) == noErr && f.mFormatID == kAudioFormatLinearPCM &&
             (f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mBitsPerChannel == 32 && !(f.mFormatFlags & kAudioFormatFlagIsBigEndian);
    }
    free(ids);
    return ok;
}

// The tap's channels are the last input channels of the aggregate (after any hardware inputs).
static int map_tap(const AudioBufferList *abl, uint32_t tapChannels, ChannelRef *l, ChannelRef *r)
{
    ChannelRef refs[2];
    uint32_t found = 0;
    for (int b = (int)abl->mNumberBuffers - 1; b >= 0 && found < tapChannels && found < 2; b--) {
        uint32_t nch = abl->mBuffers[b].mNumberChannels;
        for (int c = (int)nch - 1; c >= 0 && found < tapChannels && found < 2; c--)
            refs[found++] = (ChannelRef){ (uint32_t)b, (uint32_t)c, nch };
    }
    if (found == 0)
        return 0;
    // refs were collected back to front.
    if (tapChannels == 1 || found == 1) {
        *l = *r = refs[0];
    } else {
        *l = refs[1];
        *r = refs[0];
    }
    return 1;
}

static int map_output(const AudioBufferList *abl, ChannelRef *l, ChannelRef *r, uint32_t *total)
{
    ChannelRef refs[2];
    uint32_t found = 0, sum = 0;
    for (uint32_t b = 0; b < abl->mNumberBuffers; b++) {
        uint32_t nch = abl->mBuffers[b].mNumberChannels;
        sum += nch;
        for (uint32_t c = 0; c < nch && found < 2; c++)
            refs[found++] = (ChannelRef){ b, c, nch };
    }
    *total = sum;
    if (found == 0)
        return 0;
    *l = refs[0];
    *r = found > 1 ? refs[1] : refs[0];
    return 1;
}

JDLive *jd_live_create(AudioObjectID aggregate, AudioObjectID tap, JDDsp *dsp, char *err, size_t errLen)
{
#define FAIL(...) do { snprintf(err, errLen, __VA_ARGS__); jd_live_destroy(L); free(inCfg); free(outCfg); return NULL; } while (0)
    AudioBufferList *inCfg = NULL, *outCfg = NULL;
    JDLive *L = calloc(1, sizeof *L);
    L->aggregate = aggregate;
    L->dsp = dsp;  // owned from here on, freed by jd_live_destroy even if creation fails

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    L->ticksToSeconds = (double)tb.numer / tb.denom * 1e-9;

    Float64 rate = 0;
    UInt32 size = sizeof rate;
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(aggregate, &ra, 0, NULL, &size, &rate) != noErr || rate <= 0)
        FAIL("cannot read aggregate sample rate");
    L->info.sampleRate = rate;
    if (get_u32(aggregate, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &L->info.bufferFrames) != noErr)
        FAIL("cannot read aggregate buffer frame size");
    get_u32(aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &L->info.outputLatencyFrames);
    get_u32(aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &L->info.outputSafetyOffsetFrames);
    get_u32(aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, &L->info.inputLatencyFrames);
    get_u32(aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, &L->info.inputSafetyOffsetFrames);

    AudioStreamBasicDescription tapFmt;
    size = sizeof tapFmt;
    AudioObjectPropertyAddress ta = { kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(tap, &ta, 0, NULL, &size, &tapFmt) != noErr)
        FAIL("cannot read tap format");
    L->info.tapChannels = tapFmt.mChannelsPerFrame;

    inCfg = get_stream_config(aggregate, kAudioObjectPropertyScopeInput);
    outCfg = get_stream_config(aggregate, kAudioObjectPropertyScopeOutput);
    if (!inCfg || !outCfg)
        FAIL("cannot read aggregate stream configuration");
    if (!streams_are_float32(aggregate, kAudioObjectPropertyScopeInput) || !streams_are_float32(aggregate, kAudioObjectPropertyScopeOutput))
        FAIL("aggregate streams are not float32");
    L->expectInputBuffers = inCfg->mNumberBuffers;
    L->expectOutputBuffers = outCfg->mNumberBuffers;
    L->info.inputBuffers = inCfg->mNumberBuffers;
    L->info.outputBuffers = outCfg->mNumberBuffers;
    if (!map_tap(inCfg, L->info.tapChannels, &L->tapL, &L->tapR))
        FAIL("aggregate has no tap input channels");
    if (L->tapL.buffer != L->tapR.buffer || L->tapL.stride != L->tapR.stride)
        FAIL("tap channels split across buffers (unsupported in the spike)");
    if (!map_output(outCfg, &L->outL, &L->outR, &L->info.outputChannels))
        FAIL("aggregate has no output channels");
    if (L->outL.buffer != L->outR.buffer)
        FAIL("output L/R split across buffers (unsupported in the spike)");

    if (L->info.bufferFrames > MAX_FRAMES)
        FAIL("buffer of %u frames exceeds %u", L->info.bufferFrames, MAX_FRAMES);
    L->dryL = calloc(MAX_FRAMES, sizeof(float));
    L->dryR = calloc(MAX_FRAMES, sizeof(float));
    L->wetL = calloc(MAX_FRAMES, sizeof(float));
    L->wetR = calloc(MAX_FRAMES, sizeof(float));
    L->oldL = calloc(MAX_FRAMES, sizeof(float));
    L->oldR = calloc(MAX_FRAMES, sizeof(float));
    L->wetGain = 1.0f;
    L->wetStep = (float)(1.0 / (0.020 * rate));
    L->xfadeLength = (uint32_t)(0.040 * rate);

    L->outGain = 0.0f;
    L->fadeStep = (float)(1.0 / (0.020 * rate));
    if (AudioDeviceCreateIOProcID(aggregate, jd_ioproc, L, &L->procID) != noErr)
        FAIL("AudioDeviceCreateIOProcID failed");
    AudioObjectAddPropertyListener(aggregate, &kOverloadAddr, overload_listener, L);
    free(inCfg);
    free(outCfg);
    return L;
#undef FAIL
}

OSStatus jd_live_start(JDLive *L)
{
    return AudioDeviceStart(L->aggregate, L->procID);
}

OSStatus jd_live_stop(JDLive *L)
{
    return AudioDeviceStop(L->aggregate, L->procID);
}

void jd_live_destroy(JDLive *L)
{
    if (!L)
        return;
    if (L->procID) {
        AudioDeviceStop(L->aggregate, L->procID);
        AudioObjectRemovePropertyListener(L->aggregate, &kOverloadAddr, overload_listener, L);
        AudioDeviceDestroyIOProcID(L->aggregate, L->procID);
    }
    jd_dsp_free(L->dsp);
    jd_dsp_free(L->fading);
    jd_dsp_free(atomic_exchange(&L->pending, NULL));
    jd_dsp_free(atomic_exchange(&L->retired, NULL));
    free(L->dryL);
    free(L->dryR);
    free(L->wetL);
    free(L->wetR);
    free(L->oldL);
    free(L->oldR);
    free(L);
}

void jd_live_get_info(const JDLive *L, JDLiveInfo *out)
{
    *out = L->info;
}

static float bits_float(uint32_t u)
{
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}

void jd_live_read_stats(JDLive *L, JDLiveStats *s)
{
    const double k = L->ticksToSeconds;
    s->callbacks = atomic_load_explicit(&L->callbacks, RELAXED);
    s->frames = atomic_load_explicit(&L->frames, RELAXED);
    s->outputDiscontinuities = atomic_load_explicit(&L->outDisc, RELAXED);
    s->inputDiscontinuities = atomic_load_explicit(&L->inDisc, RELAXED);
    s->overloads = atomic_load_explicit(&L->overloads, RELAXED);
    s->zeroInputCallbacks = atomic_load_explicit(&L->zeroIn, RELAXED);
    s->unprocessedCallbacks = atomic_load_explicit(&L->unprocessed, RELAXED);
    s->layoutErrors = atomic_load_explicit(&L->layoutErrors, RELAXED);
    s->lastFrames = atomic_load_explicit(&L->lastFrames, RELAXED);
    s->busySeconds = atomic_load_explicit(&L->busyTicks, RELAXED) * k;
    s->maxCallbackSeconds = atomic_load_explicit(&L->maxTicks, RELAXED) * k;
    s->firstHostSeconds = atomic_load_explicit(&L->firstHost, RELAXED) * k;
    s->lastHostSeconds = atomic_load_explicit(&L->lastHost, RELAXED) * k;
    s->lastLatencySeconds = atomic_load_explicit(&L->lastLatencyTicks, RELAXED) * k;
    s->maxLatencySeconds = atomic_load_explicit(&L->maxLatencyTicks, RELAXED) * k;
    s->inPeak = bits_float(atomic_exchange_explicit(&L->inPeakBits, 0, RELAXED));
    s->outPeak = bits_float(atomic_exchange_explicit(&L->outPeakBits, 0, RELAXED));
    s->maxOutputStep = bits_float(atomic_exchange_explicit(&L->maxStepBits, 0, RELAXED));
}

void jd_live_set_bypass(JDLive *L, int bypass)
{
    atomic_store_explicit(&L->bypass, bypass != 0, RELAXED);
}

void jd_live_set_test_zero_input(JDLive *L, int on)
{
    atomic_store_explicit(&L->testZeroInput, on != 0, RELAXED);
}

void jd_live_post_dsp(JDLive *L, JDDsp *dsp)
{
    // Whoever takes a pointer out of `pending` owns it: the IOProc (exchange with NULL) or us here.
    jd_dsp_free(atomic_exchange_explicit(&L->pending, dsp, memory_order_acq_rel));
}

int jd_live_collect_retired(JDLive *L)
{
    JDDsp *old = atomic_exchange_explicit(&L->retired, NULL, memory_order_acq_rel);
    jd_dsp_free(old);
    return old != NULL;
}

void jd_live_fade_out(JDLive *L)
{
    atomic_store_explicit(&L->fadeOutRequested, 1, RELAXED);
}

int jd_live_faded_out(JDLive *L)
{
    return atomic_load_explicit(&L->fadedOut, RELAXED);
}

// ---------------------------------------------------------------------------------------------
// Permission probe.

typedef struct {
    float s, c, rs, rc;  // quadrature oscillator state and per-sample rotation
    float amplitude;
    int testZeroInput;
    _Atomic uint32_t peakBits;
} JDProbe;

static OSStatus jd_probe_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *in,
                                const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime,
                                void *clientData) CA_REALTIME_API
{
    (void)device; (void)now; (void)inTime; (void)outTime;
    JDProbe *P = (JDProbe *)clientData;
    // Measure: the probe tap is the aggregate's only tap, so its stream is the last input buffer.
    if (in->mNumberBuffers > 0 && !P->testZeroInput) {
        const AudioBuffer *b = &in->mBuffers[in->mNumberBuffers - 1];
        if (b->mData) {
            const float *x = (const float *)b->mData;
            const uint32_t n = b->mDataByteSize / sizeof(float);
            float peak = 0.0f;
            for (uint32_t i = 0; i < n; i++)
                peak = __builtin_fmaxf(peak, __builtin_fabsf(x[i]));
            raise_peak(&P->peakBits, peak);
        }
    }
    // Play the tone on every output channel. This is our process's output, which the tap captures.
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *ob = &out->mBuffers[b];
        if (!ob->mData || ob->mNumberChannels == 0)
            continue;
        float *y = (float *)ob->mData;
        const uint32_t nch = ob->mNumberChannels, frames = ob->mDataByteSize / (nch * sizeof(float));
        float s = P->s, c = P->c;
        for (uint32_t i = 0; i < frames; i++) {
            const float v = P->amplitude * s;
            for (uint32_t ch = 0; ch < nch; ch++)
                y[i * nch + ch] = v;
            const float s2 = s * P->rc + c * P->rs;
            c = c * P->rc - s * P->rs;
            s = s2;
        }
        if (b == out->mNumberBuffers - 1) {
            // Renormalise to stop amplitude drift of the recursive oscillator.
            const float g = 1.5f - 0.5f * (s * s + c * c);
            P->s = s * g;
            P->c = c * g;
        }
    }
    return noErr;
}

float jd_probe_run(AudioObjectID aggregate, double seconds, int testZeroInput, OSStatus *status)
{
    Float64 rate = 48000;
    UInt32 size = sizeof rate;
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(aggregate, &ra, 0, NULL, &size, &rate);
    JDProbe *P = calloc(1, sizeof *P);
    const double w = 2.0 * 3.14159265358979323846 * 1000.0 / rate;
    P->s = 0.0f;
    P->c = 1.0f;
    P->rs = (float)sin(w);
    P->rc = (float)cos(w);
    P->amplitude = 1.0e-5f;  // -100 dBFS
    P->testZeroInput = testZeroInput;

    AudioDeviceIOProcID procID = NULL;
    OSStatus err = AudioDeviceCreateIOProcID(aggregate, jd_probe_ioproc, P, &procID);
    if (err == noErr)
        err = AudioDeviceStart(aggregate, procID);
    float peak = 0.0f;
    if (err == noErr) {
        for (double waited = 0; waited < seconds; waited += 0.01) {
            usleep(10000);
            peak = bits_float(atomic_load(&P->peakBits));
            if (peak > 0.0f && waited >= 0.05)
                break;
        }
        AudioDeviceStop(aggregate, procID);
    }
    if (procID)
        AudioDeviceDestroyIOProcID(aggregate, procID);
    free(P);
    if (status)
        *status = err;
    return peak;
}

// ---------------------------------------------------------------------------------------------
// Crash cleanup.

// AudioHardwareTapping.h (macOS 27 SDK) is wrapped in #ifdef __OBJC__ because its create function
// takes a CATapDescription. The destroy function is plain C (AudioObjectID in, OSStatus out).
extern OSStatus AudioHardwareDestroyProcessTap(AudioObjectID inTapID);

#define CLEANUP_SLOTS 8
static _Atomic AudioObjectID gTrackedAggregate[CLEANUP_SLOTS], gTrackedTap[CLEANUP_SLOTS];

void jd_panic(void)
{
    for (int i = 0; i < CLEANUP_SLOTS; i++) {
        // Take ownership atomically so two callers (signal + UI) never destroy an object twice.
        AudioObjectID agg = atomic_exchange(&gTrackedAggregate[i], kAudioObjectUnknown);
        AudioObjectID tap = atomic_exchange(&gTrackedTap[i], kAudioObjectUnknown);
        // Mach IPC to coreaudiod; no use of this process's heap state. Best effort.
        if (agg != kAudioObjectUnknown)
            AudioHardwareDestroyAggregateDevice(agg);
        if (tap != kAudioObjectUnknown)
            AudioHardwareDestroyProcessTap(tap);
    }
}

static void crash_handler(int sig)
{
    jd_panic();
    signal(sig, SIG_DFL);
    raise(sig);
}

void jd_cleanup_install(void)
{
    const int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++)
        signal(sigs[i], crash_handler);
}

int jd_cleanup_track(AudioObjectID aggregate, AudioObjectID tap)
{
    for (int i = 0; i < CLEANUP_SLOTS; i++) {
        AudioObjectID expected = kAudioObjectUnknown;
        if (atomic_compare_exchange_strong(&gTrackedAggregate[i], &expected, aggregate)) {
            atomic_store(&gTrackedTap[i], tap);
            return i;
        }
    }
    return -1;
}

void jd_cleanup_untrack(int slot)
{
    if (slot < 0 || slot >= CLEANUP_SLOTS)
        return;
    atomic_store(&gTrackedTap[slot], kAudioObjectUnknown);
    atomic_store(&gTrackedAggregate[slot], kAudioObjectUnknown);
}
