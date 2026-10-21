// jdsp-offline: run libjamesdsp on WAV files, golden self-checks and liveprog CPU measurement.
// Offline only. Nothing here runs on an audio thread.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

#include "jdsp_header.h"
#include "Effects/eel2/ns-eel.h"
#include "Effects/eel2/dr_wav.h"

typedef struct {
    int block;
    int bypass;
    int eqOn, eqType, eqInterp;
    double eq[30];          // 15 freqs, then 15 gains in dB (audio.conf tone_eq layout)
    int reverbOn;
    const char *liveprog;
} Options;

static const double kEqFreqs[15] = { 25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000 };

static double now_seconds(void)
{
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0)
        mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom * 1e-9;
}

static char *read_text_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (buf && fread(buf, 1, (size_t)len, f) != (size_t)len) {
        free(buf);
        buf = NULL;
    }
    if (buf)
        buf[len] = 0;
    fclose(f);
    return buf;
}

// Builds an instance and applies options. Returns NULL (with a message on stderr) on failure.
static JamesDSPLib *engine_new(float fs, const Options *o, double *compileMs)
{
    static int globalInit = 0;
    if (!globalInit) {
        JamesDSPGlobalMemoryAllocation();
        globalInit = 1;
    }
    JamesDSPLib *d = calloc(1, sizeof *d);
    JamesDSPInit(d, o->block, fs);
    if (!JamesDSPGetMutexStatus(d)) {
        fprintf(stderr, "JamesDSPInit: mutex init failed\n");
        return NULL;
    }
    if (o->eqOn) {
        MultimodalEqualizerAxisInterpolation(d, o->eqInterp, o->eqType, (double *)o->eq, (double *)o->eq + 15);
        MultimodalEqualizerEnable(d, 1);
    }
    if (o->reverbOn) {
        // JDSP4Linux resources/assets/default.conf reverb_* values, argument order as DspHost::updateReverb.
        sf_advancereverb(&d->reverb, (int)d->fs, 1, 0.3f, -9.0f, -7.0f, 1.0f, 0.7f, 1.0f, -8.0f,
                         0.3f, 0.25f, 0.7f, 18000, 600, 9000, 17000, 2.1f, 0.0f);
        ReverbEnable(d);
    }
    if (o->liveprog) {
        char *code = read_text_file(o->liveprog);
        if (!code) {
            fprintf(stderr, "cannot read %s\n", o->liveprog);
            return NULL;
        }
        double t0 = now_seconds();
        int ret = LiveProgStringParser(d, code);
        if (compileMs)
            *compileMs = (now_seconds() - t0) * 1000.0;
        free(code);
        if (ret <= 0) {
            const char *err = NSEEL_code_getcodeerror(d->eel.vm);
            fprintf(stderr, "%s: %s%s%s\n", o->liveprog, checkErrorCode(ret), err ? ": " : "", err ? err : "");
            return NULL;
        }
        LiveProgEnable(d);
    }
    return d;
}

static void engine_free(JamesDSPLib *d)
{
    JamesDSPFree(d);
    free(d);
}

// Processes planar stereo in fixed-size blocks (the last block is zero-padded so n never changes).
// Returns processing time in seconds.
static double run(JamesDSPLib *d, const Options *o, const float *inL, const float *inR,
                  float *outL, float *outR, size_t frames)
{
    const size_t n = (size_t)o->block;
    float *pl = calloc(n, sizeof(float)), *pr = calloc(n, sizeof(float));
    float *ql = calloc(n, sizeof(float)), *qr = calloc(n, sizeof(float));
    double busy = 0.0;
    for (size_t pos = 0; pos < frames; pos += n) {
        size_t len = frames - pos < n ? frames - pos : n;
        memset(pl, 0, n * sizeof(float));
        memset(pr, 0, n * sizeof(float));
        memcpy(pl, inL + pos, len * sizeof(float));
        memcpy(pr, inR + pos, len * sizeof(float));
        double t0 = now_seconds();
        if (o->bypass) {
            memcpy(ql, pl, n * sizeof(float));
            memcpy(qr, pr, n * sizeof(float));
        } else {
            d->processFloatDeinterleaved(d, pl, pr, ql, qr, n);
        }
        busy += now_seconds() - t0;
        memcpy(outL + pos, ql, len * sizeof(float));
        memcpy(outR + pos, qr, len * sizeof(float));
    }
    free(pl); free(pr); free(ql); free(qr);
    return busy;
}

// ---------------------------------------------------------------------------------------------
// Signal helpers

static uint32_t lcg_state = 12345u;
static float noise(void)
{
    lcg_state = lcg_state * 1664525u + 1013904223u;
    return (float)((double)lcg_state / 4294967296.0 - 0.5);  // uniform -0.5 .. 0.5
}

static double rms(const float *x, size_t from, size_t to)
{
    double s = 0.0;
    for (size_t i = from; i < to; i++)
        s += (double)x[i] * x[i];
    return sqrt(s / (double)(to - from));
}

static int all_finite(const float *x, size_t n, float *peak)
{
    float p = 0.0f;
    for (size_t i = 0; i < n; i++) {
        if (!isfinite(x[i]))
            return 0;
        if (fabsf(x[i]) > p)
            p = fabsf(x[i]);
    }
    *peak = p;
    return 1;
}

static void options_default(Options *o)
{
    memset(o, 0, sizeof *o);
    o->block = 512;
    memcpy(o->eq, kEqFreqs, sizeof kEqFreqs);
}

// ---------------------------------------------------------------------------------------------
// selftest: Phase 1 golden checks

static int check_effects_off_bitexact(float fs)
{
    Options o;
    options_default(&o);
    size_t frames = (size_t)(fs * 2);
    float *l = malloc(frames * 4), *r = malloc(frames * 4), *ol = malloc(frames * 4), *or_ = malloc(frames * 4);
    lcg_state = 1;
    for (size_t i = 0; i < frames; i++) { l[i] = noise(); r[i] = noise(); }
    JamesDSPLib *d = engine_new(fs, &o, NULL);
    run(d, &o, l, r, ol, or_, frames);
    engine_free(d);
    float maxDiff = 0.0f;
    for (size_t i = 0; i < frames; i++) {
        maxDiff = fmaxf(maxDiff, fabsf(ol[i] - l[i]));
        maxDiff = fmaxf(maxDiff, fabsf(or_[i] - r[i]));
    }
    int exact = memcmp(ol, l, frames * 4) == 0 && memcmp(or_, r, frames * 4) == 0;
    printf("  effects off, %5.0f Hz: %s (max |diff| %.3g)\n", fs, exact ? "bit-exact" : "NOT bit-exact", maxDiff);
    free(l); free(r); free(ol); free(or_);
    return exact;
}

// Designed magnitude (dB) at f of the IIR EQ for these nodes, computed the same way the library
// designs it (MultimodalEqualizerAxisInterpolation, IIR branch): one HSHO shelf per node step.
static double iir_design_db(double fs, int order, const double *freq, const double *gain, double f)
{
    double re = 1.0, im = 0.0;
    for (int i = 0; i < 14; i++) {
        double designFreq = i ? (freq[i + 1] + freq[i]) * 0.5 : freq[i];
        HSHOResponse(fs, designFreq, order, gain[i + 1] - gain[i], i == 0 ? gain[i] : 0.0, 1, &f, &re, &im);
    }
    return 20.0 * log10(hypot(re, im));
}

// FIR: the curve passes through the node, so expect +6 dB. IIR: the shelves sit between nodes and
// a single +6 dB node does not reach +6 dB, so expect the library's own designed response.
static int check_eq_6db(float fs, int eqType)
{
    Options o;
    options_default(&o);
    o.eqOn = 1;
    o.eqType = eqType;
    o.eq[15 + 8] = 6.0;  // band 9 is 1000 Hz
    size_t frames = (size_t)(fs * 3);
    float *l = malloc(frames * 4), *ol = malloc(frames * 4), *or_ = malloc(frames * 4);
    for (size_t i = 0; i < frames; i++)
        l[i] = 0.25f * (float)sin(2.0 * M_PI * 1000.0 * (double)i / fs);
    JamesDSPLib *d = engine_new(fs, &o, NULL);
    run(d, &o, l, l, ol, or_, frames);
    engine_free(d);
    size_t from = (size_t)fs, to = frames;  // skip the first second (filter settling)
    double gainL = 20.0 * log10(rms(ol, from, to) / rms(l, from, to));
    double gainR = 20.0 * log10(rms(or_, from, to) / rms(l, from, to));
    static const int iirOrder[6] = { 0, 4, 6, 8, 10, 12 };
    double expected = eqType == 0 ? 6.0 : iir_design_db(fs, iirOrder[eqType], o.eq, o.eq + 15, 1000.0);
    int ok = fabs(gainL - expected) < 0.25 && fabs(gainR - expected) < 0.25;
    printf("  EQ +6 dB node @ 1 kHz, %s order %2d, %5.0f Hz: L %+.3f dB, R %+.3f dB, expected %+.3f -> %s\n",
           eqType == 0 ? "FIR" : "IIR", eqType == 0 ? 0 : iirOrder[eqType], fs, gainL, gainR, expected, ok ? "ok" : "FAIL");
    free(l); free(ol); free(or_);
    return ok;
}

static int check_reverb_sweep(float fs)
{
    Options o;
    options_default(&o);
    o.reverbOn = 1;
    size_t sweep = (size_t)(fs * 4), frames = sweep * 2;  // 4 s sweep, 4 s silence
    float *l = calloc(frames, 4), *ol = malloc(frames * 4), *or_ = malloc(frames * 4);
    const double f0 = 20.0, f1 = 20000.0, T = 4.0, k = log(f1 / f0);
    for (size_t i = 0; i < sweep; i++) {
        double t = (double)i / fs;
        l[i] = 0.5f * (float)sin(2.0 * M_PI * f0 * T / k * (exp(t / T * k) - 1.0));
    }
    JamesDSPLib *d = engine_new(fs, &o, NULL);
    run(d, &o, l, l, ol, or_, frames);
    engine_free(d);
    float pl = 0.0f, pr = 0.0f;
    int finite = all_finite(ol, frames, &pl) && all_finite(or_, frames, &pr);
    double sweepRms = rms(ol, 0, sweep);
    double tailRms = rms(ol, frames - (size_t)(fs / 2), frames);
    int ok = finite && tailRms < sweepRms * 0.01;  // tail at least 40 dB down after 3.5 s
    if (finite)
        printf("  reverb log sweep, %5.0f Hz: finite, peak L %.3f R %.3f, tail %.1f dB re sweep -> %s\n",
               fs, pl, pr, 20.0 * log10(tailRms / sweepRms + 1e-30), ok ? "ok" : "FAIL");
    else
        printf("  reverb log sweep, %5.0f Hz: NaN/Inf in output -> FAIL\n", fs);
    free(l); free(ol); free(or_);
    return ok;
}

static int cmd_selftest(void)
{
    const float rates[2] = { 44100.0f, 48000.0f };
    int failures = 0;
    printf("selftest (block 512)\n");
    for (int i = 0; i < 2; i++) failures += !check_effects_off_bitexact(rates[i]);
    for (int i = 0; i < 2; i++) failures += !check_eq_6db(rates[i], 0);
    for (int i = 0; i < 2; i++) failures += !check_eq_6db(rates[i], 1);
    for (int i = 0; i < 2; i++) failures += !check_eq_6db(rates[i], 5);
    for (int i = 0; i < 2; i++) failures += !check_reverb_sweep(rates[i]);
    printf("%s (%d failed)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}

// ---------------------------------------------------------------------------------------------
// bench-liveprog: CPU of liveprog scripts relative to real time

static int cmd_bench_liveprog(int argc, char **argv)
{
    const float fs = 48000.0f;
    const double seconds = 20.0;
    size_t frames = (size_t)(fs * seconds);
    float *l = malloc(frames * 4), *r = malloc(frames * 4), *ol = malloc(frames * 4), *or_ = malloc(frames * 4);
    lcg_state = 7;
    for (size_t i = 0; i < frames; i++) { l[i] = 0.5f * noise(); r[i] = 0.5f * noise(); }
    printf("%-36s %10s %10s %8s  %s\n", "script (48 kHz, block 512, 20 s noise)", "compile ms", "CPU %", "peak", "result");
    int failures = 0;
    for (int a = 0; a < argc; a++) {
        Options o;
        options_default(&o);
        o.liveprog = argv[a];
        double compileMs = 0.0;
        fflush(stdout);
        JamesDSPLib *d = engine_new(fs, &o, &compileMs);
        const char *name = strrchr(argv[a], '/') ? strrchr(argv[a], '/') + 1 : argv[a];
        if (!d) {
            printf("%-36s %10s %10s %8s  %s\n", name, "-", "-", "-", "compile error");
            failures++;
            continue;
        }
        double busy = run(d, &o, l, r, ol, or_, frames);
        engine_free(d);
        float pl = 0, pr = 0;
        int finite = all_finite(ol, frames, &pl) && all_finite(or_, frames, &pr);
        printf("%-36s %10.1f %10.2f %8.3f  %s\n", name, compileMs, busy / seconds * 100.0,
               fmaxf(pl, pr), finite ? "ok" : "NaN/Inf");
        failures += !finite;
    }
    free(l); free(r); free(ol); free(or_);
    return failures ? 1 : 0;
}

// ---------------------------------------------------------------------------------------------
// process: WAV in -> WAV out

static int parse_list(const char *s, double *out, int count)
{
    int i = 0;
    char *end;
    while (i < count && *s) {
        out[i++] = strtod(s, &end);
        if (end == s)
            return 0;
        s = (*end == ';') ? end + 1 : end;
    }
    return i == count && *s == 0;
}

static int cmd_process(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "process needs <in.wav> <out.wav>\n");
        return 2;
    }
    Options o;
    options_default(&o);
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--block") && i + 1 < argc) o.block = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--bypass")) o.bypass = 1;
        else if (!strcmp(argv[i], "--reverb")) o.reverbOn = 1;
        else if (!strcmp(argv[i], "--liveprog") && i + 1 < argc) o.liveprog = argv[++i];
        else if (!strcmp(argv[i], "--eq-type") && i + 1 < argc) o.eqType = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--eq-interp") && i + 1 < argc) o.eqInterp = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--eq") && i + 1 < argc) {
            o.eqOn = 1;
            if (!parse_list(argv[++i], o.eq, 30)) {
                fprintf(stderr, "--eq wants 30 ';'-separated numbers (audio.conf tone_eq)\n");
                return 2;
            }
        } else {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            return 2;
        }
    }
    if (o.block < 64) {
        fprintf(stderr, "--block must be >= 64\n");
        return 2;
    }
    unsigned int ch, fs;
    drwav_uint64 frames;
    float *in = drwav_open_file_and_read_pcm_frames_f32(argv[0], &ch, &fs, &frames, NULL);
    if (!in) {
        fprintf(stderr, "cannot read %s\n", argv[0]);
        return 1;
    }
    if (ch < 1 || ch > 2) {
        fprintf(stderr, "only mono or stereo input is supported (got %u channels)\n", ch);
        return 1;
    }
    float *l = malloc(frames * 4), *r = malloc(frames * 4), *ol = malloc(frames * 4), *or_ = malloc(frames * 4);
    for (drwav_uint64 i = 0; i < frames; i++) {
        l[i] = in[i * ch];
        r[i] = in[i * ch + (ch - 1)];
    }
    JamesDSPLib *d = o.bypass ? NULL : engine_new((float)fs, &o, NULL);
    if (!o.bypass && !d)
        return 1;
    double busy = run(d, &o, l, r, ol, or_, (size_t)frames);
    if (d)
        engine_free(d);
    float *out = malloc(frames * 2 * 4);
    for (drwav_uint64 i = 0; i < frames; i++) {
        out[i * 2] = ol[i];
        out[i * 2 + 1] = or_[i];
    }
    drwav_data_format fmt = { drwav_container_riff, DR_WAVE_FORMAT_IEEE_FLOAT, 2, fs, 32 };
    drwav wav;
    if (!drwav_init_file_write(&wav, argv[1], &fmt, NULL)) {
        fprintf(stderr, "cannot write %s\n", argv[1]);
        return 1;
    }
    drwav_write_pcm_frames(&wav, frames, out);
    drwav_uninit(&wav);
    double dur = (double)frames / fs;
    printf("%llu frames @ %u Hz, %u ch in, block %d: %.3f s audio, %.3f s CPU (%.2f%% of real time)\n",
           (unsigned long long)frames, fs, ch, o.block, dur, busy, busy / dur * 100.0);
    drwav_free(in, NULL);
    free(l); free(r); free(ol); free(or_); free(out);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "process"))
        return cmd_process(argc - 2, argv + 2);
    if (argc >= 2 && !strcmp(argv[1], "selftest"))
        return cmd_selftest();
    if (argc >= 3 && !strcmp(argv[1], "bench-liveprog"))
        return cmd_bench_liveprog(argc - 2, argv + 2);
    fprintf(stderr,
            "usage:\n"
            "  jdsp-offline process <in.wav> <out.wav> [--block N] [--bypass] [--reverb]\n"
            "                       [--eq \"<15 freqs;15 gains>\" --eq-type N --eq-interp N] [--liveprog file.eel]\n"
            "  jdsp-offline selftest\n"
            "  jdsp-offline bench-liveprog <file.eel>...\n");
    return 2;
}
