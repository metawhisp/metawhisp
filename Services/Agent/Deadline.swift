import Foundation

/// Gives up on a call at its deadline (ITER-074 §3.1, §8). The deadline is a
/// moment fixed before the call starts; the first of the call's result, that
/// moment and a cancellation wins. A result at or after the deadline is late
/// and dropped without waiting for it — even from work that ignores
/// cancellation — and an error counts like a timeout: nil either way.
///
/// A cancellation reaches the work before the canceller goes on (ITER-076
/// A1b): work that checks for it afterwards, as a send's guard does, never
/// finds itself still wanted, and a caller already cancelled starts no work.
enum Deadline {
    /// A limit this long is no limit. The clock traps when asked to wait past
    /// what it can represent, as an unlimited `.seconds(Int64.max)` would.
    private static let longest = Duration.seconds(100 * 365 * 24 * 3_600)

    static func run<T: Sendable>(within limit: Duration,
                                 _ work: @escaping @Sendable () async throws -> T) async -> T? {
        let clock = ContinuousClock()
        let cutoff = clock.now + min(limit, longest)
        let first = FirstResult<T>()
        let worker = Worker()
        let value = await withTaskCancellationHandler {
            // Started under the handler, so a cancellation either comes first
            // and nothing starts, or finds the work and cancels it.
            worker.start {
                Task {
                    let value = try? await work()
                    first.resolve(clock.now < cutoff ? value : nil)
                }
            }
            let timer = Task {
                try? await Task.sleep(until: cutoff, clock: clock)
                first.resolve(nil)
            }
            let value = await withCheckedContinuation { first.wait(with: $0) }
            timer.cancel()
            return value
        } onCancel: {
            worker.cancel()
            first.resolve(nil)
        }
        worker.cancel()
        return value
    }
}

/// The work's task, which a cancellation reaches whenever it comes.
private final class Worker: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    /// Starts the work unless it was cancelled first. The task is made under
    /// the lock, so a cancellation meanwhile waits for it and then cancels it.
    func start(_ make: () -> Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        task = make()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// Hands the first result to the waiting caller; everything after it is
/// dropped.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var outcome: T??

    func resolve(_ value: T?) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = .some(value)
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait(with continuation: CheckedContinuation<T?, Never>) {
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
