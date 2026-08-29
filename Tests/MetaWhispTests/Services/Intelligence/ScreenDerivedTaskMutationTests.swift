import SwiftData
import XCTest
@testable import MetaWhisp

/// Screen text is an observation. It may propose; it may not decide.
///
/// Measured on the real store before this slice: 957 screen-derived tasks sat in
/// `staged` — invisible, the oldest from 21 April — while exactly 5 ever reached
/// a status the user could see. The promotion loop only advances when a slot
/// frees, and with 481 open tasks a slot never frees. So the half that did not
/// work was piling up silently, and the half that did work was reaching into
/// tasks the user had written themselves and closing them.
@MainActor
final class ScreenDerivedTaskMutationTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: TaskItem.self, ScreenContext.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// The one that reaches into the user's own work. A phrase on screen —
    /// someone else's message, a quote of an old one — was enough to mark a
    /// task the user wrote as done, with no confirmation, no receipt and no
    /// undo. The first they learn of it is the task missing.
    func testTheScreenSayingItIsDoneDoesNotCloseYourTask() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let task = TaskItem(taskDescription: "Send the deck to the team")
        context.insert(task)
        try context.save()
        let id = task.id

        let ocr = String(repeating: "the deck has been sent to the team already. ", count: 3)
        let reactor = RealtimeScreenReactor()
        reactor.configure(modelContainer: container)
        reactor.applyFulfillment(
            [.init(id: id.uuidString, evidence: "the deck has been sent to the team already")],
            sent: [.init(id: id, description: "Send the deck to the team")],
            ocr: ocr)

        let after = try ModelContext(container)
            .fetch(FetchDescriptor<TaskItem>()).first
        XCTAssertEqual(after?.completed, false,
                       "a screen observation may propose that a task is done, never decide it")
        XCTAssertNil(after?.completedAt)
    }

    /// The observation itself is not the problem and stays intact: the model is
    /// still allowed to notice. Gating the noticing instead of the mutation
    /// would throw away the signal a confirmation flow will need.
    func testTheObservationItselfIsUnchanged() {
        let id = UUID()
        let ocr = String(repeating: "the deck has been sent to the team already. ", count: 3)
        let confirmed = TaskFulfillment.confirmedIds(
            [.init(id: id.uuidString, evidence: "the deck has been sent to the team already")],
            sent: [.init(id: id, description: "Send the deck to the team")],
            ocr: ocr)
        XCTAssertEqual(confirmed, [id], "the model may still notice; it may not act")
    }
}
