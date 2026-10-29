import Foundation

/// The cancellation of one request.
///
/// The token of the session stops everything when the meeting ends. This is
/// the other scope: it cancels one request — its task — and invalidates its
/// id, so a result that was on its way never reaches the card (§3.0).
///
/// The handle is not the token of the session. Calling one request off leaves
/// the session's work running: the manual answers, the speech recognition,
/// the batches and the memo all go on (§3.0).
final class LiveHintsRequestHandle: @unchecked Sendable {

    private let lock = NSLock()
    /// True when the request was called off.
    private var isCancelledNow = false
    /// The way to cancel the task of the request.
    private var cancellations: [() -> Void] = []

    /// True when the request was called off: its id is invalid and its result
    /// is never drawn.
    var isCancelled: Bool { lock.withLock { isCancelledNow } }

    /// Calls the request off: its task is cancelled, and its id is invalid.
    ///
    /// Calling off twice is the same as calling off once.
    func cancel() {
        let held = lock.withLock { () -> [() -> Void] in
            guard !isCancelledNow else { return [] }
            isCancelledNow = true
            let held = cancellations
            cancellations = []
            return held
        }
        for cancel in held { cancel() }
    }

    /// Releases completed tasks, including the task that owned this handle.
    func finish() {
        lock.withLock { cancellations = [] }
    }

    /// Gives the handle the way to cancel the task of the request.
    ///
    /// A task that is given to a handle that was already called off is
    /// cancelled at once: it must not go on after the request was called off.
    func attach(cancel: @escaping () -> Void) {
        let isAlreadyCancelled = lock.withLock { () -> Bool in
            guard !isCancelledNow else { return true }
            cancellations.append(cancel)
            return false
        }
        if isAlreadyCancelled { cancel() }
    }
}
