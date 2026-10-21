// haltest: drive Core Audio device state for scripted engine tests (Tests/phase2.sh).
//
//   haltest devices                    list devices (* = default output)
//   haltest default [<id>]             print or set the default output device
//   haltest rate [<hz>]                print or set the default output's nominal sample rate
//   haltest make-output                create a public aggregate wrapping the current default
//                                      output (name "jdsptest-output"), print its id
//   haltest destroy <id>               destroy an aggregate device
//   haltest sweep-test                 destroy any leftover "jdsptest-" aggregates
//   haltest tone <path> <hz> <seconds> <amplitude>   write a 48 kHz stereo 16-bit WAV
//   haltest serve                      read the commands above from stdin, one per line, and print
//                                      one result line each. Use this for make-output/default/
//                                      destroy: an aggregate made by a process that exits at once
//                                      vanished, and destroys sent from short-lived processes did
//                                      not always take effect (observed on macOS 27.0.1).
//
// The "jdsptest-" prefix is deliberately different from the app's "jdsp4mac-" launch sweep.

import CoreAudio
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func string(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s)
    var v: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v) == noErr, let v else { return "?" }
    return v.takeRetainedValue() as String
}

func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s)
    var v: UInt32 = 0
    var size = UInt32(4)
    AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v)
    return v
}

func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
    return ids
}

func defaultOutput() -> AudioObjectID { u32(system, kAudioHardwarePropertyDefaultOutputDevice) }

func outputChannels(_ d: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw)
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func rate(_ d: AudioObjectID) -> Float64 {
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var v: Float64 = 0
    var size = UInt32(8)
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v)
    return v
}

/// Waits until `check` holds (property changes apply asynchronously).
func waitFor(_ what: String, _ check: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !check() {
        if Date() > deadline { fail("timed out waiting for \(what)") }
        usleep(20_000)
    }
}

func run(_ args: [String]) {
switch args.first {
case "devices":
    let def = defaultOutput()
    for d in devices() {
        print("\(d == def ? "*" : " ") \(d)\t\(string(d, kAudioObjectPropertyName))\tout \(outputChannels(d))\t\(rate(d))")
    }
case "default":
    if args.count > 1, var id = UInt32(args[1]) {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        let err = AudioObjectSetPropertyData(system, &a, 0, nil, 4, &id)
        if err != noErr { fail("set default output failed: \(err)") }
        waitFor("default output \(id)") { defaultOutput() == id }
    }
    print(defaultOutput())
case "rate":
    let d = defaultOutput()
    if args.count > 1, var hz = Float64(args[1]) {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        let err = AudioObjectSetPropertyData(d, &a, 0, nil, 8, &hz)
        if err != noErr { fail("set rate failed: \(err)") }
        waitFor("rate \(hz)") { rate(d) == hz }
    }
    print(rate(d))
case "make-output":
    let base = defaultOutput()
    let uid = string(base, kAudioDevicePropertyDeviceUID)
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "jdsptest-output",
        kAudioAggregateDeviceUIDKey: "jdsptest-output-" + UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceIsPrivateKey: false,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    ]
    var id = AudioObjectID(0)
    let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
    if err != noErr { fail("create aggregate failed: \(err)") }
    waitFor("aggregate alive") { u32(id, kAudioDevicePropertyDeviceIsAlive) == 1 && outputChannels(id) > 0 }
    print(id)
case "destroy":
    guard args.count > 1, let id = UInt32(args[1]) else { fail("destroy <id>") }
    let err = AudioHardwareDestroyAggregateDevice(id)
    if err != noErr { fail("destroy failed: \(err)") }
    print("destroyed \(id)")
case "sweep-test":
    for d in devices() where string(d, kAudioObjectPropertyName).hasPrefix("jdsptest-") {
        print("destroying leftover \(d): \(AudioHardwareDestroyAggregateDevice(d))")
    }
case "tone":
    guard args.count == 5, let hz = Double(args[2]), let secs = Double(args[3]), let amp = Double(args[4]) else {
        fail("tone <path> <hz> <seconds> <amplitude>")
    }
    let fs = 48000.0, frames = Int(fs * secs)
    var pcm = Data(capacity: frames * 4)
    for i in 0..<frames {
        let v = Int16(max(-32767, min(32767, amp * 32767 * sin(2 * .pi * hz * Double(i) / fs))))
        withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
    }
    var wav = Data("RIFF".utf8)
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
    le32(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
    le32(16); le16(1); le16(2); le32(48000); le32(48000 * 4); le16(4); le16(16)
    wav.append(Data("data".utf8)); le32(UInt32(pcm.count)); wav.append(pcm)
    do { try wav.write(to: URL(fileURLWithPath: args[1])) } catch { fail("\(error)") }
default:
    fail("usage: haltest devices | default [<id>] | rate [<hz>] | make-output | destroy <id> | sweep-test | tone <path> <hz> <s> <amp> | serve")
}
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "serve" {
    setvbuf(stdout, nil, _IOLBF, 0)
    while let line = readLine() {
        let words = line.split(separator: " ").map(String.init)
        if words.isEmpty { continue }
        if words[0] == "quit" { break }
        run(words)
        print("ok")
    }
} else {
    run(cliArgs)
}
