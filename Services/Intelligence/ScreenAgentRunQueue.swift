import Foundation

/// One active run, one newest context waiting.
///
/// The proactive path guarded on an `isRunning` flag and returned, so every
/// context that arrived during a model call was dropped. With calls allowed
/// twenty seconds and windows changing far faster than that, the screens the
/// user actually moved to were the ones discarded, and the answer that came
/// back was about the screen they had left. The agent was structurally
/// guaranteed to comment on the past.
///
/// Holding the newest one instead costs a single slot and inverts that: what is
/// thrown away is the stale middle, never the user's current screen.
///
/// Pure and generic over the token so it can be tested without a capture stack.
struct ScreenAgentRunQueue<Token: Equatable> {

    enum Outcome: Equatable {
        case startNow(Token)
        case queued
        /// A newer context arrived before the waiting one ever ran.
        case replacedPending(dropped: Token)
        case idle
    }

    private(set) var isRunning = false
    private var pending: Token?

    mutating func submit(_ token: Token) -> Outcome {
        guard isRunning else {
            isRunning = true
            return .startNow(token)
        }
        if let previous = pending {
            pending = token
            return .replacedPending(dropped: previous)
        }
        pending = token
        return .queued
    }

    /// Call when the active run ends, however it ended.
    mutating func finish() -> Outcome {
        guard isRunning else { return .idle }
        guard let next = pending else {
            isRunning = false
            return .idle
        }
        pending = nil
        return .startNow(next)
    }

    /// Feature off, screen history deleted, owner changed. Strands the active
    /// run and anything waiting; a run finishing afterwards cannot start the
    /// context that was queued before the cancel.
    mutating func cancelAll() {
        isRunning = false
        pending = nil
    }
}
