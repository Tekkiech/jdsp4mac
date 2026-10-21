/// libjamesdsp's reverb presets (`Effects/reverb.c`, `sf_presetreverb`), as audio.conf `reverb_*`
/// values. RootlessJamesDSP and JamesDSP for Android store only a preset index; JDSP4Linux stores
/// the 17 parameters. Delay is stored in ms in audio.conf (the table has seconds).
public enum ReverbPresets {
    public struct Row: Equatable, Sendable {
        public let osf: Int
        public let reflectionAmount, finalWet, finalDry, reflectionFactor, reflectionWidth, width, wet,
                   lfoWander, bassBoost, lfoSpin: Double
        public let lpfInput, lpfBass, lpfDamp, lpfOutput: Int
        public let decay, delayMs: Double
    }

    public static let names = ["Default", "Small hall 1", "Small hall 2", "Medium hall 1", "Medium hall 2", "Large hall 1",
                               "Large hall 2", "Small room 1", "Small room 2", "Medium room 1", "Medium room 2",
                               "Large room 1", "Large room 2", "Medium ER 1", "Medium ER 2", "Plate high", "Plate low",
                               "Long reverb 1", "Long reverb 2"]

    // OSF ERtoLt ERWet Dry ERFac ERWdth Wdth Wet Wander BassB Spin InpLP BasLP DmpLP OutLP RT60 Delay(ms)
    public static let rows: [Row] = [
        r(1, 0.40, -9, -7, 1.6, 0.7, 1.0, -0, 0.25, 0.15, 0.7, 17000, 500, 7000, 10000, 3.2, 20),
        r(1, 0.30, -9, -7, 1.0, 0.7, 1.0, -8, 0.3, 0.25, 0.7, 18000, 600, 9000, 17000, 2.1, 10),
        r(1, 0.30, -9, -7, 1.0, 0.7, 1.0, -8, 0.25, 0.20, 0.5, 18000, 600, 7000, 9000, 2.3, 10),
        r(1, 0.30, -9, -7, 1.2, 0.7, 1.0, -8, 0.25, 0.20, 0.7, 18000, 500, 8000, 16000, 2.8, 10),
        r(1, 0.30, -9, -7, 1.2, 0.7, 1.0, -8, 0.2, 0.15, 0.5, 18000, 500, 6000, 8000, 2.9, 10),
        r(1, 0.20, -9, -7, 1.4, 0.7, 1.0, -8, 0.15, 0.20, 1.0, 18000, 400, 9000, 14000, 3.8, 18),
        r(1, 0.20, -9, -7, 1.5, 0.7, 1.0, -8, 0.20, 0.20, 0.5, 18000, 400, 5000, 7000, 4.2, 18),
        r(1, 0.70, -8, -7, 0.7, -0.4, 0.8, -8, 0.20, 0.30, 1.6, 18000, 1000, 18000, 18000, 0.5, 5),
        r(1, 0.70, -8, -7, 0.8, 0.6, 0.9, -8, 0.30, 0.30, 0.4, 18000, 300, 10000, 18000, 0.5, 5),
        r(1, 0.50, -8, -7, 1.2, -0.4, 0.8, -8, 0.20, 0.10, 1.6, 18000, 1000, 18000, 18000, 0.8, 8),
        r(1, 0.50, -8, -7, 1.2, 0.6, 0.9, -8, 0.30, 0.10, 0.4, 18000, 300, 10000, 18000, 1.2, 16),
        r(1, 0.20, -8, -7, 2.2, -0.4, 0.9, -8, 0.20, 0.10, 1.6, 18000, 1000, 16000, 18000, 1.8, 10),
        r(1, 0.20, -8, -7, 2.2, 0.6, 0.9, -8, 0.30, 0.10, 0.4, 18000, 500, 9000, 18000, 1.9, 20),
        r(1, 0.50, -7, -6, 1.2, -0.4, 0.8, -70, 0.20, 0.10, 1.6, 18000, 1000, 18000, 18000, 0.8, 8),
        r(1, 0.50, -7, -6, 1.2, 0.6, 0.9, -70, 0.30, 0.10, 0.4, 18000, 300, 10000, 18000, 1.2, 16),
        r(2, 0.00, -30, -12, 1.0, 1.0, 1.0, -8, 0.20, 0.10, 1.6, 18000, 1000, 16000, 18000, 1.8, 0),
        r(2, 0.00, -30, -12, 1.0, 1.0, 1.0, -8, 0.30, 0.20, 0.4, 18000, 500, 9000, 18000, 1.9, 0),
        r(2, 0.10, -16, -14, 1.0, 0.1, 1.0, -5, 0.35, 0.05, 1.0, 18000, 100, 10000, 18000, 12.0, 0),
        r(2, 0.10, -16, -14, 1.0, 0.1, 1.0, -5, 0.40, 0.05, 1.0, 18000, 100, 9000, 18000, 30.0, 0),
    ]

    private static func r(_ osf: Int, _ a: Double, _ fw: Double, _ fd: Double, _ rf: Double, _ rw: Double, _ w: Double,
                          _ wet: Double, _ wan: Double, _ bb: Double, _ spin: Double, _ li: Int, _ lb: Int, _ ld: Int,
                          _ lo: Int, _ decay: Double, _ delayMs: Double) -> Row {
        Row(osf: osf, reflectionAmount: a, finalWet: fw, finalDry: fd, reflectionFactor: rf, reflectionWidth: rw, width: w,
            wet: wet, lfoWander: wan, bassBoost: bb, lfoSpin: spin, lpfInput: li, lpfBass: lb, lpfDamp: ld, lpfOutput: lo,
            decay: decay, delayMs: delayMs)
    }

    public static func apply(_ index: Int, to s: inout DSPSettings) {
        let row = rows[max(0, min(rows.count - 1, index))]
        s.reverbOSF = row.osf
        s.reverbReflectionAmount = row.reflectionAmount
        s.reverbFinalWet = row.finalWet
        s.reverbFinalDry = row.finalDry
        s.reverbReflectionFactor = row.reflectionFactor
        s.reverbReflectionWidth = row.reflectionWidth
        s.reverbWidth = row.width
        s.reverbWet = row.wet
        s.reverbLFOWander = row.lfoWander
        s.reverbBassBoost = row.bassBoost
        s.reverbLFOSpin = row.lfoSpin
        s.reverbLPFInput = row.lpfInput
        s.reverbLPFBass = row.lpfBass
        s.reverbLPFDamp = row.lpfDamp
        s.reverbLPFOutput = row.lpfOutput
        s.reverbDecay = row.decay
        s.reverbDelay = row.delayMs
    }

    /// The preset matching the settings' reverb parameters, and whether the match is exact.
    public static func closest(to s: DSPSettings) -> (index: Int, exact: Bool) {
        func distance(_ row: Row) -> Double {
            let pairs: [(Double, Double, Double)] = [  // (setting, row, scale)
                (Double(s.reverbOSF), Double(row.osf), 1), (s.reverbReflectionAmount, row.reflectionAmount, 1),
                (s.reverbFinalWet, row.finalWet, 10), (s.reverbFinalDry, row.finalDry, 10),
                (s.reverbReflectionFactor, row.reflectionFactor, 1), (s.reverbReflectionWidth, row.reflectionWidth, 1),
                (s.reverbWidth, row.width, 1), (s.reverbWet, row.wet, 10), (s.reverbLFOWander, row.lfoWander, 1),
                (s.reverbBassBoost, row.bassBoost, 1), (s.reverbLFOSpin, row.lfoSpin, 1),
                (Double(s.reverbLPFInput), Double(row.lpfInput), 10000), (Double(s.reverbLPFBass), Double(row.lpfBass), 1000),
                (Double(s.reverbLPFDamp), Double(row.lpfDamp), 10000), (Double(s.reverbLPFOutput), Double(row.lpfOutput), 10000),
                (s.reverbDecay, row.decay, 1), (s.reverbDelay, row.delayMs, 10),
            ]
            return pairs.reduce(0) { $0 + abs($1.0 - $1.1) / $1.2 }
        }
        let scored = rows.indices.map { ($0, distance(rows[$0])) }
        let best = scored.min { $0.1 < $1.1 }!
        return (best.0, best.1 < 1e-6)
    }
}
