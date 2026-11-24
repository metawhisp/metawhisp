import AVFoundation
import CoreAudio
import Foundation

/// Read-only handle to a macOS audio input device. Used by Settings to let
/// the user pick which mic the app records from (built-in / AirPods / USB
/// interface / etc.). Default device behaviour is preserved by treating an
/// empty `uid` as "follow system default".
struct AudioInputDevice: Identifiable, Equatable, Hashable {
    /// Stable across plug-cycles. Persisted in `AppSettings.preferredInputDeviceUID`.
    let uid: String
    /// Human-readable name shown in the picker (e.g. "MacBook Pro Microphone").
    let name: String
    /// Runtime CoreAudio handle — only valid for the current process lifetime.
    let deviceID: AudioDeviceID

    var id: String { uid }
}

enum AudioInputCatalog {
    /// Enumerate every audio device that has at least one input stream. Skips
    /// pure output devices (speakers, displays). Returns the system default
    /// FIRST when present so the picker can highlight it.
    static func availableInputDevices() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let defaultID = systemDefaultInputDeviceID()
        var result: [AudioInputDevice] = []
        for id in ids {
            guard hasInputStreams(deviceID: id) else { continue }
            let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceNameCFString) ?? "(unnamed)"
            guard !uid.isEmpty else { continue }
            result.append(AudioInputDevice(uid: uid, name: name, deviceID: id))
        }
        // Sort: system default first, then alphabetical.
        return result.sorted { a, b in
            if a.deviceID == defaultID { return true }
            if b.deviceID == defaultID { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The Mac's own microphone, by transport type — the one input that is
    /// always present. Recovery asks for it by name after the system default
    /// following a device change has failed repeatedly (the 24 kHz aggregate
    /// that followed the 2026-09-02 change bound fine and delivered nothing).
    static func builtInMicrophone() -> AudioInputDevice? {
        availableInputDevices().first {
            transportType(deviceID: $0.deviceID) == kAudioDeviceTransportTypeBuiltIn
        }
    }

    /// Resolve a persisted UID back to a runtime device. nil if the device
    /// was unplugged since the user picked it — caller should fall back to
    /// the system default in that case.
    static func device(forUID uid: String) -> AudioInputDevice? {
        guard !uid.isEmpty else { return nil }
        return availableInputDevices().first { $0.uid == uid }
    }

    /// A device as one log line: name, UID and runtime id.
    static func description(of deviceID: AudioDeviceID) -> String {
        let name = stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "?"
        let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "?"
        return "\(name) [\(uid)] id=\(deviceID)"
    }

    static func isBuiltIn(_ deviceID: AudioDeviceID) -> Bool {
        transportType(deviceID: deviceID) == kAudioDeviceTransportTypeBuiltIn
    }

    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(deviceID: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - Private helpers

    static func systemDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return value
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
