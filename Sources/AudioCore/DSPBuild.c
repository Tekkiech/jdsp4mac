// Builds one libjamesdsp instance from a full settings snapshot, off the audio thread.
// Application order and clamps follow JDSP4Linux src/audio/base/DspHost.cpp (docs/dsphost-map.md):
// per-key settings in DspConfig::Key order, then the grouped refreshes (reverb, convolver,
// liveprog, graphic EQ, DDC, crossfeed, compander, stereo widener). Written from that description,
// not copied.

#include "AudioCore.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "JdspImpResToolbox.h"
#include "jd_messages.h"
#include "jdsp_header.h"
#include "Effects/eel2/ns-eel.h"

struct JDDsp {
    JamesDSPLib lib;
    uint32_t block;
};

static void note(char *messages, size_t len, const char *format, ...)
{
    if (!messages || len == 0)
        return;
    size_t used = strlen(messages);
    if (used + 2 >= len)
        return;
    if (used > 0)
        messages[used++] = '\n';
    va_list ap;
    va_start(ap, format);
    vsnprintf(messages + used, len - used, format, ap);
    va_end(ap);
}

JDDsp *jd_dsp_build(const JDParams *p, uint32_t block, double sampleRate, char *messages, size_t messagesLen)
{
    static int globalInit = 0;
    if (!globalInit) {
        JamesDSPGlobalMemoryAllocation();
        globalInit = 1;
    }
    if (messages && messagesLen)
        messages[0] = 0;
    JDDsp *d = calloc(1, sizeof *d);
    JamesDSPLib *j = &d->lib;
    d->block = block;
    JamesDSPInit(j, (int)block, (float)sampleRate);

    // --- per-key settings (DspConfig::Key order) ---
    if (p->bassEnable) BassBoostEnable(j); else BassBoostDisable(j);
    BassBoostSetParam(j, p->bassMaxGainDb);
    if (p->companderEnable) CompressorEnable(j, 1); else CompressorDisable(j);
    if (p->crossfeedEnable) CrossfeedEnable(j, 1); else CrossfeedDisable(j);
    if (p->reverbEnable) ReverbEnable(j); else ReverbDisable(j);
    // updateLimiter: threshold <= -0.09 dB, release >= 0.15 ms.
    JLimiterSetCoefficients(j, p->limThresholdDb > -0.09f ? -0.09f : p->limThresholdDb,
                            p->limReleaseMs < 0.15f ? 0.15f : p->limReleaseMs);
    JamesDSPSetPostGain(j, p->postGainDb);
    if (p->toneEnable) MultimodalEqualizerEnable(j, 1); else MultimodalEqualizerDisable(j);
    if (p->toneEQValid) {
        double eq[30];
        memcpy(eq, p->toneEQ, sizeof eq);
        MultimodalEqualizerAxisInterpolation(j, p->toneInterpolation, p->toneFilterType, eq, eq + 15);
    } else if (p->toneEnable) {
        note(messages, messagesLen, "EQ: tone_eq needs 30 values; EQ curve left flat");
    }
    if (p->tubeEnable) VacuumTubeEnable(j); else VacuumTubeDisable(j);
    VacuumTubeSetGain(j, p->tubePregain / 100.0f);

    // --- grouped refreshes (DspHost::update order) ---
    sf_advancereverb(&j->reverb, (int)j->fs, p->reverbOSF, p->reverbReflectionAmount, p->reverbFinalWet, p->reverbFinalDry,
                     p->reverbReflectionFactor, p->reverbReflectionWidth, p->reverbWidth, p->reverbWet, p->reverbLFOWander,
                     p->reverbBassBoost, p->reverbLFOSpin, p->reverbLPFInput, p->reverbLPFBass, p->reverbLPFDamp,
                     p->reverbLPFOutput, p->reverbDecay, p->reverbDelayMs / 1000.0f);

    if (p->convolverEnable) {
        if (!p->convolverPath || !p->convolverPath[0]) {
            note(messages, messagesLen, "Convolver: no impulse response file; convolver off");
        } else {
            int info[2] = { 0, 0 };
            int edit[6];
            memcpy(edit, p->convolverWaveformEdit, sizeof edit);
            float *ir = ReadImpulseResponseToFloat(p->convolverPath, (int)j->fs, info, p->convolverOptimizationMode, edit);
            if (!ir || info[1] <= 0 || !(info[0] == 1 || info[0] == 2 || info[0] == 4)) {
                note(messages, messagesLen, "Convolver: cannot use \"%s\" (unreadable, empty, or %d channels; need 1, 2 or 4); convolver off",
                     p->convolverPath, info[0]);
            } else if (Convolver1DLoadImpulseResponse(j, ir, (unsigned int)info[0], (size_t)info[1], 1) <= 0) {
                note(messages, messagesLen, "Convolver: libjamesdsp rejected the impulse response; convolver off");
            } else {
                Convolver1DEnable(j);
            }
            free(ir);
        }
    }

    if (p->liveprogEnable) {
        if (!p->liveprogText) {
            note(messages, messagesLen, "Liveprog: script file not found; liveprog off");
        } else {
            char *code = strdup(p->liveprogText);
            int ret = LiveProgStringParser(j, code);
            free(code);
            const char *err = NSEEL_code_getcodeerror(j->eel.vm);
            if (ret <= 0) {
                note(messages, messagesLen, "Liveprog: %s%s%s; liveprog off", checkErrorCode(ret), err ? ": " : "", err ? err : "");
            } else {
                LiveProgEnable(j);
            }
        }
    }

    if (p->graphicEQEnable) {
        if (!p->graphicEQ || !p->graphicEQ[0]) {
            note(messages, messagesLen, "Graphic EQ: empty graphiceq_param; graphic EQ off");
        } else {
            char *eq = strdup(p->graphicEQ);
            ArbitraryResponseEqualizerStringParser(j, eq);
            free(eq);
            ArbitraryResponseEqualizerEnable(j, 1);
        }
    }

    if (p->ddcEnable) {
        if (!p->ddcText) {
            note(messages, messagesLen, "DDC: .vdc file not found; DDC off");
        } else {
            char *vdc = strdup(p->ddcText);
            DDCStringParser(j, vdc);
            free(vdc);
            if (DDCEnable(j, 1) <= 0) {
                note(messages, messagesLen, "DDC: invalid .vdc contents; DDC off");
                DDCDisable(j);
            }
        }
    }

    // updateCrossfeed: modes 99 (custom) and 0 (weak) set BS2B directly (CrossfeedChangeMode(0)
    // loses audio, per the JDSP4Linux comment); weak uses fcut 700, feed 65.
    if (p->crossfeedMode == 99 || p->crossfeedMode == 0) {
        int fcut = p->crossfeedMode == 0 ? 700 : p->crossfeedFcut;
        int feed = p->crossfeedMode == 0 ? 65 : p->crossfeedFeed;
        memset(&j->advXF.bs2b, 0, sizeof j->advXF.bs2b);
        BS2BInit(&j->advXF.bs2b[1], (unsigned int)j->fs, (unsigned int)fcut | ((unsigned int)feed << 16));
        j->advXF.mode = 1;
    } else {
        CrossfeedChangeMode(j, p->crossfeedMode);
    }

    // updateCompander: granularity >= 2, time constant >= 0.22 s; ignored without 14 values.
    if (p->companderResponseValid) {
        double resp[14];
        memcpy(resp, p->companderResponse, sizeof resp);
        CompressorSetParam(j, p->companderTimeConstant < 0.22f ? 0.22f : p->companderTimeConstant,
                           p->companderGranularity < 2 ? 2 : p->companderGranularity, p->companderTransforms, 0);
        CompressorSetGain(j, resp, resp + 7, 1);
    } else if (p->companderEnable) {
        note(messages, messagesLen, "Compander: compander_response needs 14 values; compander settings ignored");
    }

    if (p->stereowideEnable) StereoEnhancementEnable(j); else StereoEnhancementDisable(j);
    StereoEnhancementSetParam(j, p->stereowideLevel / 100.0f);

    // Warm-up at the live block size: first-call work happens here, not on the audio thread.
    float *z = calloc((size_t)block * 4, sizeof(float));
    j->processFloatDeinterleaved(j, z, z + block, z + 2 * block, z + 3 * block, block);
    free(z);
    return d;
}

void jd_dsp_free(JDDsp *d)
{
    if (!d)
        return;
    JamesDSPFree(&d->lib);
    free(d);
}

void jd_dsp_process(JDDsp *d, const float *inL, const float *inR, float *outL, float *outR, uint32_t frames)
{
    d->lib.processFloatDeinterleaved(&d->lib, (float *)inL, (float *)inR, outL, outR, frames);
}

uint32_t jd_drain_messages(void (*sink)(const char *text, void *context), void *context)
{
    return jd_messages_drain(sink, context);
}
