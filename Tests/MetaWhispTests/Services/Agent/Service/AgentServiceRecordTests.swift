import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — every errand that ends is kept on disk: its record and its
/// outcome, whether it ran, was stopped, or never got to run. A file that
/// cannot be written never breaks the service.
@MainActor
final class AgentServiceRecordTests: XCTestCase {

    private func sources(_ count: Int) -> [URL] {
        (1...count).map { URL(string: "https://site-\($0).test/")! }
    }

    func testAFinishedErrandIsSavedWithItsRecordAndOutcome() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let origin = ErrandOrigin.voice(questionID: UUID())
        let id = service.start(goal: "Collect two sites", origin: origin).id!
        let run = await h.runner(for: id)
        run?.collect(2)
        let done = ErrandOutcome(ending: .done, answer: nil, sources: sources(2), sheet: URL(string: "https://sheet.test/1"),
                                 rows: 2)
        run?.finish(done)
        await h.until({ !service.errandRunning }, "the errand's end")

        var record = run!.record
        record.end(.done, failure: nil)
        XCTAssertEqual(h.saved(id), ErrandRecordStore.Saved(version: 1, origin: origin, record: record, outcome: done))
    }

    func testAStoppedErrandIsSavedWithWhatItCollected() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Collect five sites", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.collect(3)
        service.stop(id)
        let saved = h.saved(id)
        XCTAssertEqual(saved?.record.rows, run?.record.rows, "saved at once, with the rows")
        XCTAssertEqual(saved?.record.ending, .stopped)
        XCTAssertEqual(saved?.outcome, ErrandOutcome(ending: .stopped, answer: nil, sources: sources(3), sheet: nil, rows: 3))
    }

    /// A stopped run may still check an action it had sent (ITER-074 §7.4):
    /// when it returns, its final record goes over the one saved at Stop —
    /// the errand still shows one end, the one it showed at Stop.
    func testAStoppedRunsFinalRecordIsSavedOverTheOneSavedAtStop() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Collect five sites", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.returnsOnStop = false
        run?.collect(2)
        service.stop(id)
        let shown = ErrandOutcome(ending: .stopped, answer: nil, sources: sources(2), sheet: nil, rows: 2)
        XCTAssertEqual(h.saved(id)?.record.steps.count, 0, "saved at once, as it stood")

        // The check of the click it had sent comes back: the click did not hold.
        run?.record.append(AgentAction(operation: .click, target: nil, destination: nil, payload: nil,
                                       isPlannedSearch: false),
                           outcome: .failed, confidence: 0.9, engine: "scripted", milliseconds: 40, costUSD: nil)
        run?.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 2))
        await h.until({ h.saved(id)?.record.steps.count == 1 }, "the final record")
        XCTAssertEqual(h.saved(id)?.record.steps.first?.outcome, .failed)
        XCTAssertEqual(h.saved(id)?.record.rows.count, 2)
        XCTAssertEqual(h.saved(id)?.record.ending, .stopped)
        XCTAssertEqual(h.saved(id)?.outcome, shown, "the outcome the errand showed")
        XCTAssertEqual(h.events(of: id).filter(\.isFinished), [.finished(shown)], "one end")
    }

    /// I-06a review, P2-1: at the 200-event boundary, a step taken back after
    /// Stop still leaves one ending: the ending the service saved at Stop and
    /// the run's own fall under one number, and under each number the log's
    /// last line is the saved record's event, exactly.
    func testAStepTakenBackAfterStopAtTheEventCapLeavesOneEnding() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Collect five sites", origin: .chat(messageID: UUID())).id!
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        run.returnsOnStop = false
        let say = run.setup.log
        say(run.record.note(.plan(.ok, milliseconds: 1, costUSD: 0)))
        for _ in 1...198 { say(run.record.note(.pageMiss(.read))) }
        say(run.record.append(AgentAction(operation: .scroll, target: nil, destination: nil, payload: nil,
                                          isPlannedSearch: false),
                              outcome: .acted, confidence: 0.9, engine: "scripted", milliseconds: 3, costUSD: nil))
        XCTAssertEqual(run.record.events.count, ErrandRecord.maxEvents, "at the cap")

        service.stop(id)
        // The run finds the step never went out, then ends, as `AgentRun` does.
        run.record.removeLastStep().map(say)
        run.record.end(.stopped, failure: nil).map(say)
        run.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ h.saved(id)?.record.events.contains(.takenBack) == true }, "the final record")

        let record = try XCTUnwrap(h.saved(id)?.record)
        XCTAssertEqual(record.events.count, ErrandRecord.maxEvents)
        XCTAssertEqual(record.droppedEvents, 1)
        XCTAssertEqual(record.events.suffix(2).map(\.shape), ["taken back", "ending stopped rows=0"])
        let logged = Array(h.logged.events(of: id).dropFirst(record.droppedEvents))
        XCTAssertEqual(logged, record.eventLines, "the log's last word under each number")
        XCTAssertEqual(h.logged.events(of: id).filter { $0.contains(" ending ") }.count, 1, "one ending")
    }

    /// The file is the errand's: a run whose record carries another id is
    /// still saved under the errand's own.
    func testARecordIsSavedUnderTheErrandsOwnID() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Collect two sites", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        let strayID = UUID()
        run?.record = ErrandRecord(errandID: strayID, goal: "Collect two sites")
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the errand's end")
        XCTAssertNotNil(h.saved(id), "under the errand's id")
        XCTAssertNil(h.saved(strayID))
    }

    func testAnErrandTheBrowserDidNotLetInIsSavedWithWhy() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let id = service.start(goal: " Collect five sites ", origin: .chat(messageID: UUID())).id!
        await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
        h.link.fail(.notAllowed)
        await h.until({ !service.errandRunning }, "the errand's end")
        let saved = h.saved(id)
        XCTAssertEqual(saved?.record.goal, "Collect five sites")
        XCTAssertEqual(saved?.record.steps, [])
        XCTAssertEqual(saved?.record.ending, .stopped, "a setup step, not a failure (ITER-076 stage 8a, № 19)")
        XCTAssertEqual(saved?.outcome.notRun, .notAllowed)
    }

    func testErrandsThatNeverRanAreSavedAsNotStarted() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let ids = (1...3).map { service.start(goal: "Errand \($0)", origin: .chat(messageID: UUID())).id! }
        _ = await h.runner(for: ids[0])
        service.stop(ids[1])
        service.stopAll()
        XCTAssertEqual(h.saved(ids[1])?.outcome, ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
        XCTAssertEqual(h.saved(ids[2])?.outcome.notRun, .stoppedAll)
        XCTAssertEqual(h.saved(ids[2])?.record.ending, .stopped)
        XCTAssertNotNil(h.saved(ids[0]))
    }

    /// The folder cannot be written: every errand still ends, shows its end,
    /// frees the Mac, and the next one starts.
    func testAFileThatCannotBeWrittenDoesNotBreakTheService() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        try FileManager.default.createDirectory(at: h.folder, withIntermediateDirectories: true)
        let blocked = h.folder.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocked)
        h.link.connect()
        let service = h.makeService(store: ErrandRecordStore(directory: blocked))
        let first = service.start(goal: "First errand", origin: .chat(messageID: UUID())).id!
        let second = service.start(goal: "Second errand", origin: .chat(messageID: UUID())).id!
        await h.runner(for: first)?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        let run = await h.runner(for: second)
        XCTAssertEqual(h.events(of: first).last?.isFinished, true)
        run?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !service.errandRunning }, "the second errand's end")
        XCTAssertFalse(h.keepsAwake)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("\(first.uuidString).json").path))
    }

    // MARK: - Codex round 3, N3-P1-2: a cleared record does not come back

    /// A runner that does not return on Stop still saves its record at Stop.
    /// If the user clears MetaChat history before the runner returns, the
    /// service must NOT bring the cleared record back from the late save. A
    /// fresh errand admitted after the clear saves normally.
    func testAClearedRecordDoesNotComeBackFromALateRunner() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let id = service.start(goal: "Collect five sites", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.returnsOnStop = false
        run?.collect(2)
        service.stop(id)
        let stoppedFile = ErrandRecordStore(directory: h.folder).fileURL(for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stoppedFile.path),
                      "the Stop-time save is on disk")

        // Clear the service's history, like the user tapping "clear MetaChat".
        service.deleteAllRecords()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stoppedFile.path),
                       "the clear removed the file")

        // The runner now returns — its final record goes over the one saved
        // at Stop. After a clear that must NOT happen.
        run?.finish(ErrandOutcome(ending: .stopped, answer: nil, sources: sources(2), sheet: nil, rows: 2))
        await h.until({ run?.isRunning == false }, "the runner's return")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stoppedFile.path),
                       "the late save is dropped — the generation was advanced by the clear")

        // A fresh errand after the clear must still save normally.
        let nextID = service.start(goal: "Collect two more sites", origin: .chat(messageID: UUID())).id!
        let nextRun = await h.runner(for: nextID)
        nextRun?.finish(ErrandOutcome(ending: .done, answer: nil, sources: sources(2), sheet: nil, rows: 2))
        await h.until({ !service.errandRunning }, "the next errand's end")
        let nextFile = ErrandRecordStore(directory: h.folder).fileURL(for: nextID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nextFile.path),
                      "a fresh errand after the clear saves normally")
    }

    // MARK: - ITER-076 stage 9d, № 21: an errand a crash cut off

    /// An errand is on disk from its admit, not ended — the one that runs and
    /// each one that waits: a crash, a Force Quit or a power loss leaves it
    /// there for the next launch.
    func testAnErrandIsOnDiskNotEndedFromItsAdmit() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let service = h.makeService()
        let origin = ErrandOrigin.voice(questionID: UUID())
        let running = service.start(goal: "Find 10 jokes", origin: origin).id!
        let waiting = service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id!
        _ = await h.runner(for: running)
        XCTAssertEqual(h.saved(running)?.origin, origin)
        XCTAssertEqual(h.saved(running)?.record.goal, "Find 10 jokes")
        XCTAssertNil(h.saved(running)?.record.ending, "not ended")
        XCTAssertNil(h.saved(waiting)?.record.ending, "the waiting one too")
    }

    /// The next launch ends each errand the last session left not ended: it
    /// ends stopped — what it found went with the app — and says so, as any
    /// end does, so MetaChat no longer shows it started. Each once; a stop is
    /// no failure, and is not reported.
    func testAnErrandACrashCutOffEndsStoppedAtTheNextLaunch() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let crashed = h.makeService()
        let origin = ErrandOrigin.voice(questionID: UUID())
        let running = crashed.start(goal: "Find 10 jokes", origin: origin).id!
        let waiting = crashed.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id!
        _ = await h.runner(for: running)

        // The app is gone with both; the next launch's service finds them.
        let relaunched = h.makeService()
        relaunched.endInterrupted()
        let stopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0)
        let ends = h.updates.filter { $0.event.isFinished }
        XCTAssertEqual(Set(ends.map(\.id)), [running, waiting])
        XCTAssertEqual(ends.first { $0.id == running }, ErrandUpdate(id: running, origin: origin, event: .finished(stopped)))
        XCTAssertEqual(h.saved(running)?.record.ending, .stopped)
        XCTAssertEqual(h.saved(running)?.outcome, stopped)
        XCTAssertEqual(h.saved(waiting)?.record.ending, .stopped)
        XCTAssertEqual(ChatService.errandResultText(stopped), "Stopped.", "the approved line")
        XCTAssertFalse(AgentService.reportedEndings.contains(stopped.ending), "not reported to MetaWhisp")

        relaunched.endInterrupted()
        XCTAssertEqual(h.updates.filter { $0.event.isFinished }.count, 2, "each ends once")
    }

    /// MetaChat cleared while an errand ran, then a crash: nothing of it
    /// comes back at the next launch.
    func testNothingComesBackAfterMetaChatWasCleared() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let crashed = h.makeService()
        let id = crashed.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        _ = await h.runner(for: id)
        crashed.deleteAllRecords()

        let relaunched = h.makeService()
        relaunched.endInterrupted()
        XCTAssertFalse(h.updates.contains { $0.event.isFinished }, "no end comes back")
        XCTAssertNil(h.saved(id))
    }

    /// An errand that ended, and the errands this session holds, are not the
    /// launch's to end.
    func testOnlyErrandsTheLastSessionLeftAreEndedAtLaunch() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        h.link.connect()
        let earlier = h.makeService()
        let ended = earlier.start(goal: "Find 10 jokes", origin: .chat(messageID: UUID())).id!
        await h.runner(for: ended)?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ !earlier.errandRunning }, "its end")

        let service = h.makeService()
        let before = h.updates.count
        let mine = service.start(goal: "Find 5 recipes", origin: .chat(messageID: UUID())).id!
        service.endInterrupted()
        XCTAssertFalse(h.updates.dropFirst(before).contains { $0.event.isFinished }, "no end at launch")
        XCTAssertEqual(h.saved(ended)?.record.ending, .done)
        XCTAssertNil(h.saved(mine)?.record.ending, "this session's own errand goes on")
    }

    /// The app ends them once MetaChat hears an errand's end, and before the
    /// cards do: a relaunched app shows no card (`ErrandCardStack`).
    func testTheAppEndsTheLastSessionsErrandsOnceMetaChatHearsThem() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../App/AppDelegate.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        let chat = try XCTUnwrap(source.range(of: "chatService.observeErrands(AgentService.shared.events)"))
        let ended = try XCTUnwrap(source.range(of: "AgentService.shared.endInterrupted()"), "the launch ends them")
        let cards = try XCTUnwrap(source.range(of: "ErrandCardStack.shared.observe(AgentService.shared.events"))
        XCTAssertLessThan(chat.lowerBound, ended.lowerBound, "after MetaChat subscribes")
        XCTAssertLessThan(ended.lowerBound, cards.lowerBound, "before the cards do")
    }
}
