import XCTest
@testable import MetaWhisp

/// The day recap is the best output this app has — 105 of 130 stored recaps
/// carry a real "what you learned", 99 a real "what you decided" — and it lived
/// in a Dashboard tab and a banner that fires once. The menu bar is where a
/// menu-bar app is actually looked at, and the recap was not there at all.
///
/// These are the rules for offering it, kept pure so "is it worth a row" and
/// "which day does the card open on" can be argued with without a running app.
final class DayRecapStripTests: XCTestCase {

    /// Pinned to UTC: the dates below are written in UTC, and a machine in
    /// another zone would move their midnights and turn day arithmetic into a
    /// coin toss — which is exactly how the first run of this file failed.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }
    // MARK: - Which day the Dashboard opens on

    /// The review finding: the menu-bar row advertised yesterday's recap and the
    /// click opened an empty "today" placeholder. The card stands on the newest
    /// recap there is.
    func testBeforeTheScheduledHourTheCardStandsOnYesterday() {
        let anchor = DayRecapStrip.anchorDay(newestRecapDate: at("2026-08-31T00:00:00Z"),
                                             now: at("2026-09-01T09:00:00Z"), calendar: cal)
        XCTAssertEqual(anchor, cal.startOfDay(for: at("2026-08-31T00:00:00Z")))
    }

    /// Once today's recap exists, today is today.
    func testAfterTheScheduledHourTheCardStandsOnToday() {
        let anchor = DayRecapStrip.anchorDay(newestRecapDate: at("2026-09-01T00:00:00Z"),
                                             now: at("2026-09-01T22:30:00Z"), calendar: cal)
        XCTAssertEqual(anchor, cal.startOfDay(for: at("2026-09-01T22:30:00Z")))
    }

    func testWithNoRecapsTheCardStandsOnTodayAndOffersToGenerate() {
        let now = at("2026-09-01T09:00:00Z")
        XCTAssertEqual(DayRecapStrip.anchorDay(newestRecapDate: nil, now: now, calendar: cal),
                       cal.startOfDay(for: now))
    }

    /// A future-stamped recap is a moved clock; the card must not stand on a day
    /// that has not happened.
    func testAFutureRecapDoesNotPullTheCardForward() {
        let now = at("2026-09-01T09:00:00Z")
        XCTAssertEqual(DayRecapStrip.anchorDay(newestRecapDate: at("2026-09-03T00:00:00Z"),
                                               now: now, calendar: cal),
                       cal.startOfDay(for: now))
    }
}
