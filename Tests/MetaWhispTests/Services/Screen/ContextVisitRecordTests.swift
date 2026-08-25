import SwiftData
import XCTest
@testable import MetaWhisp

/// Visit-wiring step 4 — the durable visit table: upsert semantics, crash
/// reconciliation, and the frame-ID bound.
@MainActor
final class ContextVisitRecordTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ContextVisitRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func visit(id: UUID = UUID(), generation: Int = 0,
                       bundle: String = "com.apple.mail", app: String = "Mail",
                       title: String = "Inbox") -> ContextVisit {
        ContextVisit(id: id, generation: generation, bundleID: bundle, appName: app,
                     normalizedTitle: title.lowercased(), rawTitle: title,
                     windowID: nil, displayID: nil, startedAt: Date())
    }

    func testAnOpenedProposalClosesThePreviousVisitAsAContextSwitch() throws {
        let ctx = try makeContext()
        let first = visit(title: "Inbox")
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(first), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx)
        try ctx.save()

        let second = visit(bundle: "com.apple.Safari", app: "Safari", title: "Docs")
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(second), acceptedContextID: UUID(),
            captureState: "captured", token: 2, in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<ContextVisitRecord>())
        XCTAssertEqual(rows.count, 2)
        let closed = rows.first { $0.id == first.id }
        XCTAssertNotNil(closed?.endedAt)
        XCTAssertEqual(closed?.invalidationReason, "context_switch")
        XCTAssertNil(rows.first { $0.id == second.id }?.endedAt)
    }

    func testTheSameWindowReopeningReadsAsGapExpiry() throws {
        let ctx = try makeContext()
        let first = visit(title: "Inbox")
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(first), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx)
        // >300s later the coordinator opens a NEW visit for the same window.
        let again = visit(title: "Inbox")
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(again), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx)
        try ctx.save()

        XCTAssertEqual(
            try ctx.fetch(FetchDescriptor<ContextVisitRecord>())
                .first { $0.id == first.id }?.invalidationReason,
            "gap_expired")
    }

    func testAChangedProposalBumpsTheRowInPlace() throws {
        let ctx = try makeContext()
        let v = visit(title: "Inbox")
        let frame1 = UUID(), frame2 = UUID()
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(v), acceptedContextID: frame1,
            captureState: "captured", token: 1, in: ctx)
        let changed = ContextVisit(
            id: v.id, generation: 1, bundleID: v.bundleID, appName: v.appName,
            normalizedTitle: "inbox 3 unread", rawTitle: "Inbox — 3 unread",
            windowID: nil, displayID: nil, startedAt: v.startedAt)
        ScreenContextService.upsertVisitRecord(
            proposal: .changed(changed), acceptedContextID: frame2,
            captureState: "captured", token: 2, in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<ContextVisitRecord>())
        XCTAssertEqual(rows.count, 1, "a changed visit is the same row, not a new one")
        XCTAssertEqual(rows.first?.generation, 1)
        XCTAssertEqual(rows.first?.frameIDs, [frame1, frame2])
        XCTAssertEqual(rows.first?.latestContentHash, 2)
        XCTAssertNil(rows.first?.endedAt)
    }

    func testStartupReconcileClosesWhatACrashLeftOpen() throws {
        let ctx = try makeContext()
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(visit()), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx)
        try ctx.save()

        ScreenContextService.reconcileOpenVisits(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<ContextVisitRecord>())
        XCTAssertNotNil(rows.first?.endedAt)
        XCTAssertEqual(rows.first?.invalidationReason, "startup_reconcile")
    }

    /// The mark can accept what the coordinator calls unchanged (spinner
    /// glyph in the title, identical content). The row still belongs to the
    /// ongoing visit and must not go unstamped.
    func testAnUnchangedProposalStillStampsTheOngoingVisit() throws {
        let ctx = try makeContext()
        let v = visit(title: "Inbox")
        let frame1 = UUID(), frame2 = UUID()
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(v), acceptedContextID: frame1,
            captureState: "captured", token: 1, in: ctx)
        ScreenContextService.upsertVisitRecord(
            proposal: .unchanged, currentVisit: v, acceptedContextID: frame2,
            captureState: "captured", token: 1, in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<ContextVisitRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.frameIDs, [frame1, frame2],
                       "the unchanged frame still belongs to this visit")
        XCTAssertEqual(rows.first?.latestScreenContextID, frame2)
        XCTAssertEqual(rows.first?.generation, 0, "unchanged must not bump the generation")
    }

    /// The guarantee the retired mark used to hold: a visit ends when it was
    /// last SEEN. Closing at the moment the next visit opens hands the earlier
    /// app every hour the app was not even running.
    func testAGapClosesThePreviousVisitAtItsLastObservationNotAtReopen() throws {
        let ctx = try makeContext()
        let noon = Date(timeIntervalSince1970: 1_800_000_000)
        let first = visit(title: "Inbox")
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(first), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx, now: noon)

        // Two hours later the app comes back to the same window.
        let twoPM = noon.addingTimeInterval(7200)
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(visit(title: "Inbox")), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx, now: twoPM)
        try ctx.save()

        let closed = try XCTUnwrap(ctx.fetch(FetchDescriptor<ContextVisitRecord>())
            .first { $0.id == first.id })
        XCTAssertEqual(closed.invalidationReason, "gap_expired")
        XCTAssertEqual(closed.endedAt, noon,
                       "the visit must not be credited with the two hours nobody was watching")
    }

    /// A real switch is different: the previous window was current until the
    /// moment the user left it.
    func testASwitchClosesThePreviousVisitAtTheSwitchMoment() throws {
        let ctx = try makeContext()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = visit(title: "Inbox")
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(first), acceptedContextID: UUID(),
            captureState: "captured", token: 1, in: ctx, now: t0)
        let later = t0.addingTimeInterval(120)
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(visit(bundle: "com.apple.Safari", app: "Safari", title: "Docs")),
            acceptedContextID: UUID(), captureState: "captured", token: 2, in: ctx, now: later)
        try ctx.save()

        let closed = try XCTUnwrap(ctx.fetch(FetchDescriptor<ContextVisitRecord>())
            .first { $0.id == first.id })
        XCTAssertEqual(closed.invalidationReason, "context_switch")
        XCTAssertEqual(closed.endedAt, later)
    }

    func testFrameIDsAreBounded() throws {
        let ctx = try makeContext()
        let v = visit()
        ScreenContextService.upsertVisitRecord(
            proposal: .opened(v), acceptedContextID: UUID(),
            captureState: "captured", token: 0, in: ctx)
        let row = try XCTUnwrap(ctx.fetch(FetchDescriptor<ContextVisitRecord>()).first)
        for _ in 0 ..< (ContextVisitRecord.maxFrameIDs + 10) {
            row.appendFrameID(UUID())
        }
        XCTAssertEqual(row.frameIDs.count, ContextVisitRecord.maxFrameIDs,
                       "the frame list is a bounded window, not an unbounded log")
    }
}
