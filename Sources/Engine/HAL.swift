import CoreAudio
import Foundation
import os

/// Small typed wrappers over the Core Audio object API. Control plane only, never the IOProc.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr else { throw LiveError("get \(fourCC(selector)) on \(object): \(err)") }
    }

    static func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var v: UInt32 = 0
        try read(object, selector, &v, scope: scope)
        return v
    }

    static func f64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> Float64 {
        var v: Float64 = 0
        try read(object, selector, &v)
        return v
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { throw LiveError("get \(fourCC(selector)) on \(object): \(err)") }
        return value.takeRetainedValue() as String
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw LiveError("size \(fourCC(selector)) on \(object): \(err)") }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list)
        guard err == noErr else { throw LiveError("get \(fourCC(selector)) on \(object): \(err)") }
        return list
    }

    static func deviceList() throws -> [AudioObjectID] {
        try ids(system, kAudioHardwarePropertyDevices)
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        try read(system, kAudioHardwarePropertyDefaultOutputDevice, &id)
        guard id != kAudioObjectUnknown else { throw LiveError("no default output device") }
        return id
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (try? u32(device, kAudioDevicePropertyDeviceIsAlive)) == 1
    }

    static func name(_ device: AudioObjectID) -> String {
        (try? string(device, kAudioObjectPropertyName)) ?? "device \(device)"
    }

    /// Total channels in the device's output stream configuration (what an IOProc would see).
    static func outputChannels(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// True if every output stream's virtual format is native-endian float32 linear PCM.
    static func outputIsFloat32(_ device: AudioObjectID) -> Bool {
        guard let streams = try? ids(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
              !streams.isEmpty else { return false }
        return streams.allSatisfy { stream in
            var f = AudioStreamBasicDescription()
            guard (try? read(stream, kAudioStreamPropertyVirtualFormat, &f)) != nil else { return false }
            return f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && f.mBitsPerChannel == 32 && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        }
    }

    static func activeSubDevices(_ aggregate: AudioObjectID) -> [AudioObjectID] {
        (try? ids(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)) ?? []
    }

    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &id)
        guard err == noErr else { throw LiveError("translate pid \(pid): \(err)") }
        return id
    }

    /// PIDs of processes (other than `excluding`) currently running audio output.
    static func processesRunningOutput(excluding: Set<pid_t>) -> Set<pid_t> {
        var result = Set<pid_t>()
        for process in (try? ids(system, kAudioHardwarePropertyProcessObjectList)) ?? [] {
            guard (try? u32(process, kAudioProcessPropertyIsRunningOutput)) == 1 else { continue }
            var pid: pid_t = 0
            if (try? read(process, kAudioProcessPropertyPID, &pid)) != nil, !excluding.contains(pid) { result.insert(pid) }
        }
        return result
    }

    /// Core Audio's process objects (every process that has used audio), with pid, bundle ID and
    /// the bundle ID of the app responsible for it (e.g. Safari for its WebKit GPU process).
    static func audioProcesses() -> [(object: AudioObjectID, pid: pid_t, bundleID: String, owner: String?, playing: Bool)] {
        ((try? ids(system, kAudioHardwarePropertyProcessObjectList)) ?? []).compactMap { process in
            var pid: pid_t = 0
            guard (try? read(process, kAudioProcessPropertyPID, &pid)) != nil else { return nil }
            let bundleID = (try? string(process, kAudioProcessPropertyBundleID)) ?? ""
            let playing = (try? u32(process, kAudioProcessPropertyIsRunningOutput)) == 1
            return (process, pid, bundleID, Responsibility.bundleID(responsibleFor: pid), playing)
        }
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
        return String(v)
    }
}

public struct LiveError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Append-only text log at ~/Library/Logs/jdsp4mac/live.log. Any thread except the IOProc.
public enum Log {
    public static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/jdsp4mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("live.log")
    }()

    private static let lock = OSAllocatedUnfairLock()

    public static func write(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
