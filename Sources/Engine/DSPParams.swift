import AudioCore
import Config
import Foundation

/// Builds a libjamesdsp instance from typed settings (worker thread, never the IOProc).
/// String-to-number conversions and the "field count must match" rules follow JDSP4Linux DspHost.
enum DSPBuilder {
    struct Built: @unchecked Sendable {  // the pointer is handed over whole to one owner
        let dsp: OpaquePointer?
        let messages: [String]
        let seconds: Double
    }

    static func build(_ s: DSPSettings, library: FileLibrary, blockFrames: UInt32, sampleRate: Double) -> Built {
        let t0 = Date()
        var p = JDParams()
        var notes: [String] = []
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func cString(_ text: String?) -> UnsafePointer<CChar>? {
            guard let text, let copy = strdup(text) else { return nil }
            owned.append(copy)
            return UnsafePointer(copy)
        }

        p.postGainDb = Float(s.postGain)
        p.limThresholdDb = Float(s.limThreshold)
        p.limReleaseMs = Float(s.limRelease)
        p.bassEnable = s.bassEnable ? 1 : 0
        p.bassMaxGainDb = Float(s.bassMaxGain)

        p.companderEnable = s.companderEnable ? 1 : 0
        p.companderTimeConstant = Float(s.companderTimeConstant)
        p.companderGranularity = Int32(s.companderGranularity)
        p.companderTransforms = Int32(s.companderTransforms)
        if let values = numbers(s.companderResponse, count: 14) {
            p.companderResponseValid = 1
            copy(values, into: &p.companderResponse)
        }

        p.toneEnable = s.toneEnable ? 1 : 0
        p.toneFilterType = Int32(s.toneFilterType)
        p.toneInterpolation = Int32(s.toneInterpolation)
        if let values = numbers(s.toneEQ, count: 30) {
            p.toneEQValid = 1
            copy(values, into: &p.toneEQ)
        }

        p.graphicEQEnable = s.graphicEQEnable ? 1 : 0
        p.graphicEQ = cString(s.graphicEQParam)

        p.reverbEnable = s.reverbEnable ? 1 : 0
        p.reverbOSF = Int32(s.reverbOSF)
        p.reverbReflectionAmount = Float(s.reverbReflectionAmount)
        p.reverbFinalWet = Float(s.reverbFinalWet)
        p.reverbFinalDry = Float(s.reverbFinalDry)
        p.reverbReflectionFactor = Float(s.reverbReflectionFactor)
        p.reverbReflectionWidth = Float(s.reverbReflectionWidth)
        p.reverbWidth = Float(s.reverbWidth)
        p.reverbWet = Float(s.reverbWet)
        p.reverbLFOWander = Float(s.reverbLFOWander)
        p.reverbBassBoost = Float(s.reverbBassBoost)
        p.reverbLFOSpin = Float(s.reverbLFOSpin)
        p.reverbLPFInput = Float(s.reverbLPFInput)
        p.reverbLPFBass = Float(s.reverbLPFBass)
        p.reverbLPFDamp = Float(s.reverbLPFDamp)
        p.reverbLPFOutput = Float(s.reverbLPFOutput)
        p.reverbDecay = Float(s.reverbDecay)
        p.reverbDelayMs = Float(s.reverbDelay)

        p.convolverEnable = s.convolverEnable ? 1 : 0
        if s.convolverEnable {
            if let url = library.resolve(s.convolverFile, kind: .impulseResponse) {
                p.convolverPath = cString(url.path)
            } else {
                notes.append("Convolver: \"\(s.convolverFile)\" not found (looked for it by name in \(library.folder(.impulseResponse).path)); convolver off")
                p.convolverEnable = 0
            }
        }
        p.convolverOptimizationMode = Int32(s.convolverOptimizationMode)
        // DspHost: wrong field count -> -80;-100;23;12;17;28
        let edit = numbers(s.convolverWaveformEdit, count: 6)?.map { Int32($0) } ?? [-80, -100, 23, 12, 17, 28]
        copy(edit, into: &p.convolverWaveformEdit)

        p.crossfeedEnable = s.crossfeedEnable ? 1 : 0
        p.crossfeedMode = Int32(s.crossfeedMode)
        p.crossfeedFcut = Int32(s.crossfeedFcut)
        p.crossfeedFeed = Int32(s.crossfeedFeed)

        p.ddcEnable = s.ddcEnable ? 1 : 0
        if s.ddcEnable {
            if let url = library.resolve(s.ddcFile, kind: .ddc), let text = try? String(contentsOf: url, encoding: .utf8) {
                p.ddcText = cString(text)
            } else {
                notes.append("DDC: \"\(s.ddcFile)\" not found (looked for it by name in \(library.folder(.ddc).path)); DDC off")
                p.ddcEnable = 0
            }
        }

        p.liveprogEnable = s.liveprogEnable ? 1 : 0
        if s.liveprogEnable {
            if let url = library.resolve(s.liveprogFile, kind: .liveprog), let text = try? String(contentsOf: url, encoding: .utf8) {
                p.liveprogText = cString(text)
            } else {
                notes.append("Liveprog: \"\(s.liveprogFile)\" not found (looked for it by name in \(library.folder(.liveprog).path)); liveprog off")
                p.liveprogEnable = 0
            }
        }

        p.stereowideEnable = s.stereowideEnable ? 1 : 0
        p.stereowideLevel = Float(s.stereowideLevel)
        p.tubeEnable = s.tubeEnable ? 1 : 0
        p.tubePregain = Float(s.tubePregain)

        var buffer = [CChar](repeating: 0, count: 2048)
        let dsp = jd_dsp_build(&p, blockFrames, sampleRate, &buffer, buffer.count)
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        notes += text.split(separator: "\n").map(String.init)
        return Built(dsp: dsp, messages: notes, seconds: Date().timeIntervalSince(t0))
    }

    /// Copies `values` into a C fixed-size array (imported as a tuple of the same element type).
    private static func copy<Element, Tuple>(_ values: [Element], into tuple: inout Tuple) {
        precondition(values.count * MemoryLayout<Element>.stride == MemoryLayout<Tuple>.size)
        values.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &tuple) { $0.copyMemory(from: source) }
        }
    }

    /// "a;b;c" -> [Double] if exactly `count` numbers (DspHost ignores the setting otherwise).
    static func numbers(_ text: String, count: Int) -> [Double]? {
        var fields = text.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if fields.last == "" && fields.count == count + 1 { fields.removeLast() }  // trailing ';'
        guard fields.count == count else { return nil }
        let values = fields.compactMap(Double.init)
        return values.count == count ? values : nil
    }
}
