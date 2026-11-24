import Foundation

/// ITER-086 — where the recorder talks to the audio system. Never on the main thread: a call into Core Audio waits on
/// coreaudiod, and on 2026-11-24 one held MetaWhisp's main thread eight minutes after a call ended — no dictation, no
/// menu, nothing. Never waited on past a deadline: at the deadline the caller hears "not responding", and whatever the
/// call finally returns comes back on its own, for the caller to put away.
struct MicHardware {
    /// A bind takes tens of milliseconds (owner's log, 2026-11-24: 20 ms); three seconds is a microphone that will not
    /// answer.
    var deadline: TimeInterval = 3

    /// Runs `work` on a background thread. `done` gets its result on the main actor — or, when it has not answered by
    /// the deadline, `RecordingError.notResponding`, and then `late` gets what it returned.
    func run<T>(_ work: @escaping @Sendable () throws -> T,
                done: @escaping @MainActor (Result<T, Error>) -> Void,
                late: @escaping @MainActor (Result<T, Error>) -> Void) {
        let first = Once()
        DispatchQueue.global(qos: .userInitiated).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let result = Result { try work() }
            let inTime = first.take()
            let answer = UncheckedBox(result)
            Task { @MainActor in inTime ? done(answer.value) : late(answer.value) }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
            guard first.take() else { return }
            Task { @MainActor in done(.failure(AudioRecordingService.RecordingError.notResponding)) }
        }
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}

/// Carries a result to the main actor; written once on the thread that made it, read once on the main actor.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
