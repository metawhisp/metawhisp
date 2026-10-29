import Foundation

/// The stop token of one live-hints session.
///
/// A session that was stopped owns nothing any more: it starts no request,
/// it publishes nothing into the card and it takes no shortcut (§6.15).
///
/// The token is the one cancellation of the session. Every part that can
/// reach the engine or the model holds it and checks it **right before** the
/// call — never after it — so a request that was on its way when the meeting
/// ended never leaves the app. Every task the parts spawn is kept by the
/// token and cancelled with it, so nothing keeps running in the background
/// after the meeting is over.
final class LiveHintsStopToken: @unchecked Sendable {

    private let lock = NSLock()
    /// True when the session was stopped.
    private var isStopped = false
    /// The ways to cancel the tasks the session spawned.
    private var cancellations: [UUID: () -> Void] = [:]

    /// True when the session was stopped: no new work may start.
    var isCancelled: Bool { lock.withLock { isStopped } }

    /// Stops the token: every task it holds is cancelled, and nothing that
    /// asks it afterwards may start.
    ///
    /// Stopping twice is the same as stopping once.
    func stop() {
        let held: [() -> Void] = lock.withLock {
            guard !isStopped else { return [] }
            isStopped = true
            let held = Array(cancellations.values)
            cancellations.removeAll()
            return held
        }
        for cancel in held { cancel() }
    }

    /// Keeps a way to cancel a task, so the session can cancel it when it
    /// stops.
    ///
    /// A task that is given to a token that is already stopped is cancelled
    /// at once: it must not outlive the session it belongs to.
    ///
    /// The handle that comes back releases the task again when it is over.
    @discardableResult
    func retain(_ cancel: @escaping () -> Void) -> UUID {
        let handle = UUID()
        let isAlreadyStopped = lock.withLock { () -> Bool in
            guard !isStopped else { return true }
            cancellations[handle] = cancel
            return false
        }
        if isAlreadyStopped { cancel() }
        return handle
    }

    /// Lets a task go: it is over and needs no cancelling.
    func release(_ handle: UUID) {
        lock.withLock { cancellations[handle] = nil }
    }

    /// Keeps a task with the token, so the session can cancel it.
    ///
    /// The task is let go again when it is over: the token holds nothing that
    /// has already ended.
    @discardableResult
    func retain<T>(_ task: Task<T, Never>) -> UUID {
        let handle = retain { task.cancel() }
        Task { [weak self] in
            await task.value
            self?.release(handle)
        }
        return handle
    }
}
