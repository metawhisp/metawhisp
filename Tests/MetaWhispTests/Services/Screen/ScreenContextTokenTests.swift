import XCTest
@testable import MetaWhisp

/// Visit-wiring step 3 — the interim change token. `hashValue` is per-process
/// seeded and would have made every relaunch look like new content; FNV-1a
/// over UTF-8 is deterministic and cheap.
@MainActor
final class ScreenContextTokenTests: XCTestCase {

    func testTheTokenIsDeterministicAndContentSensitive() {
        XCTAssertEqual(ScreenContextService.stableToken("Invoice 2210 — overdue"),
                       ScreenContextService.stableToken("Invoice 2210 — overdue"))
        XCTAssertNotEqual(ScreenContextService.stableToken("Invoice 2210 — overdue"),
                          ScreenContextService.stableToken("Invoice 2210 — paid"))
        // The known FNV-1a offset basis for the empty string, pinned so a
        // "small refactor" of the constants cannot silently change every token.
        XCTAssertEqual(ScreenContextService.stableToken(""),
                       Int(bitPattern: UInt(truncatingIfNeeded: 0xcbf29ce484222325 as UInt64)))
    }
}
