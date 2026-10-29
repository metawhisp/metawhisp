import Foundation

/// Which side of the call a transcription belongs to.
///
/// The two sides run independently: at most one engine call in flight per
/// side, so a slow `.me` batch never holds up a question from the other side.
enum LiveStream: String, Equatable, Sendable {
    /// The user.
    case me
    /// The other side.
    case them
}

/// What a live call can end with that is not the text.
enum LiveTranscriptionError: Error, Equatable {
    /// The meeting the call belonged to is over: the recording generation
    /// changed while the call was on its way, so its result is dropped.
    case recordingChanged
    /// The call waited longer than it may before it could start, so the work
    /// was dropped.
    case waitedTooLong
    /// The call did not come back in time.
    case timedOut
}

/// The live transcriber: the one place a live call reaches the engine.
///
/// Every live call — a `.them` candidate, a `.them` final, a `.me` batch —
/// goes through here, so the rules of §3.2 live in one place:
/// - at most one call in flight per stream, and a stream's next call waits
///   for the previous one to truly return, even after a timeout;
/// - the engine is asked with `countUsage: false`, always: a live pass is
///   part of the meeting, which is booked once when it ends;
/// - the call has a deadline of 8 s; a timeout drops the text of that clip,
///   but the engine call goes on;
/// - a result for another recording generation is dropped;
/// - the monthly meeting minutes running out stops the live hints.
actor LiveEngineTranscriber: LiveTranscriber {

    // MARK: - The rules

    /// How long a call waits for the engine.
    static let deadline: Duration = .seconds(8)
    /// How long a call may wait before it can start.
    static let maximumQueueAge: Duration = .seconds(60)
    /// The worker's message when the monthly meeting minutes are used up.
    static let balanceSpentMessage = "Monthly limit reached"
    /// How long the adapter waits between two attempts at the engine.
    static let engineRetryStep: Duration = .seconds(1)

    // MARK: - The providers

    /// Where the engine comes from. The app asks the coordinator for an engine
    /// that is ready; the tests hand over a fake.
    typealias EngineProvider = @Sendable () async -> (any TranscriptionEngine)?
    /// The language handed to the engine.
    typealias LanguageProvider = @Sendable () async -> String?
    /// The prompt words handed to the engine, for a language.
    typealias PromptWordsProvider = @Sendable (String?) async -> [String]
    /// The recording a call belongs to. A result for another one is dropped.
    typealias GenerationProvider = @Sendable () async -> Int
    /// The hook the tests use to hold the task that asks the engine.
    ///
    /// The task waits here before it asks the engine, so a test can stop the
    /// session while the task is on its way — the window between the check
    /// and the call (§6.15).
    typealias BeforeDispatch = @Sendable () async -> Void

    // MARK: - The state

    private let engineProvider: EngineProvider
    private let languageProvider: LanguageProvider
    private let promptWordsProvider: PromptWordsProvider
    private let generationProvider: GenerationProvider
    private let onBalanceSpent: (@Sendable () -> Void)?
    private let beforeDispatch: BeforeDispatch?
    private let deadline: Duration
    private let maximumQueueAge: Duration

    /// The cancellation of the session this transcriber belongs to.
    ///
    /// The engine is asked only when the session is still running: a call
    /// that was on its way when the meeting ended never reaches the engine
    /// (§6.15).
    nonisolated let stopToken: LiveHintsStopToken

    /// The engine call in flight on each stream.
    ///
    /// The stream's slot is taken before the first await of a call and given
    /// back only when the engine call truly returns: a second caller cannot
    /// slip in while the first one waits for the engine or for the language
    /// (§3.2).
    private var isBusy: [LiveStream: Bool] = [:]
    /// The calls waiting for their stream, in the order they arrived.
    private var waiters: [LiveStream: [Waiter]] = [:]

    /// How many calls wait for their stream right now.
    ///
    /// The calls of the other side of the meeting are counted with it: every
    /// call waits for its own stream.
    var waitingCallCount: Int {
        waiters.values.reduce(0) { $0 + $1.count }
    }

    /// True when the monthly meeting minutes are used up: the live hints stop
    /// for this meeting.
    private(set) var isBalanceSpent = false
    /// The error the engine answered with when the balance ran out. Every
    /// call after that fails with it, without touching the engine.
    private var balanceSpentError: Error?

    // MARK: - Setting it up

    init(engineProvider: @escaping EngineProvider,
         languageProvider: @escaping LanguageProvider,
         promptWordsProvider: @escaping PromptWordsProvider,
         generationProvider: @escaping GenerationProvider,
         onBalanceSpent: (@Sendable () -> Void)? = nil,
         deadline: Duration = LiveEngineTranscriber.deadline,
         maximumQueueAge: Duration = LiveEngineTranscriber.maximumQueueAge,
         stopToken: LiveHintsStopToken = LiveHintsStopToken(),
         beforeDispatch: BeforeDispatch? = nil) {
        self.engineProvider = engineProvider
        self.languageProvider = languageProvider
        self.promptWordsProvider = promptWordsProvider
        self.generationProvider = generationProvider
        self.onBalanceSpent = onBalanceSpent
        self.deadline = deadline
        self.maximumQueueAge = maximumQueueAge
        self.stopToken = stopToken
        self.beforeDispatch = beforeDispatch
    }

    // MARK: - One live call

    /// One live call on a stream.
    ///
    /// The outcome is typed: the text, a timeout, a cancellation, or the
    /// error the engine threw. A timeout drops the text of that clip — the
    /// engine call goes on, and the stream waits for it.
    func call(samples: [Float], stream: LiveStream) async -> LiveCall.Outcome<TranscriptionResult> {
        // The balance is looked at first: once the minutes are gone, every
        // call fails at once — nothing waits, and the engine is never asked.
        if let spent = balanceSpentError {
            return .failed(spent)
        }

        let queuedAt = ContinuousClock.now
        let limit = queuedAt + maximumQueueAge

        // The meeting this call belongs to is captured now, before the call
        // waits for its stream. A call that was made in the meeting before
        // must never reach the engine of the next one (§3.2).
        let generation = await generationProvider()

        // The stream's slot is taken before the first await: two calls can
        // never be in the engine at the same time, whatever they wait for.
        guard await reserve(stream: stream, until: limit) else {
            NSLog("[LiveHints] live call dropped — the stream was busy for more than %.0fs",
                  Double(maximumQueueAge.components.seconds))
            return .failed(LiveTranscriptionError.waitedTooLong)
        }

        // The slot goes back when the engine call truly returns — or right
        // away when the call never reached the engine.
        var isSlotHandedOver = false
        defer {
            if !isSlotHandedOver { release(stream: stream) }
        }

        // The engine. It may take a while to be ready: the model is still
        // downloading, say. Work that waited too long is dropped.
        guard let engine = await waitForEngine(queuedAt: queuedAt) else {
            NSLog("[LiveHints] live call dropped — no engine after %.0fs",
                  Double(maximumQueueAge.components.seconds))
            return .failed(LiveTranscriptionError.waitedTooLong)
        }

        // The call itself.
        let language = await languageProvider()
        let promptWords = await promptWordsProvider(language)

        // The meeting may have ended while the call was on its way: the call
        // belongs to a meeting that is over, and it never reaches the engine
        // (§3.2).
        guard await generationProvider() == generation else {
            return .failed(LiveTranscriptionError.recordingChanged)
        }

        // The session may have been stopped while the call was on its way:
        // the engine is not asked at all (§6.15).
        guard !stopToken.isCancelled else {
            return .cancelled
        }

        // The token of this call, checked inside the task below: the check
        // above is only the quick way out, and a cancellation is
        // cooperative — the body of the task runs even when it was cancelled.
        let token = stopToken
        let task = Task { () -> EngineAnswer in
            // The test waits here: the session may be stopped while the task
            // is on its way, and the check that stands right before the
            // engine is asked is the one inside this task.
            if let beforeDispatch { await beforeDispatch() }
            // The session may have been stopped while the task was on its
            // way: the engine is not asked at all (§6.15).
            guard !token.isCancelled else { return .cancelled }
            do {
                // The live path never bills: the meeting is booked once when
                // it ends. The four-argument call is the only one that says
                // so — the convenience overloads bill.
                let result = try await engine.transcribe(audioSamples: samples,
                                                         language: language,
                                                         promptWords: promptWords,
                                                         countUsage: false)
                return .text(result)
            } catch {
                return .failed(error)
            }
        }
        // The engine call belongs to the session: it is cancelled with it.
        let stopToken = self.stopToken
        let handle = stopToken.retain { task.cancel() }
        // The stream is free again when the engine call truly returns — not
        // when the deadline passed.
        Task { [weak self] in
            _ = await task.value
            stopToken.release(handle)
            await self?.release(stream: stream)
        }
        isSlotHandedOver = true

        let outcome = await LiveCall.run(within: deadline) {
            switch await task.value {
            case .text(let result): return result
            case .failed(let error): throw error
            case .cancelled: throw CancellationError()
            }
        }

        switch outcome {
        case .text(let result):
            // The meeting may have ended while the engine was working.
            guard await generationProvider() == generation else {
                return .failed(LiveTranscriptionError.recordingChanged)
            }
            return .text(result)
        case .failed(let error):
            if Self.isBalanceSpent(error) {
                markBalanceSpent(error)
            }
            return .failed(error)
        case .timeout:
            return .timeout
        case .cancelled:
            return .cancelled
        }
    }

    // MARK: - The slot of a stream

    /// Takes the stream's slot, waiting for the call that holds it.
    ///
    /// The reservation happens before the wait, so the calls are served in the
    /// order they arrived and two of them never hold the slot at once. A call
    /// that waited longer than the work may live is dropped.
    private func reserve(stream: LiveStream, until limit: ContinuousClock.Instant) async -> Bool {
        if isBusy[stream] != true {
            isBusy[stream] = true
            return true
        }
        let waiter = Waiter()
        waiters[stream, default: []].append(waiter)
        // The wait is bounded: work that is too old is dropped.
        Task { [weak self] in
            try? await Task.sleep(until: limit)
            await self?.giveUp(waiter)
        }
        return await withCheckedContinuation { continuation in
            waiter.setContinuation(continuation)
        }
    }

    /// Frees the stream: the call that waits for it takes the slot over, or
    /// the stream is free again.
    private func release(stream: LiveStream) {
        if var waiting = waiters[stream], !waiting.isEmpty {
            let next = waiting.removeFirst()
            waiters[stream] = waiting
            // The slot stays with the call that takes it.
            next.resolve(granted: true)
        } else {
            isBusy[stream] = false
        }
    }

    /// The waiter waited too long: it gives the slot up.
    private func giveUp(_ waiter: Waiter) {
        for (stream, waiting) in waiters {
            guard let index = waiting.firstIndex(where: { $0 === waiter }) else { continue }
            var waiting = waiting
            waiting.remove(at: index)
            waiters[stream] = waiting
            waiter.resolve(granted: false)
            return
        }
        // It was given the slot in the meantime: there is nothing to give up.
    }

    /// A call waiting for its stream.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var isResolved = false

        /// Remembers the continuation of the waiter. A waiter that was given
        /// up before it could wait goes away empty-handed.
        func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
            let isAlreadyResolved: Bool = lock.withLock {
                guard !isResolved else { return true }
                self.continuation = continuation
                return false
            }
            if isAlreadyResolved { continuation.resume(returning: false) }
        }

        /// Gives the waiter its answer: true when it got the stream. The
        /// first writer wins — the waiter is resumed exactly once.
        func resolve(granted: Bool) {
            let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
                guard !isResolved else { return nil }
                isResolved = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            pending?.resume(returning: granted)
        }
    }

    /// The tracker's call: the other side's utterance, as text.
    ///
    /// The live path never bills, so the flag the protocol carries is pinned
    /// at false whatever the caller asked for.
    func transcribe(samples: [Float], range: LiveSampleRange, countUsage: Bool) async throws -> String {
        if countUsage {
            NSLog("[LiveHints] a live call asked to bill — the live path never bills")
        }
        switch await call(samples: samples, stream: .them) {
        case .text(let result):
            return result.text
        case .timeout:
            throw LiveTranscriptionError.timedOut
        case .cancelled:
            throw CancellationError()
        case .failed(let error):
            throw error
        }
    }

    // MARK: - The engine

    /// The engine, waiting for it while the work is young enough.
    private func waitForEngine(queuedAt: ContinuousClock.Instant) async -> (any TranscriptionEngine)? {
        let clock = ContinuousClock()
        let limit = queuedAt + maximumQueueAge
        while clock.now < limit {
            if let engine = await engineProvider() {
                // The engine came back — but the work may have waited too long
                // while it was on its way.
                guard clock.now < limit else { return nil }
                return engine
            }
            let left = limit - clock.now
            try? await Task.sleep(for: min(Self.engineRetryStep, left))
        }
        return nil
    }

    /// The engine's answer: its result, the error it threw, or the fact
    /// that the session stopped before the engine was asked.
    private enum EngineAnswer {
        case text(TranscriptionResult)
        case failed(Error)
        case cancelled
    }

    // MARK: - The balance

    /// True when the error is the worker's "the monthly minutes are gone".
    static func isBalanceSpent(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)"
        return text.contains(balanceSpentMessage)
    }

    /// The balance ran out: the live hints stop for this meeting.
    private func markBalanceSpent(_ error: Error) {
        guard !isBalanceSpent else { return }
        isBalanceSpent = true
        balanceSpentError = error
        NSLog("[LiveHints] live hints stopped — the monthly meeting minutes are used up")
        onBalanceSpent?()
    }
}
