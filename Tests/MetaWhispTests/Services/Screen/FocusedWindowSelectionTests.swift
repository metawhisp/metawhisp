import XCTest
import CoreGraphics
@testable import MetaWhisp

/// Which window, and therefore which screen, the agent is actually looking at.
///
/// Capture took `content.displays.first` and every window belonging to the
/// front app. On a second monitor that grabs the wrong screen entirely; with
/// two windows of one app it merges both into one OCR blob, so a claim about
/// one browser tab can be attributed to the other. Neither failure is visible
/// in the result — the text just quietly describes something else.
///
/// Pure geometry, so the choice is verifiable without ScreenCaptureKit.
final class FocusedWindowSelectionTests: XCTestCase {

    private func win(_ id: Int, pid: Int, _ rect: CGRect,
                     onScreen: Bool = true, layer: Int = 0) -> ActiveAppCaptureFilter.WindowRef {
        .init(id: id, ownerPID: pid, bounds: rect, isOnScreen: onScreen, layer: layer)
    }

    // MARK: choosing the window

    func testSingleFrontAppWindowIsChosen() {
        let windows = [win(1, pid: 100, .init(x: 0, y: 0, width: 800, height: 600)),
                       win(2, pid: 999, .init(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow(windows, frontPID: 100, focusedBounds: nil),
            .window(id: 1))
    }

    /// Two windows of one app: the Accessibility bounds say which one has
    /// focus. Without this the capture merges both.
    func testAccessibilityBoundsPickBetweenTwoWindowsOfOneApp() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 1920, y: 0, width: 800, height: 600)
        let windows = [win(1, pid: 100, a), win(2, pid: 100, b)]
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow(windows, frontPID: 100, focusedBounds: b),
            .window(id: 2))
    }

    /// Bounds rarely match to the pixel — shadows, title bars, rounding. The
    /// best overlap wins as long as it is clearly the same window.
    func testNearMatchingBoundsStillResolve() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 1920, y: 0, width: 800, height: 600)
        let windows = [win(1, pid: 100, a), win(2, pid: 100, b)]
        let slightlyOff = CGRect(x: 1922, y: 3, width: 796, height: 594)
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow(windows, frontPID: 100, focusedBounds: slightlyOff),
            .window(id: 2))
    }

    /// Two candidates and nothing to separate them: stay silent rather than
    /// OCR both and label the result with one of them.
    func testTwoWindowsWithoutFocusBoundsIsAmbiguous() {
        let windows = [win(1, pid: 100, .init(x: 0, y: 0, width: 800, height: 600)),
                       win(2, pid: 100, .init(x: 900, y: 0, width: 800, height: 600))]
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow(windows, frontPID: 100, focusedBounds: nil),
            .ambiguous)
    }

    func testNoFrontAppWindowIsNotFound() {
        let windows = [win(1, pid: 999, .init(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow(windows, frontPID: 100, focusedBounds: nil),
            .notFound)
    }

    /// Menu-bar items, panels and offscreen windows are not the thing the user
    /// is reading.
    func testOffscreenAndOverlayWindowsAreNotCandidates() {
        let real = win(1, pid: 100, .init(x: 0, y: 0, width: 800, height: 600))
        let hidden = win(2, pid: 100, .init(x: 0, y: 0, width: 800, height: 600), onScreen: false)
        let overlay = win(3, pid: 100, .init(x: 0, y: 0, width: 200, height: 40), layer: 25)
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow([real, hidden, overlay],
                                                       frontPID: 100, focusedBounds: nil),
            .window(id: 1))
    }

    /// A zero-sized window cannot be what the user is looking at, and must not
    /// make a real window look ambiguous.
    func testDegenerateWindowsAreIgnored() {
        let real = win(1, pid: 100, .init(x: 0, y: 0, width: 800, height: 600))
        let empty = win(2, pid: 100, .zero)
        XCTAssertEqual(
            ActiveAppCaptureFilter.selectFocusedWindow([real, empty],
                                                       frontPID: 100, focusedBounds: nil),
            .window(id: 1))
    }

    // MARK: choosing the display

    private let main = ActiveAppCaptureFilter.DisplayRef(
        id: 1, frame: .init(x: 0, y: 0, width: 1920, height: 1080))
    private let second = ActiveAppCaptureFilter.DisplayRef(
        id: 2, frame: .init(x: 1920, y: 0, width: 2560, height: 1440))

    /// The whole point on a multi-monitor desk: the focused window is on
    /// display 2, so display 2 is what gets captured — not `displays.first`.
    func testDisplayIsTheOneHoldingTheWindow() {
        let onSecond = CGRect(x: 2200, y: 300, width: 800, height: 600)
        XCTAssertEqual(
            ActiveAppCaptureFilter.displayContaining(onSecond, displays: [main, second])?.id, 2)
    }

    func testWindowOnTheMainDisplayPicksTheMainDisplay() {
        let onMain = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(
            ActiveAppCaptureFilter.displayContaining(onMain, displays: [main, second])?.id, 1)
    }

    /// A window straddling both screens belongs to whichever shows more of it.
    func testStraddlingWindowGoesToTheDisplayShowingMostOfIt() {
        let straddling = CGRect(x: 1620, y: 0, width: 800, height: 600)  // 300 on main, 500 on second
        XCTAssertEqual(
            ActiveAppCaptureFilter.displayContaining(straddling, displays: [main, second])?.id, 2)
    }

    func testNoDisplaysMeansNoChoice() {
        XCTAssertNil(ActiveAppCaptureFilter.displayContaining(
            .init(x: 0, y: 0, width: 10, height: 10), displays: []))
    }

    /// A window entirely off any display (a screen was just unplugged) must not
    /// silently resolve to some arbitrary monitor.
    func testWindowOnNoDisplayResolvesToNothing() {
        let nowhere = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        XCTAssertNil(ActiveAppCaptureFilter.displayContaining(nowhere, displays: [main, second]))
    }
}
