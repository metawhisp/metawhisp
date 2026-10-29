import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class LiveHintsRetirementTests: XCTestCase {
    private enum Retirement: CaseIterable, Equatable {
        case stop, halt, generation, cancellation
    }

    private enum Hop: Equatable { case micAppend, systemAppend, systemReset, captureRead }

    @MainActor
    private final class TrackerProbe {
        var suspendedHop: Hop?
        var entered: XCTestExpectation?
        var captureCompleted: XCTestExpectation?
        private(set) var captureSampleCounts: [Int] = []
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var micAppends = 0
        private(set) var systemAppends = 0
        private(set) var resets = 0

        var operations: LiveHintsTrackerOperations {
            LiveHintsTrackerOperations(
                append: { [self] speaker, samples, tracker in
                    await append(speaker, samples: samples, tracker: tracker)
                },
                reset: { [self] tracker in await reset(tracker) },
                readSamples: { [self] read in await readSamples(read) })
        }

        private func suspend(at hop: Hop) async {
            guard suspendedHop == hop else { return }
            suspendedHop = nil
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered?.fulfill()
            }
        }

        private func append(_ speaker: UtteranceTracker.Speaker, samples: [Float],
                            tracker: UtteranceTracker) async {
            if speaker == .me { micAppends += 1 } else { systemAppends += 1 }
            await suspend(at: speaker == .me ? .micAppend : .systemAppend)
            await tracker.append(samples)
        }

        private func reset(_ tracker: UtteranceTracker) async {
            resets += 1
            await suspend(at: .systemReset)
            await tracker.reset()
        }

        private func readSamples(_ read: @MainActor @Sendable () -> [Float]) async -> [Float] {
            await suspend(at: .captureRead)
            let samples = read()
            captureSampleCounts.append(samples.count)
            captureCompleted?.fulfill()
            return samples
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class Harness {
        let fakes = FakeLiveHintsEnvironment()
        let generation = LiveValueBox(1)
        let probe = TrackerProbe()
        let session: LiveHintsMeeting

        init() {
            var environment = fakes.environment()
            let generation = self.generation
            environment.generation = { generation.value }
            session = LiveHintsMeeting(environment: environment,
                                       trackerOperations: probe.operations,
                                       startsPolling: false)
        }

        func seedSystem() async {
            await session.start()
            fakes.system.append(LiveCallFixture.audio([.silence(3)]))
            await session.poll()
        }

        func retire(_ retirement: Retirement, poll: Task<Void, Never>) {
            switch retirement {
            case .stop: session.stop()
            case .halt: session.haltForBalance()
            case .generation: generation.value += 1
            case .cancellation: poll.cancel()
            }
        }
    }

    func testStopOrHaltDuringMicAppendSkipsSystemPeekAndRebase() async {
        for retirement in [Retirement.stop, .halt] {
            for replaceBuffer in [false, true] {
                await assertMicAppendRetirement(retirement, replaceBuffer: replaceBuffer)
            }
        }
    }

    func testGenerationReplacementDuringMicAppendSkipsSystemPeekAndRebase() async {
        await assertMicAppendRetirement(.generation, replaceBuffer: true)
    }

    func testCancellationDuringMicAppendSkipsSystemPeekAndRebase() async {
        await assertMicAppendRetirement(.cancellation, replaceBuffer: true)
    }

    private func assertMicAppendRetirement(_ retirement: Retirement, replaceBuffer: Bool,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        let harness = Harness()
        await harness.seedSystem()
        defer { harness.session.stop() }
        harness.fakes.mic.append(LiveCallFixture.audio([.speech(0.1)]))
        harness.fakes.system.append(LiveCallFixture.audio([.speech(0.5), .silence(2)]))
        harness.probe.suspendedHop = .micAppend
        harness.probe.entered = expectation(description: "mic append suspended")
        let poll = Task { await harness.session.poll() }
        await fulfillment(of: [harness.probe.entered!], timeout: 2)

        harness.retire(retirement, poll: poll)
        if replaceBuffer {
            if retirement == .stop || retirement == .halt { harness.generation.value += 1 }
            harness.fakes.system.replaceBuffer()
            harness.fakes.system.append(LiveCallFixture.audio([.speech(0.5), .silence(2)]))
        }
        let peeks = harness.fakes.system.reads.count
        let appends = harness.probe.systemAppends
        var publications = 0
        let observer = harness.fakes.state.objectWillChange.sink { publications += 1 }
        harness.probe.release()
        await poll.value

        XCTAssertEqual(harness.fakes.system.reads.count, peeks, "retired session read capture", file: file, line: line)
        XCTAssertEqual(harness.probe.resets, 0, "retired session rebased capture", file: file, line: line)
        XCTAssertEqual(harness.probe.systemAppends, appends, "retired session appended system samples", file: file, line: line)
        XCTAssertEqual(harness.fakes.engine.callCount, 0, file: file, line: line)
        XCTAssertEqual(harness.fakes.pro.requests.count, 0, file: file, line: line)
        XCTAssertTrue(harness.fakes.state.transcriptTail.isEmpty, file: file, line: line)
        XCTAssertEqual(publications, 0, "retired poll published UI state", file: file, line: line)
        withExtendedLifetime(observer) {}
    }

    func testRetirementDuringSystemRebaseDoesNotReadOrAdvanceReplacementBuffer() async {
        for retirement in Retirement.allCases {
            let harness = Harness()
            await harness.seedSystem()
            harness.fakes.system.replaceBuffer()
            harness.fakes.system.append(LiveCallFixture.audio([.speech(0.5), .silence(2)]))
            harness.probe.suspendedHop = .systemReset
            harness.probe.entered = expectation(description: "system reset suspended")
            let poll = Task { await harness.session.poll() }
            await fulfillment(of: [harness.probe.entered!], timeout: 2)
            harness.retire(retirement, poll: poll)
            let peeks = harness.fakes.system.reads.count
            let appends = harness.probe.systemAppends
            var publications = 0
            let observer = harness.fakes.state.objectWillChange.sink { publications += 1 }
            harness.probe.release()
            await poll.value

            XCTAssertEqual(harness.fakes.system.reads.count, peeks)
            XCTAssertEqual(harness.probe.systemAppends, appends)
            XCTAssertEqual(harness.probe.resets, 1)
            XCTAssertEqual(harness.fakes.engine.callCount, 0)
            XCTAssertEqual(harness.fakes.pro.requests.count, 0)
            XCTAssertEqual(publications, 0)
            observer.cancel()
            XCTAssertEqual(harness.session.finalize().systemOffset, 48_000,
                           "retired rebase moved the read cursor after its await")
        }
    }

    func testQueuedTrackerCaptureReadRechecksSessionOwnershipBeforePeek() async {
        for retirement in [Retirement.stop, .halt, .generation] {
            let harness = Harness()
            let engineDispatch = expectation(description: "retired source never dispatches an engine request")
            engineDispatch.isInverted = true
            harness.fakes.engine.setResponder { _ in
                engineDispatch.fulfill()
                return FakeLiveEngine.result("A response.")
            }
            await harness.session.start()
            harness.probe.suspendedHop = .captureRead
            harness.probe.entered = expectation(description: "candidate capture read queued")
            harness.probe.captureCompleted = expectation(description: "candidate capture read completed")
            // A real system tracker starts its candidate at the pause, then uses
            // the session's actual StreamAudioSource to fetch the candidate audio.
            harness.fakes.system.append(LiveCallFixture.audio([.speech(0.5), .silence(0.65)]))
            let poll = Task { await harness.session.poll() }
            await poll.value
            await fulfillment(of: [harness.probe.entered!], timeout: 2)
            harness.retire(retirement, poll: poll)
            if retirement == .generation {
                harness.fakes.state.arm(generation: harness.generation.value)
            }
            harness.fakes.system.replaceBuffer(alreadyHolding: 4_000)
            let peeks = harness.fakes.system.reads.count
            var publications = 0
            let observer = harness.fakes.state.objectWillChange.sink { publications += 1 }
            harness.probe.release()
            await fulfillment(of: [harness.probe.captureCompleted!], timeout: 2)
            await fulfillment(of: [engineDispatch], timeout: 0.1)

            XCTAssertEqual(harness.fakes.system.reads.count, peeks,
                           "A queued tracker source read retired capture after its actor hop")
            XCTAssertEqual(harness.probe.captureSampleCounts, [0])
            XCTAssertEqual(harness.fakes.engine.callCount, 0)
            XCTAssertEqual(harness.fakes.pro.requests.count, 0)
            XCTAssertEqual(publications, 0)
            if retirement == .generation {
                XCTAssertTrue(harness.fakes.state.isVisible, "Retiring an old source must not disarm its replacement")
                XCTAssertEqual(harness.fakes.state.recordingGeneration, harness.generation.value)
            }
            observer.cancel()
            harness.session.stop()
        }
    }

    func testCancellationDuringSystemAppendDoesNotPublishSpeaker() async {
        let harness = Harness()
        await harness.session.start()
        defer { harness.session.stop() }
        harness.fakes.system.append(LiveCallFixture.audio([.speech(0.1)]))
        harness.probe.suspendedHop = .systemAppend
        harness.probe.entered = expectation(description: "system append suspended")
        let poll = Task { await harness.session.poll() }
        await fulfillment(of: [harness.probe.entered!], timeout: 2)
        poll.cancel()
        var publications = 0
        let observer = harness.fakes.state.objectWillChange.sink { publications += 1 }
        harness.probe.release()
        await poll.value

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(harness.fakes.engine.callCount, 0)
        XCTAssertEqual(harness.fakes.pro.requests.count, 0)
        withExtendedLifetime(observer) {}
    }
}
