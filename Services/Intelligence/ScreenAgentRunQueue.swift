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

    /// Proof that a completion belongs to the run that is actually active.
    ///
    /// Without one, `submit(A) -> cancelAll() -> submit(C) -> late finish(A)`
    /// lets A's stale completion finish C: it clears the running flag, so
    /// another run starts alongside C, or it promotes C's successor while C is
    /// still going. Cancellation and timeouts make late completions normal, not
    /// exotic, so the queue has to be able to say "that is not the run I am
    /// waiting for".
    struct RunPermit: Equatable {
        fileprivate let epoch: Int
        fileprivate let serial: Int
    }

    enum Outcome: Equatable {
        case startNow(Token, RunPermit)
        case queued
        /// A newer context arrived before the waiting one ever ran.
        case replacedPending(dropped: Token)
        /// The waiting context sat out the deadline. By then the user has moved
        /// on, so it is dropped rather than delivered late.
        case expired(Token)
        case idle
    }

    private(set) var isRunning = false
    private var pending: Token?
    private var pendingSince: Date?
    private var epoch = 0
    private var serial = 0
    private var activePermit: RunPermit?

    mutating func submit(_ token: Token, at now: Date) -> Outcome {
        guard isRunning else { return .startNow(token, issuePermit()) }
        if let previous = pending {
            pending = token
            pendingSince = now
            return .replacedPending(dropped: previous)
        }
        pending = token
        pendingSince = now
        return .queued
    }

    /// Call when the active run ends, however it ended. A permit that is not
    /// the active one is a stale or duplicate completion and is ignored.
    mutating func finish(_ permit: RunPermit, at now: Date) -> Outcome {
        guard permit == activePermit else { return .idle }
        activePermit = nil

        guard let next = pending else {
            isRunning = false
            return .idle
        }
        pending = nil
        let waited = pendingSince.map { now.timeIntervalSince($0) } ?? 0
        pendingSince = nil

        guard waited <= ScreenAgentTimingPolicy.endToEndDeadline else {
            isRunning = false
            return .expired(next)
        }
        return .startNow(next, issuePermit())
    }

    /// Feature off, screen history deleted, owner changed. Bumping the epoch
    /// invalidates any permit already handed out, so a run that was started
    /// before the cancel cannot report back into the queue afterwards.
    mutating func cancelAll() {
        epoch += 1
        isRunning = false
        pending = nil
        pendingSince = nil
        activePermit = nil
    }

    private mutating func issuePermit() -> RunPermit {
        serial += 1
        let permit = RunPermit(epoch: epoch, serial: serial)
        activePermit = permit
        isRunning = true
        return permit
    }
}
