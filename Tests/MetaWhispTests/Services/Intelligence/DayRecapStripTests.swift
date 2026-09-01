import XCTest
@testable import MetaWhisp

/// The day recap is the best output this app has — 105 of 130 stored recaps
/// carry a real "what you learned", 99 a real "what you decided" — and it lived
/// in a Dashboard tab and a banner that fires once. The menu bar is where a
/// menu-bar app is actually looked at, and the recap was not there at all.
///
/// This is the rule for when the menu bar offers it, kept pure so "is it worth
/// a row" can be argued with without a running app.
final class DayRecapStripTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testTodaysRecapIsOffered() {
        XCTAssertTrue(DayRecapStrip.shouldShow(
            recapDate: at("2026-09-01T09:00:00Z"),
            now: at("2026-09-01T18:00:00Z"), calendar: cal))
    }

    /// The recap for a day is generated at the end of it, so the morning after
    /// is when a person most wants yesterday. Cutting it off at midnight would
    /// hide it exactly when it is most useful.
    func testYesterdaysRecapIsStillOfferedThisMorning() {
        XCTAssertTrue(DayRecapStrip.shouldShow(
            recapDate: at("2026-08-31T22:00:00Z"),
            now: at("2026-09-01T09:00:00Z"), calendar: cal))
    }

    /// And it stops. A row that never goes away stops being read — the same
    /// failure as a notification nobody can act on, one surface over.
    func testAnOldRecapIsNotOffered() {
        XCTAssertFalse(DayRecapStrip.shouldShow(
            recapDate: at("2026-08-29T22:00:00Z"),
            now: at("2026-09-01T09:00:00Z"), calendar: cal))
    }

    func testNoRecapMeansNoRow() {
        XCTAssertFalse(DayRecapStrip.shouldShow(
            recapDate: nil, now: at("2026-09-01T09:00:00Z"), calendar: cal))
    }

    /// A recap stamped in the future is a clock that moved, not a recap from
    /// tomorrow. Show it rather than hiding the newest thing there is.
    func testAClockThatJumpedDoesNotHideTheNewestRecap() {
        XCTAssertTrue(DayRecapStrip.shouldShow(
            recapDate: at("2026-09-02T09:00:00Z"),
            now: at("2026-09-01T09:00:00Z"), calendar: cal))
    }

    /// What the row says. "4 decided · 4 learned" is the promise the recap
    /// keeps; a bare title could be an empty one.
    func testTheRowCountsWhatIsInside() {
        XCTAssertEqual(DayRecapStrip.subtitle(decided: 4, learned: 4), "4 decided · 4 learned")
        XCTAssertEqual(DayRecapStrip.subtitle(decided: 1, learned: 0), "1 decided")
        XCTAssertEqual(DayRecapStrip.subtitle(decided: 0, learned: 2), "2 learned")
        XCTAssertEqual(DayRecapStrip.subtitle(decided: 0, learned: 0), "",
                       "an empty recap must not advertise itself as full")
    }
}
