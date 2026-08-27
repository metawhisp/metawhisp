import XCTest
import SwiftData
@testable import MetaWhisp

/// The claims that started this: «zero vision calls in a day» and «the cheap
/// gate is filtering». Both were made from a grep over a log this shell cannot
/// read, so both were an empty result mistaken for a measurement. These pin the
/// numbers to a place that can actually be queried.
@MainActor
final class ScreenAgentMetricsTests: XCTestCase {

    private func makeService() throws -> (ScreenAgentDeliveryService, ModelContainer) {
        let container = try ModelContainer(
            for: ScreenAgentItem.self, ScreenAgentRun.self,
            ScreenAgentDeliveryRecord.self, ScreenAgentRunMetrics.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (ScreenAgentDeliveryService(container: container), container)
    }

    /// A skipped run is the cheapest one there is and the one worth counting:
    /// the gate's whole reason to exist is the ratio of these to the rest.
    func testAGateSkipIsRecordedEvenThoughTheRunProducedNothing() throws {
        let (service, container) = try makeService()
        let runID = UUID()
        var tally = ScreenAgentRunMetrics.Tally()
        tally.gateOutcome = .skipped
        tally.gateScore = 0.21
        tally.gateMilliseconds = 180
        service.recordMetrics(runID: runID, tally: tally)

        let row = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ScreenAgentRunMetrics>()).first)
        XCTAssertEqual(row.gateOutcome, "skipped")
        XCTAssertEqual(row.gateScore, 0.21, accuracy: 0.0001)
        XCTAssertEqual(row.textModelCallCount, 0, "a skipped run must not look like it spent")
    }

    /// A gate that errors answers "fire" so real signals are not dropped. That
    /// is correct and it is also indistinguishable from a gate passing
    /// everything — unless the difference is recorded, which is the point.
    func testFailingOpenIsNotTheSameAsDecidingToFire() throws {
        let (service, container) = try makeService()
        var failed = ScreenAgentRunMetrics.Tally()
        failed.gateOutcome = .failedOpen
        var fired = ScreenAgentRunMetrics.Tally()
        fired.gateOutcome = .fired
        service.recordMetrics(runID: UUID(), tally: failed)
        service.recordMetrics(runID: UUID(), tally: fired)

        let outcomes = try ModelContext(container)
            .fetch(FetchDescriptor<ScreenAgentRunMetrics>()).map(\.gateOutcome)
        XCTAssertEqual(Set(outcomes), ["failedOpen", "fired"])
    }

    /// A retried run must not double its own totals.
    func testMeasuringTheSameRunTwiceKeepsOneRow() throws {
        let (service, container) = try makeService()
        let runID = UUID()
        var first = ScreenAgentRunMetrics.Tally()
        first.gateOutcome = .fired
        first.textModelCallCount = 1
        service.recordMetrics(runID: runID, tally: first)

        var second = first
        second.textModelCallCount = 3
        second.toolTurnCount = 3
        service.recordMetrics(runID: runID, tally: second)

        let rows = try ModelContext(container).fetch(FetchDescriptor<ScreenAgentRunMetrics>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.textModelCallCount, 3, "the later measurement wins")
    }

    /// Cost stays zero until the proxy reports usage. Zero has to mean NOT
    /// MEASURED — filling it with an estimate would be the original mistake
    /// wearing a database for a disguise.
    func testCostIsZeroBecauseNobodyHasMeasuredItYet() throws {
        let (service, container) = try makeService()
        var tally = ScreenAgentRunMetrics.Tally()
        tally.gateOutcome = .fired
        tally.textModelCallCount = 2
        service.recordMetrics(runID: UUID(), tally: tally)

        let row = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ScreenAgentRunMetrics>()).first)
        XCTAssertEqual(row.promptTokenCount, 0)
        XCTAssertEqual(row.completionTokenCount, 0)
        XCTAssertEqual(row.costMicroUSD, 0)
    }

    /// The metrics row carries counts and outcomes only. If the screen's text
    /// could reach it, "what did the agent do today" would mean reading what
    /// the user had open.
    /// Checked by TYPE, not by name: a name can be renamed into innocence,
    /// whereas free text needs a `String` to travel in. The single permitted
    /// one is `gateOutcome`, whose values are a closed four-word vocabulary.
    func testTheMetricsRowHasNowhereForScreenTextToTravel() {
        let entity = Schema([ScreenAgentRunMetrics.self]).entities
            .first { $0.name == "ScreenAgentRunMetrics" }
        let attributes: Set<Schema.Attribute> = entity?.attributes ?? []
        XCTAssertFalse(attributes.isEmpty, "the entity must exist")

        let stringy = attributes.filter { $0.valueType == String.self }.map { $0.name }.sorted()
        XCTAssertEqual(stringy, ["gateOutcome"],
                       "only the gate's closed vocabulary may be text; everything else "
                       + "is a count, a duration or an identifier")

        let vocabulary = Set(["notRun", "fired", "skipped", "failedOpen"])
        XCTAssertEqual(
            Set(ScreenAgentRunMetrics.Gate.allCasesForTests.map(\.rawValue)), vocabulary)
    }
}
