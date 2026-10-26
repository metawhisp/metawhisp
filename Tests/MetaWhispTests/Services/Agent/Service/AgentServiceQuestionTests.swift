import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — a run's Yes/No question reaches the Island and MetaChat as
/// `.needsYes`, and the first answer goes back to the run. Silence for the
/// answer window, Stop, or the run giving up on its question is No, and
/// nothing is left waiting.
@MainActor
final class AgentServiceQuestionTests: XCTestCase {

    private let working = ErrandEvent.working(title: "Filling the form", done: 0, wanted: nil)
    private let window = Duration.seconds(ConfirmationRequest.answerWindow)

    /// The questions' windows the service set; the ceiling is a timer too.
    private func windows(_ h: AgentServiceHarness) -> [Duration] {
        h.timers.map(\.delay).filter { $0 == window }
    }

    private func question(_ address: String = "https://site-1.test/form") -> ConfirmationRequest {
        ConfirmationRequest(action: AgentAction(operation: .open, target: nil, destination: address, payload: nil,
                                                isPlannedSearch: false),
                            tab: BrowserTab(windowID: "1", tabID: "7"), pageURL: "https://site-1.test/", askedAt: .now)
    }

    /// A running errand whose run has said what it is doing.
    private func runningErrand(_ h: AgentServiceHarness, _ service: AgentService) async -> (UUID, FakeErrandRunner?) {
        h.link.connect()
        let id = service.start(goal: "Send the contact form", origin: .chat(messageID: UUID())).id!
        let run = await h.runner(for: id)
        run?.say(.working(title: "Filling the form", done: 0, wanted: nil))
        return (id, run)
    }

    func testAQuestionReachesTheUIAndTheFirstAnswerGoesBackToTheRun() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let request = question()
        let asked = run!.ask(request)
        await h.until({ service.latest?.event == .needsYes(request) }, "the question")

        XCTAssertTrue(service.answer(id, to: request, .yes))
        XCTAssertFalse(service.answer(id, to: request, .no), "a second answer does not count")
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertEqual(asked.answer, .yes, "the first answer counts")
        XCTAssertEqual(h.events(of: id).suffix(3), [working, .needsYes(request), working],
                       "once answered, the errand shows what it was doing again")
        XCTAssertEqual(windows(h), [window])
    }

    /// A form's question (ITER-076 stage 7): the preview, or the Send.
    private func formQuestion(_ kind: FormQuestion.Kind) -> ConfirmationRequest {
        var request = question()
        request.form = FormQuestion(kind: kind, host: "site-1.test", destination: nil,
                                    rows: [FormRow(label: "Email", shown: .value("sam@example.test", .memories,
                                                                                unsure: false))])
        return request
    }

    /// Decision 7.4: a form's preview has no timer — the service sets it no
    /// window, and an answer counts however late it comes; silence is no
    /// answer yet, never a No. The errand's own expiry still ends it.
    func testAFormsPreviewWaitsForTheUserWithNoWindow() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let request = formQuestion(.fill)
        XCTAssertNil(request.window)
        let asked = run!.ask(request)
        await h.until({ service.latest?.event == .needsYes(request) }, "the preview")
        XCTAssertTrue(windows(h).isEmpty, "no two-minute window: \(h.timers.map(\.delay))")
        XCTAssertTrue(service.answer(id, to: request, .yes))
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertEqual(asked.answer, .yes)
        let at = request.askedAt
        XCTAssertEqual(request.outcome(answer: .yes, answeredAt: at + .seconds(600), now: at + .seconds(601)), .approved)
        XCTAssertEqual(request.outcome(answer: nil, answeredAt: nil, now: at + .seconds(1_000)), .waiting)
    }

    /// The Send question keeps the two-minute window every Yes has.
    func testAFormsSendKeepsTheTwoMinuteWindow() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (_, run) = await runningErrand(h, service)
        let request = formQuestion(.send)
        XCTAssertEqual(request.window, ConfirmationRequest.answerWindow)
        let asked = run!.ask(request)
        await h.until({ !windows(h).isEmpty }, "the question's window")
        XCTAssertEqual(windows(h), [window])
        h.fireFirstTimer(after: window)
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertNil(asked.answer, "silence is No")
    }

    func testSilenceForTheAnswerWindowIsNo() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let request = question()
        let asked = run!.ask(request)
        await h.until({ !windows(h).isEmpty }, "the question's window")
        XCTAssertEqual(windows(h), [.seconds(120)])
        XCTAssertFalse(asked.isAnswered, "the question waits for the user")

        h.fireFirstTimer(after: window)
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertNil(asked.answer, "silence is No")
        XCTAssertEqual(service.latest?.event, working)
        let before = h.updates.count
        XCTAssertFalse(service.answer(id, to: request, .yes), "a late answer does not count")
        XCTAssertEqual(h.updates.count, before)
    }

    func testStopDuringAQuestionEndsItAsNo() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let request = question()
        let asked = run!.ask(request)
        await h.until({ service.latest?.event == .needsYes(request) }, "the question")

        service.stop(id)
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertNil(asked.answer)
        XCTAssertEqual(h.events(of: id).last?.isFinished, true, "nothing shows after the end")
        XCTAssertEqual(run?.stops, 1)
    }

    /// A run that gives up on its question — `AgentRun` asks within a deadline
    /// — leaves nothing waiting, and the answer that comes after is ignored.
    func testARunThatGivesUpOnItsQuestionLeavesNothingWaiting() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let request = question()
        let asked = run!.ask(request)
        await h.until({ service.latest?.event == .needsYes(request) }, "the question")

        asked.giveUp()
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertNil(asked.answer)
        await h.until({ service.latest?.event == working }, "the question to close")
        let before = h.updates.count
        XCTAssertFalse(service.answer(id, to: request, .yes))
        XCTAssertEqual(h.updates.count, before)
    }

    /// Review of B1, S3: the run gave up on question A and asks B, about
    /// another action. A Yes the user gave A's card never answers B.
    func testAYesForAnEarlierQuestionNeverAnswersALaterOne() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let first = question("https://site-1.test/delete-account")
        let second = question("https://site-1.test/send-order")
        let askedFirst = run!.ask(first)
        await h.until({ service.latest?.event == .needsYes(first) }, "the first question")
        askedFirst.giveUp()
        await h.until({ askedFirst.isAnswered }, "the run to give up on the first question")
        let askedSecond = run!.ask(second)
        await h.until({ service.latest?.event == .needsYes(second) }, "the second question")

        XCTAssertFalse(service.answer(id, to: first, .yes), "a Yes for the first question does not count")
        XCTAssertFalse(askedSecond.isAnswered, "and does not answer the second")
        XCTAssertTrue(service.answer(id, to: second, .no))
        await h.until({ askedSecond.isAnswered }, "the second answer")
        XCTAssertEqual(askedSecond.answer, .no)
    }

    /// A question's window closes that question only: A's, running out after
    /// A was answered and B asked, leaves B open.
    func testAnEarlierQuestionsWindowLeavesALaterOneOpen() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let first = question("https://site-1.test/first")
        let second = question("https://site-1.test/second")
        let askedFirst = run!.ask(first)
        await h.until({ service.latest?.event == .needsYes(first) }, "the first question")
        XCTAssertTrue(service.answer(id, to: first, .yes))
        await h.until({ askedFirst.isAnswered }, "the first answer")
        let askedSecond = run!.ask(second)
        await h.until({ service.latest?.event == .needsYes(second) }, "the second question")

        h.fireFirstTimer(after: window)
        XCTAssertEqual(service.latest?.event, .needsYes(second), "the second question is still open")
        XCTAssertTrue(service.answer(id, to: second, .no), "and still takes its answer")
        await h.until({ askedSecond.isAnswered }, "the second answer")
        XCTAssertEqual(askedSecond.answer, .no)
    }

    func testANewQuestionEndsTheOneBeforeAsNo() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let first = question("https://site-1.test/first")
        let second = question("https://site-1.test/second")
        let askedFirst = run!.ask(first)
        await h.until({ service.latest?.event == .needsYes(first) }, "the first question")
        let askedSecond = run!.ask(second)
        await h.until({ askedFirst.isAnswered }, "the first answer")
        XCTAssertNil(askedFirst.answer)
        await h.until({ service.latest?.event == .needsYes(second) }, "the second question")
        XCTAssertTrue(service.answer(id, to: second, .yes))
        await h.until({ askedSecond.isAnswered }, "the second answer")
        XCTAssertEqual(askedSecond.answer, .yes)
    }

    func testAnswersThatBelongToNoQuestionAreIgnored() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        let request = question()
        let before = h.updates.count
        XCTAssertFalse(service.answer(id, to: request, .yes), "no question is open")
        XCTAssertEqual(h.updates.count, before)

        let asked = run!.ask(request)
        await h.until({ service.latest?.event == .needsYes(request) }, "the question")
        XCTAssertFalse(service.answer(UUID(), to: request, .yes), "an answer for another errand does not count")
        XCTAssertFalse(asked.isAnswered)
        XCTAssertTrue(service.answer(id, to: request, .no))
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertEqual(asked.answer, .no)
    }

    func testAQuestionAfterTheErrandEndedIsNoAtOnce() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let (id, run) = await runningErrand(h, service)
        service.stop(id)
        let asked = run!.ask(question())
        await h.until({ asked.isAnswered }, "the answer")
        XCTAssertNil(asked.answer)
        XCTAssertFalse(h.events(of: id).contains { if case .needsYes = $0 { true } else { false } })
        XCTAssertEqual(windows(h), [], "no window for a question that never opened")
    }
}
