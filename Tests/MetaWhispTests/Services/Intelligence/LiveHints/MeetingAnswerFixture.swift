import Foundation
import XCTest
@testable import MetaWhisp

/// The fakes the answer service's tests run on: a clock the test moves, a
/// gate the test opens, a route the test owns, and the service itself with
/// all of them around it.
@MainActor
final class FakeClock {
    /// The time now.
    private(set) var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }

    /// Moves the clock.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// A gate the test opens: a request that reaches it waits until then.
@MainActor
final class FakeLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Opens the gate and lets everything through.
    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Closes the gate again, so the next request waits.
    func close() {
        isOpen = false
    }

    /// Waits until the gate is open.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// A box for what a test saw, so a completion closure can record it without
/// touching a captured variable.
final class SeenBox<T>: @unchecked Sendable {
    /// What was seen.
    var values: [T] = []

    /// Records one thing.
    func append(_ value: T) {
        values.append(value)
    }
}

/// A route to the model the test owns.
@MainActor
final class FakeRoute: MeetingAnswerRoute {
    /// What the route was asked.
    struct Request: Equatable {
        let system: String
        let user: String
        let deadlineMs: Int
        /// True when the request's task was cancelled while it waited.
        var wasCancelled: Bool = false
    }

    let routeName: String
    var isAvailable: Bool
    private(set) var requests: [Request] = []
    /// The replies, one per request. The last one repeats.
    var replies: [MeetingAnswerReply] = []
    /// The reply of a request, by the number of the request.
    ///
    /// A test that holds two requests open pins the answer of each of them
    /// here: the order in which the requests come back does not decide what
    /// they answered.
    var repliesByIndex: [Int: MeetingAnswerReply] = [:]
    /// Called before the reply, so a test can hold the request open.
    var gate: (() async -> Void)?

    init(routeName: String, isAvailable: Bool = true) {
        self.routeName = routeName
        self.isAvailable = isAvailable
    }

    func answer(system: String,
                user: String,
                deadlineMs: Int,
                stopToken: LiveHintsStopToken) async throws -> MeetingAnswerReply {
        // The real routes ask the model only while the session runs (§6.15).
        // The check stands right before the call: a request of a meeting that
        // is over never reaches the backend.
        guard !stopToken.isCancelled else { throw CancellationError() }
        requests.append(Request(system: system, user: user, deadlineMs: deadlineMs))
        let index = requests.count - 1
        if let gate { await gate() }
        // The request's own handle may have called it off while it waited.
        requests[index].wasCancelled = Task.isCancelled
        if let reply = repliesByIndex[index] { return reply }
        guard !replies.isEmpty else {
            return MeetingAnswerReply(status: 200, retryAfter: nil, text: "**The answer.**")
        }
        return replies.count == 1 ? replies[0] : replies.removeFirst()
    }
}

/// The answer service with the fakes around it.
@MainActor
struct MeetingAnswerHarness {
    let service: MeetingAnswerService
    /// The card the service publishes into. Every harness gets its own, so
    /// one test never sees the answers of another.
    let state: MeetingCoachState
    let transcript: LiveMeetingTranscript
    let routes: MeetingAnswerRoutes
    let clock: FakeClock
    let pro: FakeRoute
    let ownKey: FakeRoute
    let local: FakeRoute
    let latch: FakeLatch

    /// Waits until the route has been asked `count` times.
    func waitForRequests(_ count: Int, timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pro.requests.count + ownKey.requests.count + local.requests.count >= count { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Waits until no request is running any more.
    func waitUntilIdle(timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !service.isThinking { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Waits until the condition holds.
    func waitUntil(_ condition: () -> Bool, timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Waits a little, so a call that must not happen has had its chance.
    func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The number of requests that were made.
    var requestCount: Int { pro.requests.count + ownKey.requests.count + local.requests.count }
}

/// Builds the service with the fakes around it.
@MainActor
func makeAnswerHarness(
    isAutoOn: @escaping @MainActor () -> Bool = { true },
    meSpeechSeconds: @escaping @Sendable (Int) async -> Double = { _ in 0 },
    pendingThemText: @escaping @Sendable () async -> LivePendingText? = { nil },
    relevantMemories: @escaping @MainActor @Sendable (String) -> String = { _ in "" },
    pinnedLanguage: @escaping @MainActor () -> String? = { nil },
    generation: @escaping @MainActor () -> Int = { 0 },
    transcript: LiveMeetingTranscript = LiveMeetingTranscript(),
    stopToken: LiveHintsStopToken = LiveHintsStopToken(),
    screenEnabled: @escaping @MainActor () -> Bool = { false },
    captureScreen: @escaping @MainActor () async -> String? = { nil }
) -> MeetingAnswerHarness {
    let clock = FakeClock()
    let pro = FakeRoute(routeName: "pro")
    let ownKey = FakeRoute(routeName: "own-key", isAvailable: false)
    let local = FakeRoute(routeName: "local", isAvailable: false)
    let latch = FakeLatch()
    // The card the answers are published into — its own, on the same clock
    // the service runs on.
    let state = MeetingCoachState(clock: { clock.now })

    let routes = MeetingAnswerRoutes()
    routes.pro = pro
    routes.ownKey = ownKey
    routes.local = local

    let service = MeetingAnswerService(transcript: transcript,
                                       routes: routes,
                                       clock: { clock.now },
                                       isAutoOn: isAutoOn,
                                       pendingThemText: pendingThemText,
                                       meSpeechSeconds: meSpeechSeconds,
                                       relevantMemories: relevantMemories,
                                       pinnedLanguage: pinnedLanguage,
                                       generation: generation,
                                       state: state,
                                       stopToken: stopToken,
                                       screenEnabled: screenEnabled,
                                       captureScreen: captureScreen)

    return MeetingAnswerHarness(service: service,
                                state: state,
                                transcript: transcript,
                                routes: routes,
                                clock: clock,
                                pro: pro,
                                ownKey: ownKey,
                                local: local,
                                latch: latch)
}

/// A gate for one request: the request waits until the gate is opened.
///
/// The gate does not notice a cancellation — a request that was cancelled
/// still comes back, and the test has to drop it.
final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many callers are waiting at the gate.
    var waiterCount: Int { lock.withLock { waiters.count } }

    /// Waits until the gate is open.
    func wait() async {
        if lock.withLock({ isOpen }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isAlreadyOpen: Bool = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if isAlreadyOpen { continuation.resume() }
        }
    }

    /// Opens the gate and lets everything through.
    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let waiting = self.waiters
            self.waiters = []
            return waiting
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// The gates of the requests, in the order the requests came in: the first
/// request waits for the first gate, the second for the second.
final class GateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [RequestGate] = []

    /// Adds a gate to the queue.
    func add(_ gate: RequestGate) {
        lock.withLock { gates.append(gate) }
    }

    /// The gate of the next request — nil when the queue is empty.
    func next() -> RequestGate? {
        lock.withLock { gates.isEmpty ? nil : gates.removeFirst() }
    }
}

/// Adds a line of the other side to the transcript.
@MainActor
func appendThemLine(_ transcript: LiveMeetingTranscript,
                     text: String,
                     from startSample: Int,
                     to endSample: Int? = nil,
                     isContinuation: Bool = false) async {
    await transcript.appendThem(text: text,
                                startSample: startSample,
                                endSample: endSample ?? startSample + 16_000,
                                rms: 0.05,
                                isContinuation: isContinuation)
}

/// The line of the other side the service is told about.
@MainActor
func themLine(text: String, from startSample: Int, to endSample: Int? = nil) -> LiveMeetingTranscript.Line {
    LiveMeetingTranscript.Line(speaker: .them,
                               text: text,
                               startSample: startSample,
                               endSample: endSample ?? startSample + 16_000)
}
