import XCTest
@testable import MetaWhisp

/// ITER-053.1 — pins the unified «top apps by time» math shared by Dashboard
/// (raw capture gaps) and DailySummary (visit windows).
final class ScreenTimeAggregatorTests: XCTestCase {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    func test_rawSamples_gapAccumulation_andCap() {
        // Safari 0→60 (60s), Safari 60→120 (60s), Xcode 120→1000 (gap 880 → capped 300)
        let samples = [
            (appName: "Safari", timestamp: t(0)),
            (appName: "Safari", timestamp: t(60)),
            (appName: "Xcode", timestamp: t(120)),
            (appName: "Xcode", timestamp: t(1000)),
        ]
        let top = ScreenTimeAggregator.topApps(samples: samples)
        XCTAssertEqual(top.first?.appName, "Xcode")
        XCTAssertEqual(top.first?.seconds ?? 0, 300, accuracy: 0.1)   // capped
        XCTAssertEqual(top.last?.appName, "Safari")
        XCTAssertEqual(top.last?.seconds ?? 0, 120, accuracy: 0.1)
        // Percent sums to ~100.
        XCTAssertEqual(top.map(\.percent).reduce(0, +), 100, accuracy: 1)
    }

    func test_rawSamples_needAtLeastTwo() {
        XCTAssertTrue(ScreenTimeAggregator.topApps(samples: [(appName: "X", timestamp: t(0))]).isEmpty)
        XCTAssertTrue(ScreenTimeAggregator.topApps(samples: []).isEmpty)
    }

    func test_visits_durations_andLimit() {
        let visits = (0..<8).map { i in
            (appName: "App\(i)", startedAt: t(Double(i) * 100), endedAt: t(Double(i) * 100 + Double(i + 1) * 10))
        }
        let top = ScreenTimeAggregator.topApps(visits: visits, limit: 5)
        XCTAssertEqual(top.count, 5)
        XCTAssertEqual(top.first?.appName, "App7")   // longest visit (80s)
    }

    func test_visits_zeroOrNegativeDurations_ignored() {
        let visits = [
            (appName: "Ghost", startedAt: t(100), endedAt: t(100)),   // zero
            (appName: "Weird", startedAt: t(200), endedAt: t(150)),   // negative
            (appName: "Real", startedAt: t(0), endedAt: t(60)),
        ]
        let top = ScreenTimeAggregator.topApps(visits: visits)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top.first?.appName, "Real")
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(a) != \(b) ± \(accuracy)")
}
