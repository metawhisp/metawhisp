import Foundation

/// A live call with a deadline whose outcome stays typed.
///
/// `Deadline.run` (Services/Agent/Deadline.swift) answers `nil` for every
/// failure, so a caller cannot tell a timeout from an error — and the two
/// mean different things here: a timeout drops the text of one clip, while an
/// error whose message says the monthly minutes are gone stops the live hints
/// for the meeting. This keeps the four outcomes apart.
///
/// A timeout is not the end of the work. The call goes on to completion and
/// its result is thrown away by the answer logic; the caller learns about
/// that separately, through `onFinish`, which fires when the work truly
/// finished.
enum LiveCall {

    /// What a call ended with.
    enum Outcome<T> {
        /// The work returned.
        case text(T)
        /// The deadline came first. The work goes on.
        case timeout
        /// The caller cancelled the call.
        case cancelled
        /// The work threw. The error is kept as it was thrown.
        case failed(Error)
    }

    /// Runs `work` under a deadline.
    ///
    /// - Parameters:
    ///   - limit: how long the caller waits for the answer.
    ///   - onFinish: called when the work truly finished — after a timeout,
    ///     with the work's own outcome. Called once, never for the timeout
    ///     itself.
    ///   - work: the call.
    /// - Returns: what the caller acts on now: the text, a timeout, a
    ///   cancellation, or the error.
    @discardableResult
    static func run<T: Sendable>(within limit: Duration,
                                 onFinish: (@Sendable (Outcome<T>) -> Void)? = nil,
                                 _ work: @escaping @Sendable () async throws -> T) async -> Outcome<T> {
        let clock = ContinuousClock()
        let cutoff = clock.now + limit
        let first = FirstOutcome<T>()
        let worker = Worker()

        let outcome = await withTaskCancellationHandler {
            let started = worker.start {
                Task {
                    let outcome: Outcome<T>
                    do {
                        outcome = .text(try await work())
                    } catch is CancellationError {
                        outcome = .cancelled
                    } catch {
                        outcome = .failed(error)
                    }
                    onFinish?(outcome)
                    first.resolve(outcome)
                }
            }
            guard started else {
                // The caller cancelled before the work began: nothing runs,
                // and the caller is told the call is over.
                onFinish?(.cancelled)
                first.resolve(.cancelled)
                return LiveCall.Outcome<T>.cancelled
            }

            let timer = Task {
                do {
                    try await Task.sleep(until: cutoff, clock: clock)
                    first.resolve(.timeout)
                } catch {
                    // The timer was cancelled: the work won the race.
                }
            }
            let outcome = await withCheckedContinuation { first.wait(with: $0) }
            timer.cancel()
            return outcome
        } onCancel: {
            // The caller gave up: the work is cancelled with it. A timeout is
            // not a cancellation — the work keeps running there.
            worker.cancel()
            first.resolve(.cancelled)
        }
        return outcome
    }
}

/// The outcome of a live call. The error is kept as it was thrown, so the
/// caller can read the server's message off it.
extension LiveCall.Outcome: @unchecked Sendable where T: Sendable {}

/// The first outcome wins: a timeout that arrives after the work finished
/// must not overwrite the text.
private final class FirstOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: LiveCall.Outcome<T>?
    private var continuation: CheckedContinuation<LiveCall.Outcome<T>, Never>?

    func resolve(_ outcome: LiveCall.Outcome<T>) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }

    func wait(with continuation: CheckedContinuation<LiveCall.Outcome<T>, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
}

/// The work's task. A cancellation reaches it whenever it comes.
private final class Worker: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    /// Starts the work unless it was cancelled first. The task is made under
    /// the lock, so a cancellation meanwhile waits for it and then cancels
    /// it. Answers whether the work started at all.
    func start(_ make: () -> Task<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        task = make()
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}
