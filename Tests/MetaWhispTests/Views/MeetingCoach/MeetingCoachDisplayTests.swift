import AppKit
import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class MeetingCoachDisplayTests: XCTestCase {
    func testDifferentTextWithSameBlockAndLineCountsReplacesInstalledAnswer() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let a = f.answer("Alpha"), b = f.answer("Bravo")
        try await f.publishAndWait(a)
        let old = try f.installed()
        let height = try XCTUnwrap(f.controller.answerPanel).frame.height
        var measurements = 0
        f.controller.onTargetMeasured = { _ in measurements += 1 }
        try await f.publishAndWait(b)
        let new = try f.installed()
        XCTAssertEqual(old.displayedBlocks.count, new.displayedBlocks.count)
        // These short headline/bullet pairs each fit on one line at 392 points.
        XCTAssertEqual(f.controller.answerPanel?.frame.height, height)
        XCTAssertNotEqual(old, new)
        XCTAssertNotEqual(old.layout, new.layout, "Layout equality includes text, not just line counts.")
        XCTAssertGreaterThan(measurements, 0)
    }

    func testDifferentHeightReplacesInstalledAnswerAfterMeasurement() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let a = f.answer("Alpha"), b = f.answer("Bravo", extraLines: 8)
        try await f.publishAndWait(a)
        let height = try XCTUnwrap(f.controller.answerPanel).frame.height
        var measured = false
        f.controller.onTargetMeasured = { _ in
            measured = true
            XCTAssertEqual(try? f.installed().displayedBlocks, a.blocks)
        }
        try await f.publishAndWait(b)
        XCTAssertTrue(measured)
        XCTAssertGreaterThan(try XCTUnwrap(f.controller.answerPanel).frame.height, height)
    }

    func testIdenticalLayoutNewIdentityUsesContentCommitAndInstallsNewRootSnapshot() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let a = f.answer("Alpha"), b = f.answer("Alpha")
        try await f.publishAndWait(a)
        let old = try f.installed()
        let operations = f.controller.geometryOperationCount
        var measurements = 0
        f.controller.onTargetMeasured = { _ in measurements += 1 }
        try await f.publishAndWait(b)
        XCTAssertEqual(try f.installed().layout, old.layout)
        XCTAssertNotEqual(try f.installed(), old)
        XCTAssertEqual(measurements, 0)
        XCTAssertEqual(f.controller.geometryOperationCount, operations)
    }

    func testReplacementWhileHoveringInstallsAnswerAndKeepsExpansion() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        try await f.publishAndWait(f.answer("Alpha"))
        f.controller.pointerEntered(.answer)
        try await f.waitUntil { try f.installed().isExpanded }
        try await f.publishAndWait(f.answer("Bravo"))
        XCTAssertTrue(try f.installed().isExpanded)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(try f.installed().isExpanded)
    }

    func testReplacementWhileAskIsOpenInstallsAnswerWithoutLosingEditor() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        try await f.publishAndWait(f.answer("Alpha"))
        f.state.openAsk()
        try await f.waitUntil { try f.installed().isAskOpen && f.state.isQuestionEditing }
        let field = try XCTUnwrap(questionField(in: try XCTUnwrap(f.controller.answerScrollView?.documentView)))
        f.state.updateQuestionText("Keep this unsent question")
        let b = f.answer("Bravo", extraLines: 3)
        try await f.publishAndWait(b)
        XCTAssertTrue(try f.installed().isAskOpen)
        XCTAssertTrue(f.state.isQuestionEditing)
        XCTAssertEqual(f.state.questionText, "Keep this unsent question")
        XCTAssertTrue(questionField(in: try XCTUnwrap(f.controller.answerScrollView?.documentView)) === field)
    }

    func testHiddenPanelInstallsNewestAnswerAndShowsItOnReturn() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        try await f.publishAndWait(f.answer("Alpha"))
        f.state.hidePanel()
        try await f.waitUntil { try f.installed().panelHidden && !f.controller.isAnswerPresented }
        let b = f.answer("Bravo", extraLines: 4)
        f.state.publish(b)
        try await f.waitUntil { try f.installed().requestID == b.id }
        try f.assertInstalled(b, presented: false)
        XCTAssertTrue(try f.installed().hasUnseenAnswer)
        f.state.showPanel()
        try await f.waitUntil { try !f.installed().panelHidden && f.controller.isAnswerPresented }
        try f.assertInstalled(b)
        XCTAssertFalse(try f.installed().hasUnseenAnswer)
    }

    func testReplacementAfterStreamingDraftCleanupInstallsPublishedAnswer() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let a = f.answer("Alpha"), b = f.answer("Bravo")
        f.state.showDraft(.init(requestID: a.id, generation: 1, kind: .answer, heard: nil, blocks: a.blocks))
        try await f.waitUntil { try f.installed().requestID == a.id && f.installed().isDraft }
        XCTAssertEqual(try f.installed().renderedBlocks.map { String($0.characters) }, a.blocks.map(\.text))
        // The service clears request-owned drafts on cancellation/completion.
        f.state.clearDraft(requestID: a.id, generation: 1)
        try await f.publishAndWait(b)
    }

    func testPublicationDuringPendingMeasurementSupersedesStagedDraft() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        try await f.publishAndWait(f.answer("First"))
        let a = f.answer("Alpha", extraLines: 8), b = f.answer("Bravo")
        var sawPendingTask = false
        var committedIDs: [UUID?] = []
        f.controller.onTransitionCommitted = { _ in committedIDs.append(try? f.installed().requestID) }
        f.controller.onTargetStaged = {
            f.controller.onTargetStaged = nil
            Task { @MainActor in
                // This job is enqueued before the measurement job. That job
                // yields once before finishing, so its handle must still exist.
                let task = Mirror(reflecting: f.controller!).children.first { $0.label == "measurementTask" }
                sawPendingTask = (task?.value as? Task<Void, Never>) != nil
                f.state.clearDraft(requestID: a.id, generation: 1)
                f.state.publish(b)
                // The real synchronous entry point must retire the older task.
                f.controller.syncPanelVisibility()
            }
        }
        f.state.showDraft(.init(requestID: a.id, generation: 1, kind: .answer, heard: nil, blocks: a.blocks))
        try await f.waitUntil { try f.installed().requestID == b.id }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(sawPendingTask, "The race must actually overlap a pending measurement.")
        XCTAssertFalse(committedIDs.contains(a.id), "The superseded draft must not overwrite B.")
        try f.assertInstalled(b)
    }

    func testNewPublicationInsideMeasurementCallbackRetiresOlderRevision() async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        try await f.publishAndWait(f.answer("First"))
        let a = f.answer("Alpha", extraLines: 8), b = f.answer("Bravo")
        var committedIDs: [UUID?] = []
        var superseded = false
        f.controller.onTransitionCommitted = { _ in committedIDs.append(try? f.installed().requestID) }
        f.controller.onTargetMeasured = { _ in
            f.controller.onTargetMeasured = nil
            superseded = true
            f.state.publish(b)
            f.controller.syncPanelVisibility()
        }
        f.state.publish(a)
        try await f.waitUntil { try f.installed().requestID == b.id }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(superseded)
        XCTAssertFalse(committedIDs.contains(a.id))
        try f.assertInstalled(b)
    }

    func testThreeAnswersAtRealCallIntervalsWith250MillisecondUpdates() async throws {
        try await exerciseCall(cadence: .milliseconds(250))
    }

    func testThreeAnswersAtRealCallIntervalsWith20HertzUpdates() async throws {
        try await exerciseCall(cadence: .milliseconds(50))
    }

    private func exerciseCall(cadence: Duration) async throws {
        let f = MeetingCoachDisplayFixture()
        defer { f.stop() }
        let me = CurrentValueSubject<Float, Never>(0)
        let them = CurrentValueSubject<Float, Never>(0)
        f.wave.bind(me: me.eraseToAnyPublisher(), them: them.eraseToAnyPublisher(), state: f.state)
        var speakerPublications = 0, wavePublications = 0
        let speakerToken = f.state.speakerModel.$speaker.dropFirst().sink { _ in speakerPublications += 1 }
        let waveToken = f.wave.$bars.dropFirst().sink { _ in wavePublications += 1 }
        defer { speakerToken.cancel(); waveToken.cancel() }
        let answers = [f.answer("Alpha"), f.answer("Bravo"), f.answer("Charlie", extraLines: 4)]
        var committedIDs: [UUID] = []
        f.controller.onTransitionCommitted = { _ in
            if let id = try? f.installed().requestID, committedIDs.last != id { committedIDs.append(id) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var latest = 0, tick = 0
        var publicationTimes: [Duration] = []
        publicationTimes.append(start.duration(to: clock.now))
        try await f.publishAndWait(answers[0])
        var nextTick = start
        // Real elapsed time: the supplied log has 21 s and then 12 s gaps.
        while clock.now < start.advanced(by: .seconds(34)) {
            try await clock.sleep(until: nextTick, tolerance: .milliseconds(2))
            let elapsed = start.duration(to: clock.now)
            f.state.setSpeaker(tick.isMultiple(of: 2) ? .me : .them)
            me.send(tick.isMultiple(of: 2) ? 0.25 : 0.85)
            them.send(tick.isMultiple(of: 2) ? 0.75 : 0.15)
            f.controller.capsulePanel?.contentView?.layoutSubtreeIfNeeded()
            // Anchor C to B's actual publication, so scheduler latency cannot
            // shorten the requested twelve-second gap.
            if (latest == 0 && elapsed >= .seconds(21))
                || (latest == 1 && elapsed - publicationTimes[1] >= .seconds(12)) {
                latest += 1
                publicationTimes.append(elapsed)
                try await f.publishAndWait(answers[latest])
            }
            try f.assertInstalled(answers[latest])
            tick += 1
            nextTick = start.advanced(by: cadence * tick)
        }
        XCTAssertEqual(latest, 2)
        XCTAssertEqual(committedIDs, answers.map(\.id))
        XCTAssertGreaterThan(speakerPublications, 100)
        XCTAssertGreaterThan(wavePublications, 50)
        XCTAssertGreaterThan(f.wave.mainInputDeliveryCount, 50)
        XCTAssertGreaterThan(Set(f.timerReads.map { Int($0.timeIntervalSince(f.startedAt)) }).count, 20,
                             "The real capsule TimelineView must have evaluated across the call.")
        XCTAssertEqual(publicationTimes.count, 3)
        XCTAssertGreaterThanOrEqual(publicationTimes[1], .seconds(21))
        XCTAssertLessThan(publicationTimes[1] - .seconds(21), .seconds(1))
        XCTAssertGreaterThanOrEqual(publicationTimes[2] - publicationTimes[1], .seconds(12))
        XCTAssertLessThan(publicationTimes[2] - publicationTimes[1] - .seconds(12), .seconds(1))
        try f.assertInstalled(answers[2])
    }

    private func questionField(in view: NSView) -> MeetingCoachQuestionTextField? {
        if let field = view as? MeetingCoachQuestionTextField { return field }
        return view.subviews.lazy.compactMap { self.questionField(in: $0) }.first
    }
}
