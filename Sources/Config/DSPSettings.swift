import Foundation

/// Every JDSP4Linux `audio.conf` setting (51 keys, `DspConfig::Key`), typed. Missing keys take the
/// value from JDSP4Linux's default.conf. Conversions follow JDSP4Linux `DspHost` (see
/// docs/dsphost-map.md); value *clamping* happens where DspHost clamps, when the engine applies
/// the settings, so the file keeps what the user wrote.
public struct DSPSettings: Equatable, Sendable {
    public static let allKeys: [String] = [
        "bass_enable", "bass_maxgain",
        "compander_enable", "compander_response", "compander_granularity", "compander_timeconstant", "compander_time_freq_transforms",
        "convolver_enable", "convolver_file", "convolver_optimization_mode", "convolver_waveform_edit",
        "crossfeed_bs2b_fcut", "crossfeed_bs2b_feed", "crossfeed_enable", "crossfeed_mode",
        "ddc_enable", "ddc_file",
        "graphiceq_enable", "graphiceq_param",
        "reverb_bassboost", "reverb_decay", "reverb_delay", "reverb_enable", "reverb_finaldry", "reverb_finalwet",
        "reverb_lfo_spin", "reverb_lfo_wander", "reverb_lpf_bass", "reverb_lpf_damp", "reverb_lpf_input", "reverb_lpf_output",
        "reverb_osf", "reverb_reflection_amount", "reverb_reflection_factor", "reverb_reflection_width", "reverb_wet", "reverb_width",
        "liveprog_enable", "liveprog_file",
        "master_enable", "master_limrelease", "master_limthreshold", "master_postgain",
        "stereowide_enable", "stereowide_level",
        "tone_enable", "tone_eq", "tone_filtertype", "tone_interpolation",
        "tube_enable", "tube_pregain",
    ]

    public static let defaults = DSPSettings(conf: AudioConf(text: DefaultConf.text), fallback: nil)

    // master
    public var masterEnable: Bool
    public var postGain: Double              // dB
    public var limThreshold: Double          // dB
    public var limRelease: Double            // ms
    // bass boost
    public var bassEnable: Bool
    public var bassMaxGain: Double           // dB
    // compander
    public var companderEnable: Bool
    public var companderTimeConstant: Double // s
    public var companderGranularity: Int
    public var companderTransforms: Int      // 0 STFT, 1 CWT, 2 undersampled, 3 time domain
    public var companderResponse: String     // 14 values "f1;..;f7;g1;..;g7"
    // FIR/IIR EQ
    public var toneEnable: Bool
    public var toneFilterType: Int           // 0 FIR min-phase, 1-5 IIR order 4..12
    public var toneInterpolation: Int        // 0 pchip, 1 makima
    public var toneEQ: String                // 30 values "15 freqs;15 gains"
    // arbitrary-response EQ (AutoEQ GraphicEQ)
    public var graphicEQEnable: Bool
    public var graphicEQParam: String
    // reverb
    public var reverbEnable: Bool
    public var reverbOSF: Int
    public var reverbReflectionAmount: Double
    public var reverbFinalWet: Double
    public var reverbFinalDry: Double
    public var reverbReflectionFactor: Double
    public var reverbReflectionWidth: Double
    public var reverbWidth: Double
    public var reverbWet: Double
    public var reverbLFOWander: Double
    public var reverbBassBoost: Double
    public var reverbLFOSpin: Double
    public var reverbLPFInput: Int
    public var reverbLPFBass: Int
    public var reverbLPFDamp: Int
    public var reverbLPFOutput: Int
    public var reverbDecay: Double
    public var reverbDelay: Double           // ms
    // convolver
    public var convolverEnable: Bool
    public var convolverFile: String
    public var convolverOptimizationMode: Int
    public var convolverWaveformEdit: String // 6 ints
    // crossfeed
    public var crossfeedEnable: Bool
    public var crossfeedMode: Int            // 99 custom, 0 weak, 1 strong, 2-5 HRTF
    public var crossfeedFcut: Int
    public var crossfeedFeed: Int
    // ViPER DDC
    public var ddcEnable: Bool
    public var ddcFile: String
    // liveprog
    public var liveprogEnable: Bool
    public var liveprogFile: String
    // stereo widener
    public var stereowideEnable: Bool
    public var stereowideLevel: Double       // 0-100
    // vacuum tube
    public var tubeEnable: Bool
    public var tubePregain: Double           // hundredths of a dB

    public init(conf: AudioConf) {
        self.init(conf: conf, fallback: AudioConf(text: DefaultConf.text))
    }

    private init(conf: AudioConf, fallback: AudioConf?) {
        let r = Reader(conf: conf, fallback: fallback)
        masterEnable = r.bool("master_enable")
        postGain = r.double("master_postgain")
        limThreshold = r.double("master_limthreshold")
        limRelease = r.double("master_limrelease")
        bassEnable = r.bool("bass_enable")
        bassMaxGain = r.double("bass_maxgain")
        companderEnable = r.bool("compander_enable")
        companderTimeConstant = r.double("compander_timeconstant")
        companderGranularity = r.int("compander_granularity")
        companderTransforms = r.int("compander_time_freq_transforms")
        companderResponse = r.string("compander_response")
        toneEnable = r.bool("tone_enable")
        toneFilterType = Int(r.double("tone_filtertype"))
        toneInterpolation = Int(r.double("tone_interpolation"))
        toneEQ = r.string("tone_eq")
        graphicEQEnable = r.bool("graphiceq_enable")
        graphicEQParam = r.string("graphiceq_param")
        reverbEnable = r.bool("reverb_enable")
        reverbOSF = r.int("reverb_osf")
        reverbReflectionAmount = r.double("reverb_reflection_amount")
        reverbFinalWet = r.double("reverb_finalwet")
        reverbFinalDry = r.double("reverb_finaldry")
        reverbReflectionFactor = r.double("reverb_reflection_factor")
        reverbReflectionWidth = r.double("reverb_reflection_width")
        reverbWidth = r.double("reverb_width")
        reverbWet = r.double("reverb_wet")
        reverbLFOWander = r.double("reverb_lfo_wander")
        reverbBassBoost = r.double("reverb_bassboost")
        reverbLFOSpin = r.double("reverb_lfo_spin")
        reverbLPFInput = r.int("reverb_lpf_input")
        reverbLPFBass = r.int("reverb_lpf_bass")
        reverbLPFDamp = r.int("reverb_lpf_damp")
        reverbLPFOutput = r.int("reverb_lpf_output")
        reverbDecay = r.double("reverb_decay")
        reverbDelay = r.double("reverb_delay")
        convolverEnable = r.bool("convolver_enable")
        convolverFile = r.string("convolver_file")
        convolverOptimizationMode = r.int("convolver_optimization_mode")
        convolverWaveformEdit = r.string("convolver_waveform_edit")
        crossfeedEnable = r.bool("crossfeed_enable")
        crossfeedMode = r.int("crossfeed_mode")
        crossfeedFcut = r.int("crossfeed_bs2b_fcut")
        crossfeedFeed = r.int("crossfeed_bs2b_feed")
        ddcEnable = r.bool("ddc_enable")
        ddcFile = r.string("ddc_file")
        liveprogEnable = r.bool("liveprog_enable")
        liveprogFile = r.string("liveprog_file")
        stereowideEnable = r.bool("stereowide_enable")
        stereowideLevel = r.double("stereowide_level")
        tubeEnable = r.bool("tube_enable")
        tubePregain = r.double("tube_pregain")
    }

    /// Writes every field into `conf`, touching only lines whose value actually changed, so an
    /// unchanged settings object round-trips the file text exactly.
    public func write(into conf: inout AudioConf) {
        let current = DSPSettings(conf: conf)
        func put<T: Equatable>(_ key: String, _ new: T, _ old: T, _ value: AudioConf.Value) {
            if new != old || conf.raw(key) == nil { conf.set(key, value) }
        }
        put("master_enable", masterEnable, current.masterEnable, .bool(masterEnable))
        put("master_postgain", postGain, current.postGain, Self.sliderValue(postGain))
        put("master_limthreshold", limThreshold, current.limThreshold, Self.sliderValue(limThreshold))
        put("master_limrelease", limRelease, current.limRelease, Self.sliderValue(limRelease))
        put("bass_enable", bassEnable, current.bassEnable, .bool(bassEnable))
        put("bass_maxgain", bassMaxGain, current.bassMaxGain, Self.sliderValue(bassMaxGain))
        put("compander_enable", companderEnable, current.companderEnable, .bool(companderEnable))
        put("compander_timeconstant", companderTimeConstant, current.companderTimeConstant, .float(companderTimeConstant))
        put("compander_granularity", companderGranularity, current.companderGranularity, .int(companderGranularity))
        put("compander_time_freq_transforms", companderTransforms, current.companderTransforms, .int(companderTransforms))
        put("compander_response", companderResponse, current.companderResponse, .string(companderResponse))
        put("tone_enable", toneEnable, current.toneEnable, .bool(toneEnable))
        put("tone_filtertype", toneFilterType, current.toneFilterType, .int(toneFilterType))
        put("tone_interpolation", toneInterpolation, current.toneInterpolation, .int(toneInterpolation))
        put("tone_eq", toneEQ, current.toneEQ, .string(toneEQ))
        put("graphiceq_enable", graphicEQEnable, current.graphicEQEnable, .bool(graphicEQEnable))
        put("graphiceq_param", graphicEQParam, current.graphicEQParam, .string(graphicEQParam))
        put("reverb_enable", reverbEnable, current.reverbEnable, .bool(reverbEnable))
        put("reverb_osf", reverbOSF, current.reverbOSF, .int(reverbOSF))
        put("reverb_reflection_amount", reverbReflectionAmount, current.reverbReflectionAmount, .float(reverbReflectionAmount))
        put("reverb_finalwet", reverbFinalWet, current.reverbFinalWet, .float(reverbFinalWet))
        put("reverb_finaldry", reverbFinalDry, current.reverbFinalDry, .float(reverbFinalDry))
        put("reverb_reflection_factor", reverbReflectionFactor, current.reverbReflectionFactor, .float(reverbReflectionFactor))
        put("reverb_reflection_width", reverbReflectionWidth, current.reverbReflectionWidth, .float(reverbReflectionWidth))
        put("reverb_width", reverbWidth, current.reverbWidth, .float(reverbWidth))
        put("reverb_wet", reverbWet, current.reverbWet, .float(reverbWet))
        put("reverb_lfo_wander", reverbLFOWander, current.reverbLFOWander, .float(reverbLFOWander))
        put("reverb_bassboost", reverbBassBoost, current.reverbBassBoost, .float(reverbBassBoost))
        put("reverb_lfo_spin", reverbLFOSpin, current.reverbLFOSpin, .float(reverbLFOSpin))
        put("reverb_lpf_input", reverbLPFInput, current.reverbLPFInput, .int(reverbLPFInput))
        put("reverb_lpf_bass", reverbLPFBass, current.reverbLPFBass, .int(reverbLPFBass))
        put("reverb_lpf_damp", reverbLPFDamp, current.reverbLPFDamp, .int(reverbLPFDamp))
        put("reverb_lpf_output", reverbLPFOutput, current.reverbLPFOutput, .int(reverbLPFOutput))
        put("reverb_decay", reverbDecay, current.reverbDecay, .float(reverbDecay))
        put("reverb_delay", reverbDelay, current.reverbDelay, .float(reverbDelay))
        put("convolver_enable", convolverEnable, current.convolverEnable, .bool(convolverEnable))
        put("convolver_file", convolverFile, current.convolverFile, .string(convolverFile))
        put("convolver_optimization_mode", convolverOptimizationMode, current.convolverOptimizationMode, .int(convolverOptimizationMode))
        put("convolver_waveform_edit", convolverWaveformEdit, current.convolverWaveformEdit, .string(convolverWaveformEdit))
        put("crossfeed_enable", crossfeedEnable, current.crossfeedEnable, .bool(crossfeedEnable))
        put("crossfeed_mode", crossfeedMode, current.crossfeedMode, .int(crossfeedMode))
        put("crossfeed_bs2b_fcut", crossfeedFcut, current.crossfeedFcut, .int(crossfeedFcut))
        put("crossfeed_bs2b_feed", crossfeedFeed, current.crossfeedFeed, .int(crossfeedFeed))
        put("ddc_enable", ddcEnable, current.ddcEnable, .bool(ddcEnable))
        put("ddc_file", ddcFile, current.ddcFile, .string(ddcFile))
        put("liveprog_enable", liveprogEnable, current.liveprogEnable, .bool(liveprogEnable))
        put("liveprog_file", liveprogFile, current.liveprogFile, .string(liveprogFile))
        put("stereowide_enable", stereowideEnable, current.stereowideEnable, .bool(stereowideEnable))
        put("stereowide_level", stereowideLevel, current.stereowideLevel, Self.sliderValue(stereowideLevel))
        put("tube_enable", tubeEnable, current.tubeEnable, .bool(tubeEnable))
        put("tube_pregain", tubePregain, current.tubePregain, Self.sliderValue(tubePregain))
    }

    /// JDSP4Linux writes these keys from integer sliders (`valueA()`), so whole numbers are written
    /// as integers; only the keys it divides by 10 or 100 are written as `%.5f` floats.
    /// Keys whose values are text (written quoted), whatever they look like.
    public static let stringKeys: Set<String> = [
        "compander_response", "tone_eq", "graphiceq_param", "convolver_file", "convolver_waveform_edit",
        "ddc_file", "liveprog_file",
    ]

    public enum SetError: Error, CustomStringConvertible {
        case unknownKey(String), badPair(String)
        public var description: String {
            switch self {
            case .unknownKey(let k): "unknown key \(k) (see --list-keys)"
            case .badPair(let p): "expected key=value, got \(p)"
            }
        }
    }

    /// Sets one `key=value` from a command line (jdspconf, jdspctl), typed as JDSP4Linux writes it.
    public static func set(_ pair: String, in conf: inout AudioConf) throws {
        guard let eq = pair.firstIndex(of: "=") else { throw SetError.badPair(pair) }
        let key = String(pair[..<eq])
        var value = String(pair[pair.index(after: eq)...])
        guard allKeys.contains(key) else { throw SetError.unknownKey(key) }
        if stringKeys.contains(key) {
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            conf.set(key, .string(value))
        } else if value == "true" || value == "false" { conf.set(key, .bool(value == "true")) }
        else if let i = Int(value) { conf.set(key, .int(i)) }
        else if let d = Double(value) { conf.set(key, .float(d)) }
        else { conf.set(key, .string(value)) }
    }

    private static func sliderValue(_ v: Double) -> AudioConf.Value {
        v.rounded() == v && abs(v) < 1e9 ? .int(Int(v)) : .float(v)
    }

    /// Reads with JDSP4Linux semantics: missing key -> default.conf value; strings lose their
    /// surrounding quotes; numbers parse leniently (Qt's toInt would give 0 for "600.00000").
    private struct Reader {
        let conf: AudioConf
        let fallback: AudioConf?

        func raw(_ key: String) -> String {
            conf.string(key) ?? fallback?.string(key) ?? ""
        }

        func bool(_ key: String) -> Bool {
            // QVariant(QString).toBool(): false only for "", "0" and "false" (case-insensitive).
            let v = raw(key).lowercased()
            return !(v.isEmpty || v == "0" || v == "false")
        }

        func double(_ key: String) -> Double {
            Double(raw(key)) ?? 0
        }

        func int(_ key: String) -> Int {
            let v = raw(key)
            return Int(v) ?? Int(Double(v) ?? 0)
        }

        func string(_ key: String) -> String {
            raw(key)
        }
    }
}
