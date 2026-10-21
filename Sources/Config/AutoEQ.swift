import Foundation

/// AutoEq (github.com/jaakkopasanen/AutoEq, MIT) published results. `results/INDEX.md` lists every
/// profile as `- [Name](./source/rig/Name) by source on rig`; each folder holds
/// `<Name> GraphicEQ.txt`, which the arbitrary-response EQ (`graphiceq_param`) takes as is.
public enum AutoEQ {
    public static let base = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
    public static let indexURL = base.appendingPathComponent("INDEX.md")

    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String { path }
        public let name: String
        public let path: String      // percent-encoded, relative to results/
        public let source: String    // who measured it
        public let rig: String?      // measurement rig, when the index names one

        public var graphicEQURL: URL {
            // path is already percent-encoded; append the file name the same way.
            let file = (name + " GraphicEQ.txt").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return URL(string: path + "/" + file, relativeTo: AutoEQ.base)!.absoluteURL
        }
    }

    public static func parseIndex(_ markdown: String) -> [Entry] {
        markdown.split(whereSeparator: \.isNewline).compactMap { line in
            // Names and paths can contain parentheses ("(ANC Off)"); the link ends at ") by ".
            guard line.hasPrefix("- ["), let close = line.range(of: "](./"),
                  let end = line.range(of: ") by ", range: close.upperBound..<line.endIndex) else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let path = String(line[close.upperBound..<end.lowerBound])
            let parts = line[end.upperBound...].trimmingCharacters(in: .whitespaces).components(separatedBy: " on ")
            return Entry(name: name, path: path, source: parts[0], rig: parts.count > 1 ? parts[1...].joined(separator: " on ") : nil)
        }
    }

    /// The `GraphicEQ: ...` line of a GraphicEQ.txt, or nil.
    public static func graphicEQLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("GraphicEQ:") }.map(String.init)
    }

    /// Converts an AutoEq / Equalizer APO ParametricEQ.txt (Preamp, then PK / LSC / HSC filters) to
    /// a GraphicEQ curve by evaluating the RBJ biquads at 48 kHz on AutoEq's GraphicEQ frequency
    /// grid. Returns nil if there are no usable filters.
    public static func graphicEQ(fromParametric text: String) -> String? {
        var preamp = 0.0
        var filters: [(type: String, fc: Double, gain: Double, q: Double)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let words = raw.split(separator: " ").map(String.init)
            if words.first == "Preamp:", words.count > 1, let v = Double(words[1]) { preamp = v; continue }
            guard words.first == "Filter", words.contains("ON") else { continue }
            func value(after key: String) -> Double? { words.firstIndex(of: key).flatMap { words.indices.contains($0 + 1) ? Double(words[$0 + 1]) : nil } }
            guard let onIndex = words.firstIndex(of: "ON"), words.indices.contains(onIndex + 1),
                  let fc = value(after: "Fc") else { continue }
            let type = words[onIndex + 1]
            filters.append((type, fc, value(after: "Gain") ?? 0, value(after: "Q") ?? 0.707))
        }
        guard !filters.isEmpty else { return nil }
        let fs = 48000.0
        let points = graphicEQFrequencies.map { f -> String in
            var db = preamp
            for flt in filters { db += biquadGainDB(type: flt.type, fc: flt.fc, gain: flt.gain, q: flt.q, f: f, fs: fs) }
            return "\(Int(f)) \(String(format: "%.1f", db))"
        }
        return "GraphicEQ: " + points.joined(separator: "; ")
    }

    /// AutoEq's GraphicEQ frequency grid (127 points, copied from its published GraphicEQ.txt files).
    static let graphicEQFrequencies: [Double] = [
        20, 21, 22, 23, 24, 26, 27, 29, 30, 32, 34, 36, 38, 40, 43, 45, 48, 50, 53, 56, 59, 63, 66, 70, 74, 78, 83, 87, 92,
        97, 103, 109, 115, 121, 128, 136, 143, 151, 160, 169, 178, 188, 199, 210, 222, 235, 248, 262, 277, 292, 309, 326, 345,
        364, 385, 406, 429, 453, 479, 506, 534, 565, 596, 630, 665, 703, 743, 784, 829, 875, 924, 977, 1032, 1090, 1151, 1216,
        1284, 1357, 1433, 1514, 1599, 1689, 1784, 1885, 1991, 2103, 2221, 2347, 2479, 2618, 2766, 2921, 3086, 3260, 3443,
        3637, 3842, 4058, 4287, 4528, 4783, 5052, 5337, 5637, 5955, 6290, 6644, 7018, 7414, 7831, 8272, 8738, 9230, 9749,
        10298, 10878, 11490, 12137, 12821, 13543, 14305, 15110, 15961, 16860, 17809, 18812, 19871,
    ]

    static func biquadGainDB(type: String, fc: Double, gain: Double, q: Double, f: Double, fs: Double) -> Double {
        let a = pow(10, gain / 40), w0 = 2 * Double.pi * fc / fs, alpha = sin(w0) / (2 * q), c = cos(w0)
        let b0, b1, b2, a0, a1, a2: Double
        switch type {
        case "LSC", "LS":
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * c + s); b1 = 2 * a * ((a - 1) - (a + 1) * c); b2 = a * ((a + 1) - (a - 1) * c - s)
            a0 = (a + 1) + (a - 1) * c + s; a1 = -2 * ((a - 1) + (a + 1) * c); a2 = (a + 1) + (a - 1) * c - s
        case "HSC", "HS":
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * c + s); b1 = -2 * a * ((a - 1) + (a + 1) * c); b2 = a * ((a + 1) + (a - 1) * c - s)
            a0 = (a + 1) - (a - 1) * c + s; a1 = 2 * ((a - 1) - (a + 1) * c); a2 = (a + 1) - (a - 1) * c - s
        default:  // PK
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a
        }
        let w = 2 * Double.pi * f / fs
        func mag2(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
            let re = x0 + x1 * cos(w) + x2 * cos(2 * w), im = -(x1 * sin(w) + x2 * sin(2 * w))
            return re * re + im * im
        }
        return 10 * log10(mag2(b0, b1, b2) / mag2(a0, a1, a2))
    }
}
