import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import os

/// What can happen to a capture's device under a live recording.
enum MicCaptureEvent: Equatable {
    /// The device's input format no longer matches the one the capture delivers.
    case formatChanged
    /// The device went away.
    case deviceGone
}

/// One input device, captured for a recording.
protocol MicCapture: AnyObject, Sendable {
    /// The format buffers arrive in.
    var format: AVAudioFormat { get }
    /// Starts delivering buffers to `handler`, off the main thread, and news of the device to `onEvent`.
    func start(handler: @escaping AVAudioNodeTapBlock, onEvent: @escaping @MainActor (MicCaptureEvent) -> Void) throws
    /// Stops for good. It may wait on the audio system, so callers run it off the main thread.
    func stop()
}

/// Captures one input device through the HAL output unit with its output side disabled (Apple TN2091).
///
/// AVAudioEngine runs input and output as one combined device on macOS. Opening a Bluetooth headset's microphone
/// switches the headset to its call profile, which changes the OUTPUT side of that device; the engine resets, a
/// recorder that follows it opens the microphone again, and the loop records nothing (owner's log, 2026-10-13: three
/// headset dictations, 3, 5 and 6 switches, 0 samples each). This unit holds the input alone.
///
/// Threads: the device's IO thread renders into preallocated slots and signals; it allocates nothing and only ever
/// tries a lock, never waits on one. A delivery thread gathers the slots into buffers of `deliveryFrames` and hands
/// them to the handler.
final class InputOnlyCapture: MicCapture, @unchecked Sendable {

    let format: AVAudioFormat
    private let deviceID: AudioDeviceID
    private let unit: AudioUnit

    // The device thread fills a slot only while it holds a `free` token and hands it over with `filled`: each slot
    // belongs to one side at a time, and the semaphores order the writes before the reads.
    private static let slotCount = 32
    private let slots: [AVAudioPCMBuffer]
    private let slotData: UnsafeMutablePointer<UnsafeMutableRawPointer>
    private let slotFrames: UnsafeMutablePointer<UInt32>
    private let slotTimes: UnsafeMutablePointer<AudioTimeStamp>
    private let slotCapacity: UInt32
    private let free = DispatchSemaphore(value: InputOnlyCapture.slotCount)
    private let filled = DispatchSemaphore(value: 0)
    private var writeIndex = 0   // the device thread's alone
    /// Open while the unit may call in. `stop()` closes it, waiting out a render in progress; the device thread only
    /// ever tries it, so it never waits.
    private let renderGate = OSAllocatedUnfairLock(initialState: true)

    /// The size the engine's tap was asked for, and delivered — tens of buffers a second: meters keep their pace, and
    /// a stop leaves no more undelivered than a tap did.
    static let deliveryFrames: AVAudioFrameCount = 1_024
    private let chunk: AVAudioPCMBuffer
    private let chunkFrames = InputOnlyCapture.deliveryFrames

    private let lock = NSLock()
    private var handler: AVAudioNodeTapBlock?
    private var onEvent: (@MainActor (MicCaptureEvent) -> Void)?
    private var delivering = false
    private var stopped = false
    private let deliveryEnded = DispatchSemaphore(value: 0)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "com.metawhisp.input-only-capture")

    init(deviceID: AudioDeviceID) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Self.failure(kAudioUnitErr_FailedInitialization)
        }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw Self.failure(kAudioUnitErr_FailedInitialization) }

        let format: AVAudioFormat
        let capacity: UInt32
        do {
            // Input on, output off — before the device is set (TN2091).
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                                &on, flagSize))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                                &off, flagSize))
            var device = deviceID
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                kAudioUnitScope_Global, 0, &device,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)))
            // The device's side of the input element is its format; the unit converts channels and sample format
            // to ours but not the sample rate, so ours keeps the device's rate. Mono, as the recorder keeps.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                                &hardware, &size))
            guard hardware.mSampleRate > 0,
                  let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                             channels: 1, interleaved: false) else {
                throw AudioRecordingService.RecordingError.noInputDevice
            }
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                                client.streamDescription, size))
            // A render larger than a slot is dropped, so a slot holds the most either side may ask for.
            var maxFrames: UInt32 = 0
            var maxSize = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                                kAudioUnitScope_Global, 0, &maxFrames, &maxSize))
            var deviceFrames: UInt32 = 0
            var deviceSize = UInt32(MemoryLayout<UInt32>.size)
            var bufferSize = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(deviceID, &bufferSize, 0, nil, &deviceSize, &deviceFrames)
            format = client
            capacity = max(maxFrames, deviceFrames, 4_096)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        self.deviceID = deviceID
        self.unit = unit
        self.format = format
        self.slotCapacity = capacity
        self.slots = (0..<Self.slotCount).map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)! }
        self.slotData = .allocate(capacity: Self.slotCount)
        self.slotData.initialize(from: slots.map { UnsafeMutableRawPointer($0.floatChannelData![0]) },
                                 count: Self.slotCount)
        self.slotFrames = .allocate(capacity: Self.slotCount)
        self.slotFrames.initialize(repeating: 0, count: Self.slotCount)
        self.slotTimes = .allocate(capacity: Self.slotCount)
        self.slotTimes.initialize(repeating: AudioTimeStamp(), count: Self.slotCount)
        self.chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.deliveryFrames + capacity)!

        // From here a failure is released through `deinit`, which stops and disposes the unit.
        var callback = AURenderCallbackStruct(inputProc: inputOnlyRender,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                                            0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try Self.check(AudioUnitInitialize(unit))
    }

    deinit {
        stop()
        slotData.deallocate()
        slotFrames.deallocate()
        slotTimes.deallocate()
    }

    func start(handler: @escaping AVAudioNodeTapBlock, onEvent: @escaping @MainActor (MicCaptureEvent) -> Void) throws {
        lock.withLock {
            self.handler = handler
            self.onEvent = onEvent
            delivering = true
        }
        let delivery = Thread { [self] in deliver() }
        delivery.name = "MetaWhisp microphone"
        delivery.qualityOfService = .userInteractive
        delivery.start()
        listen()
        try Self.check(AudioOutputUnitStart(unit))
    }

    func stop() {
        let first: Bool = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        AudioOutputUnitStop(unit)
        renderGate.withLock { $0 = false }   // no render is running, and none will touch the unit again
        for (object, address, block) in lock.withLock({ listeners }) {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
        let threadRunning: Bool = lock.withLock {
            defer { delivering = false }
            return delivering
        }
        if threadRunning {
            filled.signal()
            deliveryEnded.wait()
        }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    // MARK: - Device thread

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        renderGate.withLockIfAvailableUnchecked { open in
            // No free slot: the delivery thread is behind by the whole ring — this cycle is dropped, and the
            // recorder places the gap as silence by the device's sample clock.
            guard open, frames <= slotCapacity, free.wait(timeout: .now()) == .success else { return }
            let slot = writeIndex % Self.slotCount
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1,
                                                             mDataByteSize: frames * UInt32(MemoryLayout<Float>.size),
                                                             mData: slotData[slot]))
            // A failed render (the device's format moved under the unit) delivers nothing; the clock check sees
            // the stream stop and binds again.
            guard AudioUnitRender(unit, flags, time, 1, frames, &list) == noErr else {
                free.signal()
                return
            }
            slotFrames[slot] = frames
            slotTimes[slot] = time.pointee
            writeIndex += 1
            filled.signal()
        }
        return noErr
    }

    // MARK: - Delivery thread

    private func deliver() {
        let handler = lock.withLock { self.handler }
        var readIndex = 0
        var chunkStart = AudioTimeStamp()
        chunk.frameLength = 0
        while true {
            filled.wait()
            guard lock.withLock({ delivering }) else { break }
            let slot = readIndex % Self.slotCount
            readIndex += 1
            let frames = slotFrames[slot]
            let time = slotTimes[slot]
            // A dropped cycle is a gap in the device's clock: what was gathered goes first, so the recorder
            // places the gap where it happened.
            let continues = chunk.frameLength > 0
                && abs(time.mSampleTime - (chunkStart.mSampleTime + Double(chunk.frameLength))) < 1
            if chunk.frameLength > 0, !continues {
                hand(chunk, at: &chunkStart, to: handler)
            }
            if chunk.frameLength == 0 { chunkStart = time }
            memcpy(chunk.floatChannelData![0] + Int(chunk.frameLength), slotData[slot],
                   Int(frames) * MemoryLayout<Float>.size)
            chunk.frameLength += frames
            free.signal()
            if chunk.frameLength >= chunkFrames { hand(chunk, at: &chunkStart, to: handler) }
        }
        deliveryEnded.signal()
    }

    private func hand(_ buffer: AVAudioPCMBuffer, at start: inout AudioTimeStamp,
                      to handler: AVAudioNodeTapBlock?) {
        handler?(buffer, AVAudioTime(audioTimeStamp: &start, sampleRate: format.sampleRate))
        buffer.frameLength = 0
    }

    // MARK: - The device

    /// The device leaving, and its input format moving away from ours. A change of the OUTPUT side — the headset's
    /// call profile — changes neither, and is exactly what this capture must ride through.
    private func listen() {
        listen(to: deviceID, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self, !self.isAlive else { return }
            self.emit(.deviceGone)
        }
        listen(to: deviceID, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.checkFormat() }
        if let stream = inputStream {
            listen(to: stream, kAudioStreamPropertyVirtualFormat) { [weak self] in self?.checkFormat() }
        }
    }

    private func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ changed: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr else { return }
        lock.withLock { listeners.append((object, address, block)) }
    }

    private func checkFormat() {
        guard let rate = inputRate, rate > 0, rate != format.sampleRate else { return }
        emit(.formatChanged)
    }

    private func emit(_ event: MicCaptureEvent) {
        guard let onEvent = lock.withLock({ stopped ? nil : self.onEvent }) else { return }
        Task { @MainActor in onEvent(event) }
    }

    private var isAlive: Bool {
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        // Asked when the property changed, and a device never comes back to life: unreadable means gone.
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    /// The device's first input stream.
    private var inputStream: AudioStreamID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    /// The sample rate the device's input delivers now.
    private var inputRate: Double? {
        guard let stream = inputStream else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &description) == noErr else { return nil }
        return description.mSampleRate
    }

    // MARK: - Errors

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw failure(status) }
    }

    /// The system's own words for the status, as the engine's errors were shown.
    private static func failure(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

/// The device's IO thread enters here: no allocation, no lock, no Swift runtime work beyond the call.
private func inputOnlyRender(_ refCon: UnsafeMutableRawPointer,
                             _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                             _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<InputOnlyCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, frames)
}

/// Tells when macOS's default input device changes. Installed for as long as it is held.
final class DefaultInputObserver {
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
    private let queue = DispatchQueue(label: "com.metawhisp.default-input")
    private var block: AudioObjectPropertyListenerBlock?

    init(_ changed: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue,
                                               block) == noErr {
            self.block = block
        }
    }

    deinit {
        if let block {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }
}
