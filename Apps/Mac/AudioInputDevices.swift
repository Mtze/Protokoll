import CoreAudio
import Foundation
import SharedKit

/// Enumerates the machine's audio **input** devices via the CoreAudio HAL.
///
/// We go through the HAL rather than `AVCaptureDevice.DiscoverySession` on
/// purpose: the capture-device API omits virtual and aggregate devices (e.g.
/// BlackHole, Loopback, an Aggregate Device), which are exactly what power
/// users route meeting audio through. The HAL lists every device the system
/// knows about; we keep the ones that expose input channels.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// The device's persistent UID (`kAudioDevicePropertyDeviceUID`). Stable
    /// across reboots/replug, so it is what we store in preferences.
    let uid: String
    /// Localized, human-readable device name.
    let name: String

    var id: String { uid }
}

enum AudioInputDevices {
    /// All input-capable devices currently present, in HAL order.
    static func available() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard hasInputChannels(id), let uid = uid(of: id) else { return nil }
            let name = name(of: id) ?? uid
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Resolves a stored UID back to a live `AudioDeviceID`, or `nil` if the
    /// device is no longer present (unplugged, driver removed).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in deviceIDs() where AudioInputDevices.uid(of: id) == uid {
            return id
        }
        return nil
    }

    /// The machine's current default input device, or `nil` if none is set. Used
    /// to actively follow the system default when no device is preferred.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - HAL helpers

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            if status != noErr {
                AppLog.recording.warning("device enumeration size query failed status=\(status, privacy: .public)")
            }
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else {
            AppLog.recording.warning("device enumeration failed status=\(status, privacy: .public)")
            return []
        }
        return ids
    }

    /// True when the device has at least one input channel (skips output-only
    /// devices like plain speakers).
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let lists = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        for buffer in lists where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
    }

    /// Reads a `CFString`-valued device property.
    private static func stringProperty(
        _ id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
