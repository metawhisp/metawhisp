import XCTest
@testable import MetaWhisp

/// A2 — Settings shows the real plan. Every license row says plan "pro", so "Monthly plan unless plan == annual"
/// told yearly subscribers they paid monthly. The billing period comes from the session answer's subscription
/// (server S2, `interval` "year" / "month"); with no period known, no plan line — never a guessed "Monthly".
final class LicensePlanLabelTests: XCTestCase {

    func testThePlanLineSaysTheBillingPeriod() {
        XCTAssertEqual(LicenseService.planLabel(interval: "year"), "Annual plan")
        XCTAssertEqual(LicenseService.planLabel(interval: "month"), "Monthly plan")
    }

    func testNoPeriodShowsNoPlanLine() {
        for interval in [nil, "", "week", "pro", "annual"] as [String?] {
            XCTAssertNil(LicenseService.planLabel(interval: interval), interval ?? "nil")
        }
    }

    /// The session answer carries the period in its subscription; an older server sends none.
    func testTheSessionAnswerCarriesItsBillingPeriod() throws {
        let yearly = #"{"email":"sam@example.com","license":{"license_key":"k","plan":"pro","status":"active"},"subscription":{"current_period_end":1790000000,"cancel_at_period_end":false,"status":"active","interval":"year"}}"#
        XCTAssertEqual(try JSONDecoder().decode(SessionResponse.self, from: Data(yearly.utf8)).subscription?.interval, "year")
        let older = #"{"email":"sam@example.com","license":null,"subscription":{"current_period_end":1790000000,"status":"active"}}"#
        let decoded = try JSONDecoder().decode(SessionResponse.self, from: Data(older.utf8))
        XCTAssertNotNil(decoded.subscription)
        XCTAssertNil(decoded.subscription?.interval)
    }
}
