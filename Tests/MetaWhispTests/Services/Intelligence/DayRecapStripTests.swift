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
    private func show(_ recap: String?, read: Bool = false, now: String) -> Bool {
        DayRecapStrip.shouldShow(recapDate: recap.map(at), isRead: read, now: at(now), calendar: cal)
    }

    func testTodaysRecapIsOffered() {
        XCTAssertTrue(show("2026-09-01T09:00:00Z", now: "2026-09-01T18:00:00Z"))
    }

    /// The recap for a day is generated at the end of it, so the morning after
    /// is when a person most wants yesterday. Cutting it off at midnight would
    /// hide it exactly when it is most useful.
    func testYesterdaysRecapIsStillOfferedThisMorning() {
        XCTAssertTrue(show("2026-08-31T22:00:00Z", now: "2026-09-01T09:00:00Z"))
    }

    /// The gate's first release: it was opened. A read recap two days old is
    /// done with.
    func testAReadRecapStopsBeingOfferedAfterADay() {
        XCTAssertFalse(show("2026-08-29T22:00:00Z", read: true, now: "2026-09-01T09:00:00Z"))
    }

    /// The finding this rule was rewritten for: one missed generation
    /// (2026-08-08 has no row in the store) left the menu bar empty the next
    /// morning while an unread recap sat there. A gate with age as its only
    /// release starves — an unread recap stays offered past the day.
    func testAnUnreadRecapStaysOfferedPastTheDay() {
        XCTAssertTrue(show("2026-08-29T22:00:00Z", read: false, now: "2026-09-01T09:00:00Z"),
                      "unread and three days old is still worth a row")
    }

    /// And the second release: a row that never goes away stops being read.
    func testAnUnreadRecapIsLetGoAfterAWeek() {
        XCTAssertTrue(show("2026-08-25T22:00:00Z", read: false, now: "2026-09-01T09:00:00Z"))
        XCTAssertFalse(show("2026-08-24T22:00:00Z", read: false, now: "2026-09-01T09:00:00Z"))
    }

    func testNoRecapMeansNoRow() {
        XCTAssertFalse(show(nil, now: "2026-09-01T09:00:00Z"))
    }

    /// A recap stamped in the future is a clock that moved, not a recap from
    /// tomorrow. Show it rather than hiding the newest thing there is.
    func testAClockThatJumpedDoesNotHideTheNewestRecap() {
        XCTAssertTrue(show("2026-09-02T09:00:00Z", now: "2026-09-01T09:00:00Z"))
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
