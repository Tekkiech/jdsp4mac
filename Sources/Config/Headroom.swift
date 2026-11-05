import Foundation

/// Automatic headroom: how far the static EQ curves (the 15-band equalizer and the AutoEQ
/// GraphicEQ curve, when enabled) lift the signal at their highest point. Lowering post gain by
/// this much keeps boosted curves out of libjamesdsp's limiter, which runs right after post gain.
/// Bass boost and the compander are level-dependent, so they are left to the limiter.
public enum Headroom {
    /// How far automatic headroom lowers the output: the largest boost, less any cut already made
    /// by a negative post gain (a preset that allows for its own curve is not lowered twice).
    public static func neededDB(_ s: DSPSettings) -> Double {
        max(0, maxBoostDB(s) + min(0, s.postGain))
    }

    /// The largest combined boost in dB (0 if the curves only cut), evaluated on AutoEq's 127-point
    /// grid plus the equalizer's own band frequencies, interpolating each curve linearly over
    /// log-frequency.
    public static func maxBoostDB(_ s: DSPSettings) -> Double {
        var curves: [[(f: Double, g: Double)]] = []
        if s.toneEnable, let eq = toneCurve(s.toneEQ) { curves.append(eq) }
        if s.graphicEQEnable, let graphic = graphicCurve(s.graphicEQParam) { curves.append(graphic) }
        guard !curves.isEmpty else { return 0 }
        let grid = Set(AutoEQ.graphicEQFrequencies + curves.flatMap { $0.map(\.f) }).sorted()
        let peak = grid.map { f in curves.reduce(0) { $0 + gain($1, at: f) } }.max() ?? 0
        return max(0, peak)
    }

    /// `tone_eq`: 15 frequencies then 15 gains.
    static func toneCurve(_ text: String) -> [(f: Double, g: Double)]? {
        let v = text.split(separator: ";").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 30 else { return nil }
        return (0..<15).map { (v[$0], v[15 + $0]) }.sorted { $0.f < $1.f }
    }

    /// `GraphicEQ: f g; f g; ...`
    static func graphicCurve(_ text: String) -> [(f: Double, g: Double)]? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let points: [(f: Double, g: Double)] = text[text.index(after: colon)...].split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: " ").compactMap { Double($0) }
            return parts.count == 2 && parts[0] > 0 ? (parts[0], parts[1]) : nil
        }
        return points.isEmpty ? nil : points.sorted { $0.f < $1.f }
    }

    /// Linear in log-frequency between points; the edge values beyond them.
    static func gain(_ curve: [(f: Double, g: Double)], at f: Double) -> Double {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if f <= first.f { return first.g }
        if f >= last.f { return last.g }
        let i = curve.firstIndex { $0.f >= f }!
        let a = curve[i - 1], b = curve[i]
        let t = (log(f) - log(a.f)) / (log(b.f) - log(a.f))
        return a.g + t * (b.g - a.g)
    }
}
