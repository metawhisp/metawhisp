import XCTest
@testable import MetaWhisp

/// How the hourly pass decides where one stretch of screen time ends.
///
/// It grouped by app name alone, so two browser tabs or two Slack channels
/// became one visit — and the last window's title was then attached to OCR
/// accumulated across all of them. A fact from one conversation could be
/// attributed to another, in a summary the user reads as a record of their day.
@MainActor
final class ScreenExtractorVisitGroupingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func context(_ app: String, _ title: String, at offset: TimeInterval,
                         ocr: String = "text") -> ScreenContext {
        let c = ScreenContext(appName: app, windowTitle: title, ocrText: ocr)
        c.timestamp = t0.addingTimeInterval(offset)
        return c
    }

    private func visits(_ contexts: [ScreenContext]) -> [ScreenExtractor.Visit] {
        ScreenExtractor().collapseIntoVisits(contexts)
    }

    func testOneWindowIsOneVisit() {
        let out = visits([
            context("Slack", "#launch", at: 0),
            context("Slack", "#launch", at: 30),
            context("Slack", "#launch", at: 60),
        ])
        XCTAssertEqual(out.count, 1)
    }

    /// The defect: two channels of one app were one visit, and everything said
    /// in the first got labelled with the title of the second.
    func testTwoWindowsOfOneAppAreTwoVisits() {
        let out = visits([
            context("Slack", "#launch", at: 0, ocr: "Anna: send the deck"),
            context("Slack", "#random", at: 30, ocr: "lunch?"),
        ])
        XCTAssertEqual(out.count, 2, "a different channel is a different stretch of work")
        XCTAssertEqual(out.first?.windowTitle, "#launch")
        XCTAssertTrue(out.first?.ocrPreview.contains("Anna") == true)
        XCTAssertFalse(out.first?.ocrPreview.contains("lunch") == true,
                       "text from the other window must not land in this visit")
    }

    func testDifferentAppsAreDifferentVisits() {
        let out = visits([
            context("Slack", "#launch", at: 0),
            context("Figma", "Board", at: 30),
        ])
        XCTAssertEqual(out.count, 2)
    }

    /// A clock ticking in a title is not the user going anywhere. Splitting on
    /// raw titles would shatter one afternoon into dozens of one-sample visits.
    func testCosmeticTitleChurnDoesNotShatterAVisit() {
        let out = visits([
            context("Toggl", "Toggl 00:05:23 work", at: 0),
            context("Toggl", "Toggl 00:05:53 work", at: 30),
            context("Toggl", "Toggl 00:06:23 work", at: 60),
        ])
        XCTAssertEqual(out.count, 1, "a ticking timer is the same window")
    }

    /// Coming back after a long break is a new stretch of work, not the
    /// morning's continuing.
    func testALongGapEndsTheVisit() {
        let out = visits([
            context("Slack", "#launch", at: 0),
            context("Slack", "#launch", at: 3600),
        ])
        XCTAssertEqual(out.count, 2)
    }

    func testAnEmptyBatchProducesNothing() {
        XCTAssertTrue(visits([]).isEmpty)
    }

    /// Timing has to survive grouping: a summary that says how long something
    /// took is only worth reading if the boundaries are right.
    func testVisitBoundsSpanItsOwnSamplesOnly() {
        let out = visits([
            context("Slack", "#launch", at: 0),
            context("Slack", "#launch", at: 60),
            context("Slack", "#random", at: 120),
        ])
        XCTAssertEqual(out.first?.startedAt, t0)
        XCTAssertEqual(out.first?.endedAt, t0.addingTimeInterval(60))
        XCTAssertEqual(out.last?.startedAt, t0.addingTimeInterval(120))
    }
}
