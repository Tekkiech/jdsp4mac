import CoreAudio
import Foundation

/// Output devices for the panel's picker. The engine always follows the system default output, so
/// picking a device here sets the system default (as the Sound menu does).
public struct OutputDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let channels: Int
}

public enum OutputDevices {
    /// Devices with output channels, without our own private aggregates.
    public static func list() -> [OutputDevice] {
        ((try? HAL.deviceList()) ?? []).compactMap { device in
            let channels = HAL.outputChannels(device)
            guard channels > 0, let uid = try? HAL.string(device, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = HAL.name(device)
            guard !uid.hasPrefix(AudioEngine.aggregatePrefix), !name.hasPrefix(AudioEngine.aggregatePrefix) else { return nil }
            return OutputDevice(uid: uid, name: name, channels: channels)
        }
    }

    /// UID of the current system default output.
    public static func defaultUID() -> String? {
        (try? HAL.defaultOutputDevice()).flatMap { try? HAL.string($0, kAudioDevicePropertyDeviceUID) }
    }

    /// Makes the device with this UID the system default output. The engine notices the change and
    /// rebuilds on the new device.
    public static func setDefault(uid: String) {
        guard var device = ((try? HAL.deviceList()) ?? []).first(where: { (try? HAL.string($0, kAudioDevicePropertyDeviceUID)) == uid }) else {
            Log.write("output picker: no device for \(uid)")
            return
        }
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let err = AudioObjectSetPropertyData(HAL.system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
        if err != noErr { Log.write("output picker: set default output failed: \(err)") }
    }
}
