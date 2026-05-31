import XCTest
@testable import MetaWhisp

/// AUD-022 — screen capture must include only the front app's windows, so a
/// password manager or private chat visible beside the focused app never reaches
/// OCR. These pin the exclude-list selection.
final class ActiveAppCaptureFilterTests: XCTestCase {

    private typealias W = ActiveAppCaptureFilter.WindowRef

    func test_excludesEveryWindowNotOwnedByFrontApp() {
        let windows = [
            W(id: 1, ownerPID: 100), // front app
            W(id: 2, ownerPID: 200), // other app — EXCLUDE
            W(id: 3, ownerPID: 100), // front app
            W(id: 4, ownerPID: 999), // other app — EXCLUDE
        ]
        XCTAssertEqual(Set(ActiveAppCaptureFilter.windowsToExclude(windows, frontPID: 100)), [2, 4])
    }

    func test_frontAppOnly_excludesNothing() {
        let windows = [W(id: 1, ownerPID: 100), W(id: 2, ownerPID: 100)]
        XCTAssertTrue(ActiveAppCaptureFilter.windowsToExclude(windows, frontPID: 100).isEmpty)
    }

    func test_emptyWindowList() {
        XCTAssertTrue(ActiveAppCaptureFilter.windowsToExclude([], frontPID: 1).isEmpty)
    }

    func test_noFrontAppWindows_excludesAll() {
        let windows = [W(id: 1, ownerPID: 200), W(id: 2, ownerPID: 300)]
        XCTAssertEqual(Set(ActiveAppCaptureFilter.windowsToExclude(windows, frontPID: 100)), [1, 2])
    }
}
