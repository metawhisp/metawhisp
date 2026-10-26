import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 I-11 — one card per errand, from the errand service's own events:
/// each card updates in place while its errand runs and never fades; its
/// buttons call the service, which decides — the card shows only what the
/// service says; an ended errand's card can be closed and closes by itself.
@MainActor
final class ErrandCardStackTests: XCTestCase {

    /// What the card's open buttons asked for.
    private final class Opened {
        var sheets: [URL] = []
        var results: [UUID] = []
    }

    /// The card's buttons, recorded, with no service behind them: nothing
    /// they do reaches a card unless an event says so.
    private final class RecordingService: ErrandCardService {
        var stops: [UUID] = []
        var stopAlls = 0
        var answers: [(UUID, ConfirmationRequest, ConfirmationRequest.Answer)] = []
        var proceeds: [(UUID, ErrandPause)] = []
        var shownTabs: [UUID] = []
        func stop(_ id: UUID) { stops.append(id) }
        func stopAll() { stopAlls += 1 }
        func answer(_ id: UUID, to request: ConfirmationRequest, _ answer: ConfirmationRequest.Answer) -> Bool {
            answers.append((id, request, answer))
            return true
        }
        func proceed(_ id: UUID, after pause: ErrandPause) -> Bool {
            proceeds.append((id, pause))
            return true
        }
        func showTab(_ id: UUID) -> Bool {
            shownTabs.append(id)
            return true
        }
    }

    /// Timers the test fires by hand.
    private var timers: [(seconds: TimeInterval, action: @MainActor () -> Void)] = []

    private func makeStack() -> ErrandCardStack {
        ErrandCardStack(schedule: { [weak self] seconds, action in self?.timers.append((seconds, action)) })
    }

    private func fireTimers() {
        let due = timers
        timers = []
        for timer in due { timer.action() }
    }

    private func observe(_ stack: ErrandCardStack, _ events: AnyPublisher<ErrandUpdate, Never>,
                         _ service: any ErrandCardService, opened: Opened = Opened()) {
        stack.observe(events, service: service, openSheet: { opened.sheets.append($0) },
                      openResult: { opened.results.append($0) })
    }

    private func question(_ address: String = "https://site-1.test/form",
                          askedAt: ContinuousClock.Instant = .now) -> ConfirmationRequest {
        ConfirmationRequest(action: AgentAction(operation: .open, target: nil, destination: address, payload: nil,
                                                isPlannedSearch: false),
                            tab: BrowserTab(windowID: "1", tabID: "7"), pageURL: address, askedAt: askedAt)
    }

    private func card(_ stack: ErrandCardStack, _ id: UUID) -> ErrandCard? {
        stack.cards.first { $0.id == id }
    }

    private let chat = ErrandOrigin.chat(messageID: UUID())

    // MARK: - One card per errand, in place

    func testEveryErrandGetsItsOwnCardUpdatedInPlace() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let stack = makeStack()
        observe(stack, service.events, service)
        h.link.connect()
        let first = service.start(goal: "Find shops", origin: chat).id!
        let second = service.start(goal: "Find cafes", origin: chat).id!
        // The waiting errand says its place at once; the running one shows
        // once the service's job says where the browser stands.
        await h.until({ stack.cards.count == 2 }, "both cards")
        XCTAssertEqual(stack.cards.map(\.id), [first, second], "the running one first, then the line")
        XCTAssertEqual(card(stack, second)?.title, "Next in line")

        let run = await h.runner(for: first)
        run?.say(.working(title: "Shops", done: 1, wanted: 4))
        XCTAssertEqual(stack.cards.count, 2, "updated in place, not a new card")
        XCTAssertEqual(card(stack, first)?.title, "Shops — 1 of 4")
        run?.say(.working(title: "Shops", done: 2, wanted: 4))
        XCTAssertEqual(card(stack, first)?.title, "Shops — 2 of 4")
        XCTAssertTrue(timers.isEmpty, "a running errand's card never fades")
    }

    /// The service tells a waiting errand its place at once and a started one
    /// a moment later: the cards keep the queue's order whatever came first —
    /// the errands that run or ran, as they came, then the line by place.
    func testTheCardsKeepTheQueuesOrder() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), RecordingService())
        let (running, next, last) = (UUID(), UUID(), UUID())
        events.send(ErrandUpdate(id: last, origin: chat, event: .queued(position: 2)))
        events.send(ErrandUpdate(id: next, origin: chat, event: .queued(position: 1)))
        events.send(ErrandUpdate(id: running, origin: chat, event: .connecting(.connecting)))
        XCTAssertEqual(stack.cards.map(\.id), [running, next, last])

        events.send(ErrandUpdate(id: running, origin: chat, event: .finished(ErrandOutcome(
            ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))))
        events.send(ErrandUpdate(id: last, origin: chat, event: .queued(position: 1)))
        events.send(ErrandUpdate(id: next, origin: chat, event: .connecting(.connecting)))
        XCTAssertEqual(stack.cards.map(\.id), [running, next, last])
        XCTAssertEqual(card(stack, last)?.title, "Next in line")
    }

    // MARK: - The buttons call the service; the card shows what it says

    func testStopAndStopAllCallTheServiceAndTheCardWaitsForIt() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let service = RecordingService()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), service)
        let id = UUID()
        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Shops", done: 1, wanted: 4)))

        stack.press(.stop, on: id)
        XCTAssertEqual(service.stops, [id])
        XCTAssertEqual(card(stack, id)?.label, "Working", "never \"Stopped\" before the service says so")
        stack.press(.stopAll, on: id)
        XCTAssertEqual(service.stopAlls, 1)
        XCTAssertEqual(card(stack, id)?.label, "Working")

        events.send(ErrandUpdate(id: id, origin: chat, event: .finished(ErrandOutcome(
            ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 1))))
        XCTAssertEqual(card(stack, id)?.label, "Stopped")
        XCTAssertEqual(card(stack, id)?.body, "1 row saved.")
    }

    func testYesAndNoAnswerTheCardsOwnQuestion() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let service = RecordingService()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), service)
        let id = UUID()
        let request = question()
        events.send(ErrandUpdate(id: id, origin: chat, event: .needsYes(request)))
        stack.press(.yes, on: id)
        stack.press(.no, on: id)
        XCTAssertEqual(service.answers.map(\.0), [id, id])
        XCTAssertEqual(service.answers.map(\.1), [request, request])
        XCTAssertEqual(service.answers.map(\.2), [.yes, .no])
        XCTAssertEqual(card(stack, id)?.label, "Needs your Yes", "the service decides what the answer did")
    }

    /// Continue and Show tab call the service for the card's own pause, and
    /// the card waits for what the service then says (ITER-076 stage 3).
    func testContinueAndShowTabCallTheServiceForTheCardsOwnPause() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let service = RecordingService()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), service)
        let id = UUID()
        let pause = ErrandPause(id: UUID(), handover: ErrandHandover(kind: .signIn, host: "site-5.test"))
        events.send(ErrandUpdate(id: id, origin: chat, event: .paused(pause)))
        stack.press(.showTab, on: id)
        stack.press(.proceed, on: id)
        XCTAssertEqual(service.shownTabs, [id])
        XCTAssertEqual(service.proceeds.map(\.0), [id])
        XCTAssertEqual(service.proceeds.map(\.1), [pause])
        XCTAssertEqual(card(stack, id)?.label, "Sign-in needed", "the service decides what Continue did")

        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Order", done: 0, wanted: nil)))
        stack.press(.proceed, on: id)
        stack.press(.showTab, on: id)
        XCTAssertEqual(service.proceeds.count, 1, "a pause that closed takes no Continue")
        XCTAssertEqual(service.shownTabs, [id])
    }

    /// A Yes asked while another errand's Yes is open: two cards, each answers
    /// its own request, each counts down from its own `askedAt`.
    func testTwoOpenQuestionsEachAnswerTheirOwn() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let service = RecordingService()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), service)
        let now = ContinuousClock.now
        let (a, b) = (UUID(), UUID())
        let first = question("https://one.test/form", askedAt: now - .seconds(90))
        let second = question("https://two.test/form", askedAt: now)
        events.send(ErrandUpdate(id: a, origin: chat, event: .needsYes(first)))
        events.send(ErrandUpdate(id: b, origin: chat, event: .needsYes(second)))
        XCTAssertEqual(stack.cards.count, 2)
        XCTAssertEqual(card(stack, a)?.countdown(at: now)?.time, "0:30")
        XCTAssertEqual(card(stack, b)?.countdown(at: now)?.time, "2:00")

        stack.press(.yes, on: b)
        stack.press(.no, on: a)
        XCTAssertEqual(service.answers.map(\.0), [b, a])
        XCTAssertEqual(service.answers.map(\.1), [second, first])
        XCTAssertEqual(service.answers.map(\.2), [.yes, .no])
    }

    /// A button the card no longer offers does nothing: a click on a stale
    /// card after its question closed answers nothing.
    func testAButtonTheCardNoLongerOffersDoesNothing() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let service = RecordingService()
        let opened = Opened()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), service, opened: opened)
        let id = UUID()
        events.send(ErrandUpdate(id: id, origin: chat, event: .needsYes(question())))
        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Form", done: 0, wanted: nil)))
        stack.press(.yes, on: id)
        stack.press(.openSheet, on: id)
        stack.press(.openInMetaChat, on: id)
        stack.press(.stop, on: UUID())
        XCTAssertTrue(service.answers.isEmpty)
        XCTAssertTrue(service.stops.isEmpty, "no card, no Stop")
        XCTAssertTrue(opened.sheets.isEmpty)
        XCTAssertTrue(opened.results.isEmpty)
    }

    func testTheOpenButtonsOpenTheSheetAndTheResult() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let opened = Opened()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), RecordingService(), opened: opened)
        let id = UUID()
        let sheet = URL(string: "https://docs.google.com/spreadsheets/d/abc/edit")!
        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Shops", done: 2, wanted: 2)))
        events.send(ErrandUpdate(id: id, origin: chat, event: .finished(ErrandOutcome(
            ending: .done, answer: nil, sources: [], sheet: sheet, rows: 2))))
        stack.press(.openSheet, on: id)
        stack.press(.openInMetaChat, on: id)
        XCTAssertEqual(opened.sheets, [sheet])
        XCTAssertEqual(opened.results, [id])
    }

    // MARK: - With the service: Stop, a lapsed question, Stop all, sleep, quit

    /// The board's Yes card offers no Stop of its own; Stop all on another
    /// errand's card stops it while it asks.
    func testStopDuringAQuestionEndsTheCardAsStoppedAndClosesTheQuestion() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let stack = makeStack()
        observe(stack, service.events, service)
        h.link.connect()
        let id = service.start(goal: "Send the form", origin: chat).id!
        let waiting = service.start(goal: "Find shops", origin: chat).id!
        let run = await h.runner(for: id)
        run?.say(.working(title: "Form", done: 0, wanted: nil))
        let request = question()
        let asked = run!.ask(request)
        await h.until({ self.card(stack, id)?.question == request }, "the question on the card")
        stack.press(.stop, on: id)
        XCTAssertFalse(asked.isAnswered, "the Yes card has no Stop button")

        stack.press(.stopAll, on: waiting)
        await h.until({ asked.isAnswered }, "the question closed")
        XCTAssertNil(asked.answer, "Stop is No")
        XCTAssertEqual(card(stack, id)?.label, "Stopped")
        XCTAssertNil(card(stack, id)?.question)
        XCTAssertFalse(service.answer(id, to: request, .yes), "nothing is left to answer")
    }

    func testAYesAfterTheWindowChangesNothing() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let stack = makeStack()
        observe(stack, service.events, service)
        h.link.connect()
        let id = service.start(goal: "Send the form", origin: chat).id!
        let run = await h.runner(for: id)
        run?.say(.working(title: "Form", done: 0, wanted: nil))
        let request = question()
        let asked = run!.ask(request)
        await h.until({ self.card(stack, id)?.question == request }, "the question on the card")
        let shown = card(stack, id)

        h.fireFirstTimer(after: .seconds(ConfirmationRequest.answerWindow))
        await h.until({ asked.isAnswered }, "silence")
        XCTAssertNil(asked.answer, "silence is No")
        XCTAssertEqual(card(stack, id)?.label, "Working", "the card shows the work again once the service says so")
        // A click on the card as it was, after the window.
        XCTAssertEqual(shown?.question, request)
        stack.press(.yes, on: id)
        XCTAssertFalse(service.answer(id, to: request, .yes))
        XCTAssertEqual(card(stack, id)?.label, "Working")
    }

    /// Five cards — one ended, one running, three waiting — and Stop all ends
    /// every errand that was still running or waiting.
    func testStopAllEndsEveryCard() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let service = h.makeService()
        let stack = makeStack()
        observe(stack, service.events, service)
        h.link.connect()
        let ended = service.start(goal: "Errand 0", origin: chat).id!
        await h.runner(for: ended)?.finish(ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))
        await h.until({ self.card(stack, ended)?.hasEnded == true }, "the first errand's end")
        let ids = (1...4).map { service.start(goal: "Errand \($0)", origin: chat).id! }
        await h.until({ stack.cards.count == 5 }, "five cards")
        XCTAssertEqual(stack.cards.map(\.id), [ended] + ids, "the ended one, the running one, then the line")
        XCTAssertEqual(stack.cards.filter { !$0.hasEnded }.count, 4)

        stack.press(.stopAll, on: ids[0])
        await h.until({ stack.cards.allSatisfy(\.hasEnded) }, "every card ended")
        XCTAssertEqual(ids.compactMap { card(stack, $0)?.label }, ["Stopped", "Stopped", "Stopped", "Stopped"])
        XCTAssertEqual(ids.dropFirst().compactMap { card(stack, $0)?.title },
                       Array(repeating: "Not started: all errands were stopped.", count: 3))
    }

    func testTheMacSleepingOrTheAppQuittingEndsTheCardAsStopped() async {
        for quit in [false, true] {
            let h = AgentServiceHarness()
            let service = h.makeService()
            let stack = makeStack()
            observe(stack, service.events, service)
            h.link.connect()
            let running = service.start(goal: "Errand 1", origin: chat).id!
            let waiting = service.start(goal: "Errand 2", origin: chat).id!
            _ = await h.runner(for: running)
            if quit { service.appWillQuit() } else { h.macWillSleep() }
            await h.until({ stack.cards.allSatisfy(\.hasEnded) }, "the cards ended")
            XCTAssertEqual(card(stack, running)?.label, "Stopped")
            XCTAssertEqual(card(stack, waiting)?.title,
                           quit ? "Not started: MetaWhisp quit." : "Not started: the Mac went to sleep.")
            h.cleanUp()
        }
    }

    /// Cards live in memory only: a relaunched app — a new service over the
    /// same saved records, and a new stack — shows none.
    func testARelaunchShowsNoStaleCard() async {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let before = h.makeService()
        let old = makeStack()
        observe(old, before.events, before)
        h.link.connect()
        let id = before.start(goal: "Errand", origin: chat).id!
        _ = await h.runner(for: id)
        before.appWillQuit()
        await h.until({ self.card(old, id)?.hasEnded == true }, "the end before the quit")
        XCTAssertNotNil(h.saved(id), "the record is on disk")

        let after = h.makeService()
        let fresh = makeStack()
        observe(fresh, after.events, after)
        XCTAssertTrue(fresh.cards.isEmpty)
    }

    // MARK: - The card's answer reaches the errand (ITER-076 stage 2, № 242)

    /// A Yes or a No pressed on the card reaches the errand's run as that
    /// answer, through the service.
    func testAYesOrANoFromTheCardReachesTheErrand() async {
        for answer in [ConfirmationRequest.Answer.yes, .no] {
            let h = AgentServiceHarness()
            let service = h.makeService()
            let stack = makeStack()
            observe(stack, service.events, service)
            h.link.connect()
            let id = service.start(goal: "Send the form", origin: chat).id!
            let run = await h.runner(for: id)
            let request = question()
            let asked = run!.ask(request)
            await h.until({ self.card(stack, id)?.question == request }, "the question on the card")
            stack.press(answer == .yes ? .yes : .no, on: id)
            await h.until({ asked.isAnswered }, "the card's answer reached the run")
            XCTAssertEqual(asked.answer, answer)
            h.cleanUp()
        }
    }

    /// The first answer counts, whoever gives it — the card, or MetaChat
    /// through the same service call — and the second changes nothing.
    func testTheFirstAnswerCountsFromTheCardOrMetaChat() async {
        for cardFirst in [true, false] {
            let h = AgentServiceHarness()
            let service = h.makeService()
            let stack = makeStack()
            observe(stack, service.events, service)
            h.link.connect()
            let id = service.start(goal: "Send the form", origin: chat).id!
            let run = await h.runner(for: id)
            let request = question()
            let asked = run!.ask(request)
            await h.until({ self.card(stack, id)?.question == request }, "the question on the card")
            if cardFirst {
                stack.press(.no, on: id)
                XCTAssertFalse(service.answer(id, to: request, .yes), "MetaChat's Yes after the card's No")
            } else {
                XCTAssertTrue(service.answer(id, to: request, .no), "MetaChat's No first")
                stack.press(.yes, on: id)
            }
            await h.until({ asked.isAnswered }, "the first answer reached the run")
            XCTAssertEqual(asked.answer, .no, cardFirst ? "the card's No" : "MetaChat's No")
            XCTAssertFalse(service.answer(id, to: request, .yes), "nothing is left to answer")
            h.cleanUp()
        }
    }

    // MARK: - Closing

    func testOnlyAnEndedCardClosesAndItClosesByItselfAsANotificationDoes() {
        XCTAssertEqual(ErrandCardStack.endedLifetime, MWNotificationStack.toastLifetimeForTests)
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), RecordingService())
        let id = UUID()
        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Shops", done: 1, wanted: 4)))
        stack.close(id)
        XCTAssertNotNil(card(stack, id), "a running errand's card cannot be closed")
        XCTAssertTrue(timers.isEmpty)

        events.send(ErrandUpdate(id: id, origin: chat, event: .finished(ErrandOutcome(
            ending: .done, answer: nil, sources: [], sheet: nil, rows: 4))))
        XCTAssertEqual(timers.map(\.seconds), [ErrandCardStack.endedLifetime])
        fireTimers()
        XCTAssertNil(card(stack, id), "closed by itself")

        let other = UUID()
        events.send(ErrandUpdate(id: other, origin: chat, event: .finished(ErrandOutcome(
            ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))))
        stack.close(other)
        XCTAssertNil(card(stack, other), "closed by the user")
        fireTimers()
        XCTAssertTrue(stack.cards.isEmpty)
    }

    func testHoveringKeepsAnEndedCardUntilTheCursorLeaves() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), RecordingService())
        let id = UUID()
        events.send(ErrandUpdate(id: id, origin: chat, event: .finished(ErrandOutcome(
            ending: .done, answer: nil, sources: [], sheet: nil, rows: 0))))
        stack.setHovering(true, id: id)
        fireTimers()
        XCTAssertNotNil(card(stack, id), "under the cursor it stays")
        stack.setHovering(false, id: id)
        XCTAssertEqual(timers.map(\.seconds), [ErrandCardStack.endedLifetime], "the time starts again")
        fireTimers()
        XCTAssertNil(card(stack, id))
    }

    /// A Sheet that comes after the end shows on the card that is still up;
    /// a card already closed does not come back for it.
    func testAnAmendedEndingUpdatesAnOpenCardAndNeverReopensAClosedOne() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let stack = makeStack()
        observe(stack, events.eraseToAnyPublisher(), RecordingService())
        let sheet = URL(string: "https://docs.google.com/spreadsheets/d/abc/edit")!
        let stopped = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 1)
        let (open, closed) = (UUID(), UUID())
        for id in [open, closed] {
            events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Shops", done: 1, wanted: 3)))
            events.send(ErrandUpdate(id: id, origin: chat, event: .finished(stopped)))
        }
        stack.close(closed)
        for id in [open, closed] {
            events.send(ErrandUpdate(id: id, origin: chat, event: .amended(stopped.withSheet(sheet))))
        }
        XCTAssertEqual(card(stack, open)?.sheet, sheet)
        XCTAssertEqual(card(stack, open)?.source, "Sheet · Shops")
        XCTAssertNil(card(stack, closed))
        XCTAssertEqual(stack.cards.count, 1)
    }
}
