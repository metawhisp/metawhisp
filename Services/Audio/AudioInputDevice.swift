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

    /// Resolve a persisted UID back to a runtime device. nil if the device
    /// was unplugged since the user picked it — caller should fall back to
    /// the system default in that case.
    static func device(forUID uid: String) -> AudioInputDevice? {
        guard !uid.isEmpty else { return nil }
        return availableInputDevices().first { $0.uid == uid }
    }

    /// Bind a chosen input device to an existing `AVAudioEngine`. Must be
    /// called BEFORE `installTap` / `engine.start()` — switching the device
    /// after the input node already has a tap requires a teardown.
    @discardableResult
    static func setInputDevice(_ device: AudioInputDevice, on engine: AVAudioEngine) -> Bool {
        guard let inputUnit = engine.inputNode.audioUnit else { return false }
        var id = device.deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        return status == noErr
    }

    // MARK: - Private helpers

    private static func systemDefaultInputDeviceID() -> AudioDeviceID {
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
