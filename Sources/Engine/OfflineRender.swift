import AVFoundation
import AudioCore
import Config
import Foundation

/// Runs a file through a DSP instance built exactly as the live engine builds it (tools and
/// tests only; uses the same DSPBuilder).
public enum OfflineRender {
    public struct Report: Sendable {
        public var messages: [String]
        public var buildSeconds: Double
        public var processSeconds: Double
        public var maxBlockSeconds: Double   // longest single process call (the audio thread's worst case)
        public var audioSeconds: Double
        public var finite: Bool
        public var inPeak: Float
        public var outPeak: Float
    }

    public static func render(settings: DSPSettings, library: FileLibrary, input: URL, output: URL?,
                              blockFrames: UInt32 = 512) throws -> Report {
        let file = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw LiveError("cannot allocate buffer")
        }
        try file.read(into: buffer)
        let channels = Int(file.processingFormat.channelCount)
        guard let data = buffer.floatChannelData, channels >= 1 else { throw LiveError("no audio data") }
        let inL = data[0], inR = data[min(1, channels - 1)]

        let built = DSPBuilder.build(settings, library: library, blockFrames: blockFrames, sampleRate: rate)
        guard let dsp = built.dsp else { throw LiveError("DSP build failed") }
        defer { jd_dsp_free(dsp) }

        let n = Int(blockFrames), total = Int(frames)
        var outL = [Float](repeating: 0, count: total), outR = [Float](repeating: 0, count: total)
        var bl = [Float](repeating: 0, count: n), br = [Float](repeating: 0, count: n)
        var ol = [Float](repeating: 0, count: n), or = [Float](repeating: 0, count: n)
        var busy = 0.0, maxBlock = 0.0
        var inPeak: Float = 0
        for start in stride(from: 0, to: total, by: n) {
            let len = min(n, total - start)
            for i in 0..<n {
                bl[i] = i < len ? inL[start + i] : 0
                br[i] = i < len ? inR[start + i] : 0
                inPeak = max(inPeak, abs(bl[i]), abs(br[i]))
            }
            let t0 = Date()
            jd_dsp_process(dsp, bl, br, &ol, &or, blockFrames)
            let dt = Date().timeIntervalSince(t0)
            busy += dt
            maxBlock = max(maxBlock, dt)
            for i in 0..<len {
                outL[start + i] = ol[i]
                outR[start + i] = or[i]
            }
        }
        let finite = !outL.contains { !$0.isFinite } && !outR.contains { !$0.isFinite }
        let outPeak = max(outL.map(abs).max() ?? 0, outR.map(abs).max() ?? 0)
        if let output {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
            let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            outBuffer.frameLength = frames
            outL.withUnsafeBufferPointer { outBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: total) }
            outR.withUnsafeBufferPointer { outBuffer.floatChannelData![1].update(from: $0.baseAddress!, count: total) }
            let outFile = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: outBuffer)
        }
        return Report(messages: built.messages, buildSeconds: built.seconds, processSeconds: busy, maxBlockSeconds: maxBlock,
                      audioSeconds: Double(total) / rate, finite: finite, inPeak: inPeak, outPeak: outPeak)
    }
}
