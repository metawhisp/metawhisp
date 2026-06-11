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
    /// TR-9/TR-10 — AVAudioConverter-backed resampler, fresh per capture (clean
    /// filter state per meeting). Only touched from `audioQueue` after start.
    private var resampler: StreamingResampler?
    /// AUD-008 — bumped on every start()/stop(). The async setup task captures its
    /// value and bails after each suspension point if it no longer matches, so a
    /// STOP during setup cannot resurrect a recording the user already cancelled.
    private var startGeneration = 0

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
        resampler = StreamingResampler(outputRate: targetSampleRate)  // TR-9/TR-10
        lastError = nil
        isStarting = true
        startGeneration += 1
        let gen = startGeneration  // AUD-008

        // ScreenCaptureKit setup happens async. If permission is missing,
        // SCShareableContent will either trigger the dialog or throw.
        Task { [weak self] in
            guard let self else { return }

            // Pre-flight: if permission is denied, proactively trigger the TCC dialog
            // so user sees WHY the button "did nothing".
            if !CGPreflightScreenCaptureAccess() {
                NSLog("[SystemAudio] No Screen Recording permission — requesting...")
                _ = await PermissionsService.shared.requestScreenRecording()
                guard self.startGeneration == gen else { return }  // AUD-008: stopped during permission prompt

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
                guard self.startGeneration == gen else {
                    // AUD-008 — user stopped during setup; tear down the stream we just made.
                    try? await self.stream?.stopCapture()
                    self.stream = nil
                    self.streamOutput = nil
                    return
                }
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

    /// ITER-019 — total samples accumulated so far.
    var currentSampleCount: Int { samples.count }

    /// ITER-019 — non-destructive read of samples accumulated since `from`.
    /// Final `stop()` still returns the full recording.
    func peekSamples(from index: Int) -> [Float] {
        guard index < samples.count else { return [] }
        let safeStart = max(0, index)
        return Array(samples[safeStart..<samples.count])
    }

    /// Stop capturing and return collected PCM samples.
    func stop() -> [Float] {
        startGeneration += 1  // AUD-008: invalidate any in-flight start
        isStarting = false
        Task {
            try? await stream?.stopCapture()
        }
        stream = nil
        streamOutput = nil
        resampler = nil   // TR-9/TR-10: late buffers after stop just bail
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

        // TR-9: resample 48→16 kHz via AVAudioConverter (same mechanism as the
        // mic path) — proper anti-aliasing low-pass instead of bare linear
        // interpolation, which folded everything above 8 kHz into the speech
        // band and degraded the "Them" stream. TR-10: the per-capture converter
        // carries the fractional source position across buffers, so no samples
        // are lost at buffer boundaries (the old `Int(frameCount * ratio)`
        // truncated every buffer and drifted mic/system sync on long calls).
        guard let resampler else { return }
        let resampled = resampler.resample(mono, from: sampleRate)
        guard !resampled.isEmpty else { return }

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

    /// Apps treated as call-only (bundle match alone fires call detection).
    /// Includes Zoom + Teams since user reported strict title-matching kept
    /// missing real calls (titles like "User's Personal Meeting Room" or
    /// "Waiting for host" don't contain "Zoom Meeting"). Trade-off: clicking
    /// the Zoom Workplace home window in idle state still fires a 5s
    /// countdown — false positive, user can dismiss. Better than missing
    /// real calls.
    private static let alwaysCallBundleIDs: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "com.webex.meetingmanager": "Webex",
        "com.webex.meetings": "Webex",
        "com.logmein.gotomeeting": "GoTo Meeting",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
    ]

    /// Chat-first apps where call mode is optional and rarely the default.
    /// Title indicator REQUIRED — clicking Slack tab while typing in a thread
    /// shouldn't trigger a recording countdown. Adjusted scope down from
    /// Phase A: Zoom/Teams moved back to always-call after user hit
    /// missed-call cases.
    private static let dualModeCallBundleIDs: [String: [String]] = [
        // Slack: huddle adds "Huddle" to the title.
        "com.tinyspeck.slackmacgap":   ["Huddle"],
        // Discord: voice call shows "Voice Connected" / "Voice Call".
        "com.discord.Discord":         ["Voice Connected", "Voice Call"],
    ]

    /// Browser bundle IDs — we look at the active window title for call keywords.
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",     // Arc
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    /// Window-title keywords that indicate an active video call (matched case-insensitive).
    /// Observed title formats (2026-04-21 missed a Meet call because we required "Google Meet"
    /// but Chrome shows "Meet – <name>..."):
    ///   Chrome in-meeting:  "Meet – Standup A..."        (em-dash)
    ///   Chrome pre-join:    "Meet - Google Chrome - <profile>"     (hyphen, tab title just "Meet")
    ///   Chrome direct URL:  "<name> - Google Meet" / "meet.google.com/..."
    ///   Arc:                "gpq-mmkq-iaz" (room code only)
    private static let callTitleKeywords: [(keyword: String, name: String)] = [
        ("meet.google.com", "Google Meet"),
        ("Google Meet", "Google Meet"),
        ("Meet – ", "Google Meet"),        // Chrome in-meeting (em-dash, Google's own format)
        ("Meet - Google Chrome", "Google Meet"),  // Chrome pre-join (tab title "Meet" + chrome suffix)
        ("Teams - Microsoft", "Teams"),
        ("Microsoft Teams", "Teams"),
        ("Zoom Meeting", "Zoom"),
    ]

    /// Arc (and some Chrome setups) show only the Google Meet room code in the window title
    /// (format `xxx-yyyy-zzz` — lowercase, 3-{3,4}-3 dashes). Word-boundary match so we catch
    /// both Arc (title == code) AND Chrome (title == `code - Google Chrome - profile`).
    /// The old `^...$` anchoring missed Chrome because of the trailing chrome suffix.
    private static let meetRoomCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — literal pattern, cannot fail at runtime.
        try! NSRegularExpression(pattern: #"\b[a-z]{3}-[a-z]{3,4}-[a-z]{3}\b"#)
    }()

    /// Detect if a video call app is currently running (legacy — whole system scan).
    /// Only checks `alwaysCallBundleIDs` (FaceTime / Webex / GoToMeeting) since
    /// dual-mode apps need title verification that this entry point can't do.
    static func detectActiveMeetingApp() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, let name = alwaysCallBundleIDs[bundleID] {
                return name
            }
        }
        return nil
    }

    /// Detect call context from the **currently-frontmost** app + its window title.
    /// Returns display name ("Google Meet", "Zoom", …) or nil if no call is active.
    ///
    /// Two-tier resolution (2026-04-29 strict-mode):
    /// 1. `alwaysCallBundleIDs` — FaceTime/Webex/GoToMeeting are call-only apps,
    ///    bundle match alone is enough.
    /// 2. `dualModeCallBundleIDs` — Zoom/Teams/Slack/Discord are chat-and-call
    ///    apps. Window title MUST contain a call-indicator substring; otherwise
    ///    the user is just browsing the app and we return nil.
    /// 3. Browser bundles → scan title for "Google Meet" / "Teams" / "Zoom Meeting".
    ///
    /// Implements spec://iterations/ITER-002-call-detection#detection
    static func detectCallContext(bundleID: String, appName: String, windowTitle: String) -> String? {
        // Tier 1: always-call apps.
        if let name = alwaysCallBundleIDs[bundleID] { return name }

        // Tier 2: dual-mode apps — require call indicator in title.
        if let titleKeywords = dualModeCallBundleIDs[bundleID] {
            for kw in titleKeywords where windowTitle.localizedCaseInsensitiveContains(kw) {
                // Display name = first word of bundle's family. Reuse the
                // browser-title map's display names for consistency.
                if bundleID.hasPrefix("us.zoom") { return "Zoom" }
                if bundleID.hasPrefix("com.microsoft.teams") { return "Teams" }
                if bundleID.hasPrefix("com.tinyspeck.slack") { return "Slack" }
                if bundleID.hasPrefix("com.discord") { return "Discord" }
                return appName
            }
            // Bundle matched but title didn't — user is browsing the app, not in a call.
            return nil
        }

        // Browser: scan window title for call keywords.
        if browserBundleIDs.contains(bundleID) {
            for (kw, name) in callTitleKeywords where windowTitle.localizedCaseInsensitiveContains(kw) {
                return name
            }
            // Fallback: Arc & some Chrome builds show only the Google Meet room code
            // (xxx-yyyy-zzz) without any "Google Meet" suffix. Regex-match it.
            let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if meetRoomCodeRegex.firstMatch(in: trimmed, range: range) != nil {
                return "Google Meet"
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
