import Foundation

/// Where a summary run goes: the local model, or the cloud (Pro or a key).
enum StructuredRoute {
    case local, cloud
}

/// ITER-075 step 1 (1.5) — the conversations waiting for their summary, kept on
/// disk. A run without LLM access waits for access; a failed run is tried again
/// after a pause that grows; a service that cannot take runs gives up no one.
/// Nothing is dropped: the recaps of 2026-09-25 stayed blank because a run
/// without access returned and nothing queued it again.
@MainActor
final class StructuredQueue {
    /// The pauses before the first, second and third retry of a failed run, and
    /// between tries of the cloud while it cannot take runs.
    static let retryPauses: [TimeInterval] = [60, 300, 1800]
    /// A run that fails again after the third retry leaves the queue.
    static let maxFailedRuns = retryPauses.count + 1

    private let store: ExtractionQueueStore
    private let run: (UUID, String?, Bool) async -> StructuredOutcome
    private let route: (Bool) -> StructuredRoute?
    private let isStoreHealthy: () -> Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    /// A fresh conversation's in-memory transcript, for the first of its runs
    /// that runs: its rows may not be readable yet from a new context
    /// (2026-05-01).
    private var knownTranscripts: [UUID: String] = [:]
    /// The conversations that closed in this session. Only they may use the
    /// local model: a pass of older ones through it froze a Mac (2026-05-13).
    private var fresh: Set<UUID> = []
    /// Conversations the close is running right now; a drain leaves them be.
    private var running: Set<UUID> = []
    /// When a conversation whose run failed may run again.
    private var notBefore: [UUID: Date] = [:]
    /// Times in a row a conversation was turned away; its own pause grows
    /// with them.
    private var turnAways: [UUID: Int] = [:]
    /// When the cloud may be tried again after it turned a run away; nil once
    /// it answers.
    private var cloudResumeAt: Date?
    /// Runs in a row the cloud turned away; each makes its rest longer.
    private var cloudRefusals = 0
    /// Set in a drain once the cloud turned a run away, or two cloud runs in a
    /// row failed: the others would fare the same way.
    private var cloudStopped = false
    private var failuresInARow = 0
    private var waitingForAccess = 0
    private var isDraining = false
    private var drainAgain = false
    private var retry: Task<Void, Never>?

    /// - Parameters:
    ///   - directory: override for tests; defaults to the app's support folder.
    ///   - route: where a run would go now, or nil without access for it; its
    ///     flag says whether the run may use the local model.
    ///   - isStoreHealthy: a degraded store reads as empty; nothing runs against it.
    ///   - now: the clock, replaced in tests.
    ///   - sleep: the retry timer's wait, replaced in tests.
    ///   - run: one summary run; its flag says whether it may use the local model.
    init(directory: URL? = nil,
         route: @escaping (Bool) -> StructuredRoute?,
         isStoreHealthy: @escaping () -> Bool = { StoreHealthSignal.shared.isHealthy },
         now: @escaping () -> Date = { Date() },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         run: @escaping (UUID, String?, Bool) async -> StructuredOutcome) {
        store = ExtractionQueueStore(filename: "structured-generation-queue.json", directory: directory,
                                     maxFailedAttempts: Self.maxFailedRuns)
        self.run = run
        self.route = route
        self.isStoreHealthy = isStoreHealthy
        self.now = now
        self.sleep = sleep
    }

    /// Queued conversations, the next to run first.
    var pending: [UUID] { store.pending() }

    /// The retry waiting for a pause to end, if any.
    var scheduledRetry: Task<Void, Never>? { retry }

    /// The counted failed runs of a queued conversation.
    func failedRuns(for id: UUID) -> Int { store.failedAttempts(for: id) }

    /// A conversation that just closed: it goes first, and it may use the local model.
    func enqueueFresh(_ id: UUID, knownTranscript: String?) {
        if let knownTranscript { knownTranscripts[id] = knownTranscript }
        fresh.insert(id)
        store.enqueueFirst(id)
    }

    /// A conversation that just closed: queued first, on disk, then run at once
    /// in its turn — its summary is what the Library and the recap show. The
    /// rest of the queue runs afterwards, on its own.
    func runFresh(_ id: UUID, knownTranscript: String?) async {
        enqueueFresh(id, knownTranscript: knownTranscript)
        running.insert(id)
        let outcome = await runOnce(id, inDrain: false)
        running.remove(id)
        store.record(id, outcome)
        forgetWhatLeft()
        scheduleRetry(stoppedEarly: false)
        Task { await self.drain() }
    }

    /// Older conversations: behind everything queued, on the cloud only. False
    /// when the queue could not be written to disk.
    @discardableResult
    func enqueue(_ ids: [UUID]) -> Bool {
        store.enqueue(contentsOf: ids)
    }

    /// Runs each queued conversation once. A result, or nothing to change,
    /// leaves the queue. No access waits, uncounted, with no run at all. A
    /// failed run is counted, waits its pause, and leaves after its fourth
    /// failure; two in a row stop the cloud for this drain. A run the cloud
    /// turned away (no network, the key, the service unavailable) is not
    /// counted: the cloud stops for this drain and rests a pause that grows.
    /// A drain asked for while one runs makes that one go round again.
    func drain() async {
        guard !isDraining else {
            drainAgain = true
            return
        }
        // A degraded store reads as empty: every conversation would come back
        // "not found" and leave the queue for good (as in MemoryExtractor,
        // ITER-049 A2). The queue waits for the next launch.
        guard isStoreHealthy() else {
            NSLog("[StructuredQueue] store degraded — %d queued conversations wait for the next launch", store.pending().count)
            return
        }
        // Nothing can run without cloud access but a conversation from this
        // session: one check, not one per conversation.
        guard route(false) != nil || store.pending().contains(where: fresh.contains) else {
            retry?.cancel()
            retry = nil
            NSLog("[StructuredQueue] %d queued conversations wait for LLM access", store.pending().count)
            return
        }
        isDraining = true
        defer { isDraining = false }
        cloudStopped = false
        failuresInARow = 0
        repeat {
            drainAgain = false
            waitingForAccess = 0
            await store.drain { id in await self.runOnce(id, inDrain: true) }
        } while drainAgain
        forgetWhatLeft()
        scheduleRetry(stoppedEarly: cloudStopped)
        NSLog("[StructuredQueue] drain done — %d queued, %d waiting for LLM access%@", store.pending().count,
              waitingForAccess, cloudStopped ? ", the cloud stopped early" : "")
    }

    static func extractionOutcome(_ outcome: StructuredOutcome) -> ExtractionOutcome {
        switch outcome {
        case .written, .unchanged: return .completed
        case .notNow: return .retryLater
        case .failed: return .failedAttempt
        }
    }

    private func runOnce(_ id: UUID, inDrain: Bool) async -> ExtractionOutcome {
        if inDrain && running.contains(id) { return .retryLater }
        if let due = notBefore[id] {
            guard due <= now() else { return .retryLater }
            // Due now: its date is spent, and must never re-arm the timer.
            notBefore[id] = nil
        }
        let mayUseLocal = fresh.contains(id)
        // Without access for its path it waits for access: no run, no log line.
        guard let path = route(mayUseLocal) else {
            waitingForAccess += 1
            return .retryLater
        }
        if inDrain, path == .cloud {
            if cloudStopped { return .retryLater }
            if let resume = cloudResumeAt, resume > now() { return .retryLater }
        }
        let result = await run(id, knownTranscripts[id], mayUseLocal)
        let outcome = Self.extractionOutcome(result)
        if path == .cloud && (result == .written || result == .failed) {
            // The cloud took the run. (A short transcript is written with no
            // call at all; at worst that tries the cloud again sooner.)
            cloudRefusals = 0
            cloudResumeAt = nil
        }
        switch outcome {
        case .retryLater:
            if path == .cloud { cloudTurnedAway(id, inDrain: inDrain) }
            return outcome   // the fresh transcript is kept
        case .failedAttempt:
            turnAways[id] = nil
            if inDrain, path == .cloud {
                failuresInARow += 1
                if failuresInARow >= 2 { cloudStopped = true }
            }
            // The store counts this failure when it gets the outcome back.
            let failures = store.failedAttempts(for: id) + 1
            if failures < Self.maxFailedRuns {
                notBefore[id] = now().addingTimeInterval(Self.retryPauses[failures - 1])
            }
        case .completed:
            turnAways[id] = nil
            if inDrain, path == .cloud { failuresInARow = 0 }
        }
        // The in-memory transcript has served the run that ran.
        knownTranscripts[id] = nil
        return outcome
    }

    /// Access was there and the cloud turned the run away: no network, the key,
    /// or the service unavailable. That is no failure of this conversation, so
    /// nothing is counted. The cloud stops for this drain and rests a pause that
    /// grows. The conversation itself waits twice that pause at its own count:
    /// when the rest ends the ones behind it go first, so none of them waits on
    /// it, and one turned away again and again is tried less and less often.
    private func cloudTurnedAway(_ id: UUID, inDrain: Bool) {
        if inDrain { cloudStopped = true }
        cloudRefusals += 1
        let rest = Self.retryPauses[min(cloudRefusals, Self.retryPauses.count) - 1]
        cloudResumeAt = now().addingTimeInterval(rest)
        let times = (turnAways[id] ?? 0) + 1
        turnAways[id] = times
        notBefore[id] = now().addingTimeInterval(2 * Self.retryPauses[min(times, Self.retryPauses.count) - 1])
    }

    /// What left the queue needs nothing kept for it.
    private func forgetWhatLeft() {
        let queued = Set(store.pending())
        fresh.formIntersection(queued)
        notBefore = notBefore.filter { queued.contains($0.key) }
        turnAways = turnAways.filter { queued.contains($0.key) }
        knownTranscripts = knownTranscripts.filter { queued.contains($0.key) }
    }

    /// One timer, for the earliest pause still to end; the drain it starts runs
    /// what is due by then. A drain that stopped early leaves conversations
    /// untried: they get a try after the first pause even when nothing else
    /// waits on a date.
    private func scheduleRetry(stoppedEarly: Bool) {
        retry?.cancel()
        retry = nil
        guard !store.pending().isEmpty else { return }
        let current = now()
        var dates = notBefore.values.filter { $0 > current }
        // The cloud's rest counts only for a conversation not waiting on a
        // later date of its own.
        if let resume = cloudResumeAt, resume > current,
           store.pending().contains(where: { (notBefore[$0] ?? current) <= current }) {
            dates.append(resume)
        }
        if stoppedEarly, dates.isEmpty { dates.append(current.addingTimeInterval(Self.retryPauses[0])) }
        guard let due = dates.min() else { return }
        let wait = due.timeIntervalSince(current)
        retry = Task { [weak self] in
            do { try await self?.sleep(wait) } catch { return }
            await self?.drain()
        }
    }
}
