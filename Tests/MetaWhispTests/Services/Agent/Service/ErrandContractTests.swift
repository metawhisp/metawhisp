import XCTest
@testable import MetaWhisp

/// ITER-076 B0 — a finished errand is kept as JSON: its outcome and where it
/// was asked for come back whole.
final class ErrandContractTests: XCTestCase {

    func testAnOutcomeComesBackWholeFromJSON() throws {
        let done = ErrandOutcome(ending: .done, answer: "Three sites", sources: [URL(string: "https://site-1.test/")!],
                                 sheet: URL(string: "https://sheet.test/1"), rows: 3)
        let notRun = ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: 0,
                                   notRun: .remoteDebuggingOff)
        for outcome in [done, notRun] {
            XCTAssertEqual(try JSONDecoder().decode(ErrandOutcome.self, from: JSONEncoder().encode(outcome)), outcome)
        }
        XCTAssertNil(done.notRun, "an errand that ran has no reason for not running")
    }

    func testWhereAnErrandWasAskedForComesBackFromJSON() throws {
        for origin in [ErrandOrigin.chat(messageID: UUID()), .voice(questionID: UUID())] {
            XCTAssertEqual(try JSONDecoder().decode(ErrandOrigin.self, from: JSONEncoder().encode(origin)), origin)
        }
    }

    /// ITER-076 I-05: an outcome keeps why its errand failed and when to ask
    /// again; one saved before either existed still reads.
    func testAnOutcomeKeepsItsFailureAndWhenToAskAgain() throws {
        let limit = ErrandOutcome(ending: .dailyLimit, answer: nil, sources: [], sheet: nil, rows: 0,
                                  retryAt: Date(timeIntervalSince1970: 1_790_000_000))
        let lost = ErrandOutcome(ending: .failed, answer: nil, sources: [URL(string: "https://site-1.test/")!],
                                 sheet: nil, rows: 1, failure: .bridgeLost)
        for outcome in [limit, lost] {
            XCTAssertEqual(try JSONDecoder().decode(ErrandOutcome.self, from: JSONEncoder().encode(outcome)), outcome)
        }
        let before = #"{"ending":"stopped","sources":[],"rows":0}"#
        let old = try JSONDecoder().decode(ErrandOutcome.self, from: Data(before.utf8))
        XCTAssertEqual(old, ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 0))
    }

    /// ITER-076 stage 6: an outcome keeps how its Sheet failed, beside its ending and answer; one saved before
    /// that was kept still reads, with none.
    func testAnOutcomeKeepsHowItsSheetFailed() throws {
        for failure in ErrandOutcome.SheetFailure.allCases {
            let outcome = ErrandOutcome(ending: .done, answer: "Joke 1\nhttps://site-1.test/",
                                        sources: [URL(string: "https://site-1.test/")!], sheet: nil, rows: 0,
                                        sheetFailure: failure)
            let back = try JSONDecoder().decode(ErrandOutcome.self, from: JSONEncoder().encode(outcome))
            XCTAssertEqual(back, outcome)
            XCTAssertEqual(back.withSheet(URL(string: "https://sheet.test/1")).sheetFailure, failure,
                           "a Sheet amended after the end keeps the failure named")
        }
        let before = #"{"ending":"done","answer":"a","sources":[],"rows":0}"#
        XCTAssertNil(try JSONDecoder().decode(ErrandOutcome.self, from: Data(before.utf8)).sheetFailure)
    }
}
