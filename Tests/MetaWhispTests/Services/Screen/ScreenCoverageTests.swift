import XCTest
@testable import MetaWhisp

/// ITER-071 §6 — an answer about the day may never present a few observed
/// minutes as the whole afternoon. These pin what "honest about what I did not
/// see" means before any prose is generated from it.
final class ScreenCoverageTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }

    func testAnUnwatchedPeriodIsOneWholeGap() {
        let report = ScreenCoverage.report(from: noon, to: at(120), samples: [])
        XCTAssertEqual(report.gaps, [.init(from: noon, to: at(120))])
        XCTAssertEqual(report.observedFraction, 0)
    }

    func testAGapInTheMiddleIsNamed() {
        // Watched 12:00–12:10, nothing until 13:00, watched again to 13:10.
        let samples = stride(from: 0.5, through: 10, by: 0.5).map(at)
            + stride(from: 60.5, through: 70, by: 0.5).map(at)
        let report = ScreenCoverage.report(from: noon, to: at(70), samples: samples)
        XCTAssertEqual(report.gaps.count, 1)
        XCTAssertEqual(report.gaps.first?.from, at(10))
        XCTAssertEqual(report.gaps.first?.to, at(60))
    }

    func testAShortPauseIsNotAGap() {
        // A minute between samples is someone reading, not a hole in the record.
        let samples = [at(1), at(2), at(3.5), at(5)]
        let report = ScreenCoverage.report(from: noon, to: at(5), samples: samples)
        XCTAssertTrue(report.gaps.isEmpty)
    }

    func testASampleStandsForItsCadenceNotAnInstant() {
        // Twenty samples across ten minutes at a 30s cadence cover the period;
        // treating each as an instant would report ~0% and call a working
        // stretch unobserved.
        let samples = stride(from: 0.5, through: 10, by: 0.5).map(at)
        let report = ScreenCoverage.report(from: noon, to: at(10), samples: samples)
        XCTAssertGreaterThan(report.observedFraction, 0.9)
    }

    func testTheLineNamesTheGapsAndForbidsClaimingFullCoverage() {
        let samples = stride(from: 0.5, through: 10, by: 0.5).map(at)
        let report = ScreenCoverage.report(from: noon, to: at(70), samples: samples)
        let line = ScreenCoverage.honestyLine(report, captureEnabled: true)
        XCTAssertTrue(line.contains("COVERAGE"))
        XCTAssertTrue(line.lowercased().contains("never present the period as fully seen"))
        XCTAssertFalse(line.isEmpty)
    }

    func testCaptureOffSaysNothingWasObserved() {
        let report = ScreenCoverage.report(from: noon, to: at(120), samples: [])
        let line = ScreenCoverage.honestyLine(report, captureEnabled: false)
        XCTAssertTrue(line.lowercased().contains("off"))
        XCTAssertTrue(line.lowercased().contains("nothing in this period was observed"))
    }

    func testAContinuousRecordSaysSoRatherThanInventingAGap() {
        let samples = stride(from: 0.5, through: 30, by: 0.5).map(at)
        let report = ScreenCoverage.report(from: noon, to: at(30), samples: samples)
        XCTAssertTrue(report.gaps.isEmpty)
        XCTAssertTrue(ScreenCoverage.honestyLine(report, captureEnabled: true)
            .contains("continuous"))
    }
}
