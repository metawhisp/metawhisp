import Foundation

/// Common interface for audio capture sources (microphone, system audio).
/// Both AudioRecordingService and SystemAudioCaptureService conform to this.
@MainActor
protocol AudioSource: AnyObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var audioBars: [Float] { get }
    var hasPermission: Bool { get }
    /// Nobody has answered the permission prompt yet, so asking would show it.
    var permissionUndetermined: Bool { get }
    /// Shows the permission prompt — only for a user's action.
    func requestPermission(_ ask: PermissionAsk) async -> Bool
    /// Starts a recording at once; the input is opened off the main thread (ITER-086). `reported` hears how that went
    /// — nil when the capture runs, the error when it did not — on the main actor, after `start` returned, and not at
    /// all for a recording stopped first. A throw is a recording that could not even be asked for.
    func start(reported: @escaping @MainActor (Error?) -> Void) throws
    func stop() -> [Float]
    /// The recorder's verdict that the microphone delivered nothing, still readable after `stop()`.
    var micHealthError: String? { get }
    /// Changes on every explicit `start()` and `stop()`, so it names one
    /// recording: a cleanup that belongs to a recording stops that one and
    /// never the next (round-2 N3).
    var captureSession: Int { get }
}

extension AudioSource {
    var micHealthError: String? { nil }

    /// A start whose outcome the caller reads from the stream itself.
    func start() throws { try start(reported: { _ in }) }
}
