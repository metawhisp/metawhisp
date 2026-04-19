import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Captures system audio output using ScreenCaptureKit (macOS 14+).
/// Converts to 16kHz mono Float32 PCM for WhisperKit transcription.
/// Used for meeting recording (Zoom, Meet, Teams, etc.)
@MainActor
final class SystemAudioCaptureService: NSObject, ObservableObject, AudioSource {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0
    @Published var audioBars: [Float] = Array(repeating: 0, count: 24)
    /// Last error — surfaced to UI so user knows why recording failed to start.
    @Published var lastError: String?
    /// Set to true while async setup is in progress so UI can show "starting" state.
    @Published var isStarting = false

    private var samples: [Float] = []
    private let targetSampleRate: Double = 16000
    private var barPhase: Double = 0

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.metawhisp.system-audio", qos: .userInteractive)
    private var streamOutput: AudioStreamOutput?

    /// Based on Screen Recording permission — system audio via SCStream needs it.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Actively request Screen Recording permission (triggers TCC dialog).
    func requestPermission() async -> Bool {
        await PermissionsService.shared.requestScreenRecording()
    }

    /// Start capturing all system audio.
    /// Synchronously throws only for immediate state errors — actual SCStream setup is async.
    func start() throws {
        guard !isRecording, !isStarting else { return }
        samples = []
        samples.reserveCapacity(Int(targetSampleRate) * 300) // ~5 min pre-alloc
        lastError = nil
        isStarting = true

        // ScreenCaptureKit setup happens async. If permission is missing,
        // SCShareableContent will either trigger the dialog or throw.
        Task { [weak self] in
            guard let self else { return }

            // Pre-flight: if permission is denied, proactively trigger the TCC dialog
            // so user sees WHY the button "did nothing".
            if !CGPreflightScreenCaptureAccess() {
                NSLog("[SystemAudio] No Screen Recording permission — requesting...")
                _ = await PermissionsService.shared.requestScreenRecording()

                if !CGPreflightScreenCaptureAccess() {
                    // Keep the popover open — surface error in UI with a clickable hint.
                    // DO NOT auto-open System Settings here: it steals focus and closes
                    // the popover, making the user think "nothing happened".
                    // User can click the error banner to open Settings (see popover strip).
                    self.lastError = "🎥 Screen Recording denied. Click here to open Settings"
                    self.isStarting = false
                    return
                }
            }

            do {
                try await self.setupStream()
                self.isRecording = true
                self.isStarting = false
                NSLog("[SystemAudio] ✅ Capture started via ScreenCaptureKit")
            } catch {
                self.lastError = "System audio failed: \(error.localizedDescription)"
                self.isStarting = false
                NSLog("[SystemAudio] ❌ Failed to start: %@", error.localizedDescription)
            }
        }
    }

    /// Stop capturing and return collected PCM samples.
    func stop() -> [Float] {
        Task {
            try? await stream?.stopCapture()
        }
        stream = nil
        streamOutput = nil
        isRecording = false
        audioLevel = 0
        audioBars = Array(repeating: 0, count: 24)

        let result = samples
        samples = []
        NSLog("[SystemAudio] Stopped, %d samples collected", result.count)
        return result
    }

    // MARK: - ScreenCaptureKit Setup

    private func setupStream() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Filter: capture entire display but we only want audio
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // We only want audio — minimize video capture
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
        config.capturesAudio = true
        config.sampleRate = 48000 // Capture at high quality, resample later
        config.channelCount = 2
        // Exclude MetaWhisp's own audio to avoid feedback
        config.excludesCurrentProcessAudio = true

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Create output handler
        let output = AudioStreamOutput { [weak self] sampleBuffer in
            self?.processSampleBuffer(sampleBuffer)
        }
        self.streamOutput = output

        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    // MARK: - Audio Processing

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == noErr, let data = dataPointer else { return }

        // Get format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bitsPerChannel = asbd.pointee.mBitsPerChannel
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        let frameCount: Int
        if isFloat && bitsPerChannel == 32 {
            frameCount = length / (MemoryLayout<Float>.size * channelCount)
        } else if bitsPerChannel == 16 {
            frameCount = length / (MemoryLayout<Int16>.size * channelCount)
        } else {
            return // Unsupported format
        }

        guard frameCount > 0 else { return }

        // Convert to mono Float32
        var mono = [Float](repeating: 0, count: frameCount)

        if isFloat && bitsPerChannel == 32 {
            let floatPtr = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: frameCount * channelCount)
            if channelCount == 1 {
                mono = Array(UnsafeBufferPointer(start: floatPtr, count: frameCount))
            } else {
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += floatPtr[i * channelCount + ch]
                    }
                    mono[i] = sum / Float(channelCount)
                }
            }
        } else if bitsPerChannel == 16 {
            let int16Ptr = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: frameCount * channelCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(int16Ptr[i * channelCount + ch]) / 32768.0
                }
                mono[i] = sum / Float(channelCount)
            }
        }

        // Calculate level
        var sumSq: Float = 0
        for s in mono { sumSq += s * s }
        let rms = sqrtf(sumSq / Float(mono.count))
        let level = sqrtf(min(rms * 12.0, 1.0))

        // Resample to 16kHz (linear interpolation)
        let ratio = targetSampleRate / sampleRate
        let outCount = Int(Double(frameCount) * ratio)
        guard outCount > 0 else { return }
        var resampled = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let s0 = idx0 < mono.count ? mono[idx0] : 0
            let s1 = (idx0 + 1) < mono.count ? mono[idx0 + 1] : s0
            resampled[i] = s0 + frac * (s1 - s0)
        }

        Task { @MainActor in
            self.samples.append(contentsOf: resampled)
            self.audioLevel = level
            self.updateBars(level: level)
        }
    }

    private func updateBars(level: Float) {
        barPhase += 0.12
        let count = 24
        let mid = count / 2
        for i in 0..<count {
            let distFromCenter = abs(i - mid)
            let normalizedDist = Double(distFromCenter) / Double(mid)
            let f1 = sin(barPhase * 1.0 + Double(i) * 0.5) * 0.4
            let f2 = sin(barPhase * 2.3 + Double(i) * 0.8) * 0.25
            let f3 = sin(barPhase * 3.7 + Double(i) * 1.2) * 0.15
            let variation = 0.5 + f1 + f2 + f3
            let envelope = 1.0 - normalizedDist * 0.65
            let raw = Double(level) * variation * envelope
            audioBars[i] = Float(max(0.03, min(1.0, raw)))
        }
    }

    // MARK: - Meeting Detection

    /// Detect if a video call app is currently running.
    static func detectActiveMeetingApp() -> String? {
        let meetingBundleIDs: [String: String] = [
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams2": "Teams",
            "com.microsoft.teams": "Teams",
            "com.apple.FaceTime": "FaceTime",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.discord.Discord": "Discord",
            "com.webex.meetingmanager": "Webex",
        ]

        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, let name = meetingBundleIDs[bundleID] {
                return name
            }
        }
        return nil
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display found for system audio capture"
            }
        }
    }
}

// MARK: - SCStreamOutput Handler

/// Wraps the SCStreamOutput protocol to forward audio buffers via closure.
private final class AudioStreamOutput: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}
