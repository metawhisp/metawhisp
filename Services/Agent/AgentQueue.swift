import Foundation

/// Errands take turns (ITER-074 §8, §11, US-8): one runs, at most three
/// wait, and a waiting one is dropped thirty minutes after it was queued.
/// While an update waits, nothing new starts.
struct AgentQueue {
    struct Errand: Equatable {
        let id: UUID
        let goal: String
        let queuedAt: ContinuousClock.Instant
        /// What the user asked it to give (ITER-076 stage 6).
        var output: ErrandOutput = .answer
        /// Where it begins when its goal names no address (`ErrandSetup.start`).
        var start: URL? = nil
    }

    enum Admission: Equatable {
        case started
        /// The card says the errand is queued; 1 is next.
        case queued(position: Int)
        case refused(Refusal)
    }

    enum Refusal: Equatable { case queueFull, updateWaiting }

    /// A waiting errand that never started, and why — the card says which.
    struct NotStarted: Equatable {
        enum Reason: Equatable { case expired, updateWaiting, stoppedAll }
        let errand: Errand
        let reason: Reason
    }

    static let maxWaiting = 3
    static let maxWait: Duration = .seconds(30 * 60)

    private(set) var running: Errand?
    private(set) var waiting: [Errand] = []
    private(set) var updateWaiting = false

    /// A new errand starts if nothing runs, waits if there is room, and is
    /// refused otherwise. Expired waiting errands are dropped first.
    mutating func submit(_ errand: Errand, now: ContinuousClock.Instant) -> (admission: Admission, notStarted: [NotStarted]) {
        let expired = dropExpired(now: now)
        if updateWaiting { return (.refused(.updateWaiting), expired) }
        if running == nil {
            running = errand
            return (.started, expired)
        }
        guard waiting.count < Self.maxWaiting else { return (.refused(.queueFull), expired) }
        waiting.append(errand)
        return (.queued(position: waiting.count), expired)
    }

    /// The running errand ended — done, stopped, stuck or at a ceiling. The
    /// next waiting one that has not expired starts, unless an update waits.
    mutating func finishRunning(now: ContinuousClock.Instant) -> (started: Errand?, notStarted: [NotStarted]) {
        running = nil
        let expired = dropExpired(now: now)
        guard !updateWaiting, !waiting.isEmpty else { return (nil, expired) }
        running = waiting.removeFirst()
        return (running, expired)
    }

    /// Stop on one waiting errand (ITER-076 B1): it leaves the queue and the
    /// others keep their order. Nil when no waiting errand has that id — the
    /// running one is stopped by its run, which then calls `finishRunning`.
    mutating func remove(_ id: UUID) -> Errand? {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
        return waiting.remove(at: index)
    }

    /// Stop all: the waiting errands never start. The running one is stopped
    /// by its run, which then calls `finishRunning`.
    mutating func stopAll() -> [NotStarted] {
        let dropped = waiting.map { NotStarted(errand: $0, reason: .stoppedAll) }
        waiting = []
        return dropped
    }

    /// An update is ready (§11): the running errand may finish, nothing new
    /// starts, and the waiting ones are recorded as not started.
    mutating func updateIsReady() -> [NotStarted] {
        updateWaiting = true
        let dropped = waiting.map { NotStarted(errand: $0, reason: .updateWaiting) }
        waiting = []
        return dropped
    }

    /// The update did not happen after all: errands may start again. Without
    /// this, a failed install would stop every errand until the app quits.
    mutating func updateWithdrawn() { updateWaiting = false }

    private mutating func dropExpired(now: ContinuousClock.Instant) -> [NotStarted] {
        let isExpired = { (errand: Errand) in now - errand.queuedAt >= Self.maxWait }
        let expired = waiting.filter(isExpired).map { NotStarted(errand: $0, reason: .expired) }
        waiting.removeAll(where: isExpired)
        return expired
    }
}
