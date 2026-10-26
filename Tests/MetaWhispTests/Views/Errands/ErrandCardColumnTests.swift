import AppKit
import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 I-11 — the errand cards sit top-right, where the notification
/// cards appear, in the same column and the same panel: two surfaces in one
/// corner that do not know of each other collide (ITER-026). The panel never
/// takes focus and shows on every Space, a full-screen one included.
@MainActor
final class ErrandCardColumnTests: XCTestCase {

    private let chat = ErrandOrigin.chat(messageID: UUID())

    func testAColumnThatFitsKeepsItsGaps() {
        let column = MWNotificationStackController.column(heights: [100, 80, 60], available: 2_000)
        XCTAssertEqual(column.tops, [34, 142, 230], "34 pt for the shadow, then 8 pt between cards")
        XCTAssertEqual(column.height, 34 + 100 + 8 + 80 + 8 + 60 + 34)
    }

    /// One running errand, three waiting, one ended and two notifications on
    /// a small screen (1280 × 800, less the menu bar): every card stays on
    /// it, in order, each one's badge row in sight.
    func testSevenCardsStayWithinASmallScreen() {
        func height(_ events: ErrandEvent...) -> CGFloat {
            ErrandCardView(card: events.reduce(ErrandCard(id: UUID())) { $0.showing($1) },
                           onPress: { _ in }, onClose: {}, onHover: { _ in }).measuredHeight
        }
        let notification = MWNotificationCardView(
            notification: MWNotification(kind: .task, title: "Task added", body: "Call the bank about the card"),
            onClose: {}, onTap: nil, onHover: { _ in }).measuredHeight
        let heights = [height(.working(title: "Shops", done: 3, wanted: 10)),
                       height(.queued(position: 1)), height(.queued(position: 2)), height(.queued(position: 3)),
                       height(.working(title: "Cafes", done: 2, wanted: 2), .finished(ErrandOutcome(
                           ending: .done, answer: nil, sources: [], sheet: URL(string: "https://sheets.test/1"), rows: 2))),
                       notification, notification]
        let available: CGFloat = 800 - 25
        let column = MWNotificationStackController.column(heights: heights, available: available)
        XCTAssertLessThanOrEqual(column.height, available)
        XCTAssertEqual(column.tops.first, 34)
        for (index, top) in column.tops.enumerated().dropFirst() {
            XCTAssertGreaterThanOrEqual(top - column.tops[index - 1], 52, "card \(index) hides the badge row above it")
        }
        XCTAssertEqual(column.tops.count, heights.count)
        XCTAssertLessThanOrEqual((column.tops.last ?? .infinity) + heights[heights.count - 1], column.height - 34)
    }

    func testErrandCardsSitAboveTheNotificationsInOnePanelThatNeverTakesFocus() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let errands = ErrandCardStack(schedule: { _, _ in })
        var stopped: [UUID] = []
        errands.observe(events.eraseToAnyPublisher(), service: StopRecorder { stopped.append($0) },
                        openSheet: { _ in }, openResult: { _ in })
        let (running, waiting) = (UUID(), UUID())
        events.send(ErrandUpdate(id: running, origin: chat, event: .working(title: "Shops", done: 1, wanted: 4)))
        events.send(ErrandUpdate(id: waiting, origin: chat, event: .queued(position: 1)))
        let notification = MWNotification(kind: .task, title: "Task added", body: "Call back")
        let controller = MWNotificationStackController(errands: errands)
        defer { controller.render(items: [], errands: []) }

        controller.render(items: [notification], errands: errands.cards)
        let panel = try? XCTUnwrap(controller.panel)
        let shown = panel?.contentView?.subviews ?? []
        let cards = shown.compactMap { $0 as? ErrandCardView }.sorted { $0.frame.maxY > $1.frame.maxY }
        let notes = shown.compactMap { $0 as? MWNotificationCardView }
        XCTAssertEqual(cards.map(\.card.id), [running, waiting], "the running errand on top, then the line")
        XCTAssertEqual(notes.count, 1)
        for card in cards {
            for note in notes {
                XCTAssertGreaterThan(card.frame.minY, note.frame.maxY, "errand cards above the notifications")
            }
        }

        XCTAssertEqual(panel?.collectionBehavior, MWWindowBehavior.overlay)
        XCTAssertTrue(panel?.collectionBehavior.contains(.fullScreenAuxiliary) ?? false,
                      "on a full-screen app's Space, not a jump to another one")
        XCTAssertTrue(panel?.collectionBehavior.contains(.canJoinAllSpaces) ?? false)
        XCTAssertTrue(panel?.styleMask.contains(.nonactivatingPanel) ?? false, "a click does not activate MetaWhisp")
        XCTAssertEqual(panel?.canBecomeKey, false, "the user's window keeps the keyboard")
        XCTAssertEqual(panel?.canBecomeMain, false)

        // A button clicked in the panel acts, and the panel never becomes key.
        guard let top = cards.first else { return XCTFail("no errand card in the panel") }
        top.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Stop" }?.performClick(nil)
        XCTAssertEqual(stopped, [running])
        XCTAssertEqual(panel?.isKeyWindow, false)
    }

    /// A running errand's card is the same card from event to event: it
    /// updates in place, it is never replaced by a new one.
    func testAnErrandsCardIsUpdatedInPlace() {
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let errands = ErrandCardStack(schedule: { _, _ in })
        errands.observe(events.eraseToAnyPublisher(), service: StopRecorder { _ in }, openSheet: { _ in },
                        openResult: { _ in })
        let id = UUID()
        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Shops", done: 1, wanted: 4)))
        let controller = MWNotificationStackController(errands: errands)
        defer { controller.render(items: [], errands: []) }
        controller.render(items: [], errands: errands.cards)
        let shown = { controller.panel?.contentView?.subviews.compactMap { $0 as? ErrandCardView } ?? [] }
        let first = shown().first
        events.send(ErrandUpdate(id: id, origin: chat, event: .working(title: "Shops", done: 2, wanted: 4)))
        controller.render(items: [], errands: errands.cards)
        XCTAssertEqual(shown().count, 1)
        XCTAssertTrue(shown().first === first, "the same card, updated")
        XCTAssertEqual(first?.card.title, "Shops — 2 of 4")
    }

    /// An errand card keeps the panel up with no notification, and the
    /// panel goes once both are gone.
    func testThePanelGoesOnlyWhenBothAreEmpty() {
        let errands = ErrandCardStack(schedule: { _, _ in })
        let events = PassthroughSubject<ErrandUpdate, Never>()
        errands.observe(events.eraseToAnyPublisher(), service: StopRecorder { _ in }, openSheet: { _ in },
                        openResult: { _ in })
        events.send(ErrandUpdate(id: UUID(), origin: chat, event: .queued(position: 1)))
        let controller = MWNotificationStackController(errands: errands)
        controller.render(items: [], errands: errands.cards)
        XCTAssertEqual(controller.panel?.isVisible, true)
        controller.render(items: [], errands: [])
        XCTAssertEqual(controller.panel?.isVisible, false)
    }

    /// Review round 3, R3-4: on a screen 800 pt high, a form's question of
    /// eight fields, one a message of 2,000 characters, keeps its Fill and No
    /// on the screen: the rows take the room the screen leaves and scroll
    /// inside the card, every value whole in them.
    func testAFormsButtonsStayOnASmallScreenAndItsRowsScroll() throws {
        let screen = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let errands = ErrandCardStack(schedule: { _, _ in })
        errands.observe(events.eraseToAnyPublisher(), service: StopRecorder { _ in }, openSheet: { _ in },
                        openResult: { _ in })
        events.send(ErrandUpdate(id: UUID(), origin: chat, event: .needsYes(Self.longForm())))
        let controller = MWNotificationStackController(errands: errands, screen: { screen })
        defer { controller.render(items: [], errands: []) }
        controller.render(items: [], errands: errands.cards)
        let panel = try XCTUnwrap(controller.panel)
        let card = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? ErrandCardView }.first)
        let buttons = card.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && !$0.title.isEmpty }
        XCTAssertEqual(buttons.map(\.title).sorted(), ["Fill", "No"])
        for button in buttons {
            let onScreen = panel.convertToScreen(card.convert(button.frame, to: nil))
            XCTAssertTrue(screen.contains(onScreen), "\(button.title) at \(onScreen) is off the screen")
        }
        let scroll = try XCTUnwrap(card.subviews.compactMap { $0 as? NSScrollView }.first, "no rows that scroll")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height, "the rows scroll")
        let rows = document.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(rows.count, 8)
        let message = try XCTUnwrap(rows.first { $0.stringValue.hasPrefix("Message — ") })
        let probe = NSTextField(wrappingLabelWithString: message.stringValue)
        probe.font = message.font
        probe.maximumNumberOfLines = 0
        let whole = probe.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: message.frame.width, height: 100_000))
            .height ?? .greatestFiniteMagnitude
        XCTAssertGreaterThanOrEqual(message.frame.height + 0.5, whole, "every line of the message is in the rows")
    }

    /// Review round 3, R3-4: the screen the column stands on gets smaller
    /// while a form's question is shown — another display, say: the card
    /// takes the room the smaller screen leaves, and its Fill and No stay on
    /// it.
    func testAFormsButtonsStayOnTheScreenWhenItGetsSmaller() throws {
        var screen = NSRect(x: 0, y: 0, width: 1280, height: 2_400)
        let events = PassthroughSubject<ErrandUpdate, Never>()
        let errands = ErrandCardStack(schedule: { _, _ in })
        errands.observe(events.eraseToAnyPublisher(), service: StopRecorder { _ in }, openSheet: { _ in },
                        openResult: { _ in })
        events.send(ErrandUpdate(id: UUID(), origin: chat, event: .needsYes(Self.longForm())))
        let controller = MWNotificationStackController(errands: errands, screen: { screen })
        defer { controller.render(items: [], errands: []) }
        controller.render(items: [], errands: errands.cards)
        screen = NSRect(x: 0, y: 0, width: 1280, height: 800)
        controller.render(items: [], errands: errands.cards)
        let panel = try XCTUnwrap(controller.panel)
        let card = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? ErrandCardView }.first)
        let buttons = card.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && !$0.title.isEmpty }
        XCTAssertEqual(buttons.map(\.title).sorted(), ["Fill", "No"])
        for button in buttons {
            let onScreen = panel.convertToScreen(card.convert(button.frame, to: nil))
            XCTAssertTrue(screen.contains(onScreen), "\(button.title) at \(onScreen) is off the screen")
        }
    }

    /// A form's Fill question of eight fields, one a message of 2,000
    /// characters.
    private static func longForm() -> ConfirmationRequest {
        let send = ObservedElement(index: 0, role: "button", name: "Send", text: "Send", href: nil, inputType: nil,
                                   heading: nil, region: .main, inViewport: true, context: nil,
                                   formAction: "https://example.com/contact", formMethod: "post",
                                   formSubmitLabel: "Send", options: nil, checked: nil, submits: true)
        var request = ConfirmationRequest(action: AgentAction(operation: .type, target: send, destination: nil,
                                                              payload: nil, isPlannedSearch: false),
                                          tab: BrowserTab(windowID: "1", tabID: "2"),
                                          pageURL: "https://example.com/contact", askedAt: .now)
        let message = String(String(repeating: "We would like a demo for our team of twelve. ", count: 50).prefix(2_000))
        let rows = (1...7).map { FormRow(label: "Field \($0)", shown: .value("Value \($0)", .memories, unsure: false)) }
            + [FormRow(label: "Message", shown: .value(message, .request, unsure: false))]
        request.form = FormQuestion(kind: .fill, host: "example.com", destination: nil, rows: rows)
        return request
    }

    private final class StopRecorder: ErrandCardService {
        let stopped: (UUID) -> Void
        init(_ stopped: @escaping (UUID) -> Void) { self.stopped = stopped }
        func stop(_ id: UUID) { stopped(id) }
        func stopAll() {}
        func answer(_ id: UUID, to request: ConfirmationRequest, _ answer: ConfirmationRequest.Answer) -> Bool { false }
        func proceed(_ id: UUID, after pause: ErrandPause) -> Bool { false }
        func showTab(_ id: UUID) -> Bool { false }
    }
}
