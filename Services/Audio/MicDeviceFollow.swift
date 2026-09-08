import Foundation

/// A live recording follows the current input device.
///
/// On macOS a device change during capture is ordinary, not exceptional: a
/// Bluetooth headset switches to its hands-free profile the moment recording
/// starts, a monitor with a microphone is plugged in, AirPods connect. The
/// recorder used to treat every one of those as a fatal interruption — destroy
/// the engine, drop the recording, write a line about it — so a dictation on a
/// headset captured nothing at all while the indicator stayed on (owner's log,
/// 2026-09-08 19:23: eight seconds of speech, `0 samples, discarding`).
///
/// Following is the normal path, for dictation and for meetings alike. The
/// meeting recorder's once-a-second tick remains the outer net for what a
/// rebind cannot fix — no device at all, a revoked permission, a stream that
/// binds and delivers silence — and it stands down while a follow is in
/// flight so two owners never rebind one engine.
///
/// Pure, so what "follows" means is arguable without plugging anything in.
enum MicDeviceFollow {

    /// A rebind can provoke the next configuration change, so the follow is
    /// bounded — but generously. A headset that switches profile on start and
    /// again on the first packet has already used two; giving up early is the
    /// failure the owner reported.
    static let maxAttempts = 6

    /// Long enough for the device to finish appearing, short enough that a
    /// dictation is not over before the microphone is back.
    static let settleDelaySeconds: Double = 0.35

    static func shouldFollow(wasRecording: Bool, attempts: Int) -> Bool {
        wasRecording && attempts < maxAttempts
    }
}
