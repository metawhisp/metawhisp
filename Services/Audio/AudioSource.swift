import Foundation

/// Common interface for audio capture sources (microphone, system audio).
/// Both AudioRecordingService and SystemAudioCaptureService conform to this.
@MainActor
protocol AudioSource: AnyObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var audioBars: [Float] { get }
    var hasPermission: Bool { get }
    func requestPermission() async -> Bool
    func start() throws
    func stop() -> [Float]
}
