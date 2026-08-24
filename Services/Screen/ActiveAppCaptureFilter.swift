import CoreGraphics
import Foundation

/// AUD-022 fix — decide which windows to EXCLUDE from a screen capture so the
/// screenshot contains only the front application's content.
///
/// Before this, `ScreenContextService.captureScreenshot` filtered the whole
/// display with `excludingWindows: []` — it screenshotted EVERYTHING, including a
/// password manager, private chat or token window visible beside the focused
/// app, then labeled the OCR with only the front app. That bypassed the
/// front-app blacklist and pushed unrelated sensitive text into SwiftData and
/// cloud prompts.
///
/// Excluding every window not owned by the front app (rather than picking a
/// single "active" window) is intentional: it handles multi-window apps, avoids
/// guessing which window is key, and guarantees no other app's pixels are
/// captured. Pure + unit-tested so the privacy boundary is verifiable without
/// ScreenCaptureKit.
enum ActiveAppCaptureFilter {

    struct WindowRef: Equatable {
        let id: Int
        let ownerPID: Int
        /// Screen rectangle. Needed to tell two windows of one app apart and to
        /// work out which monitor the user is actually reading.
        var bounds: CGRect = .zero
        var isOnScreen: Bool = true
        /// Window level. Menu-bar extras, tooltips and panels sit above the
        /// normal layer and are not what anyone is reading.
        var layer: Int = 0
    }

    struct DisplayRef: Equatable {
        let id: UInt32
        let frame: CGRect
    }

    enum FocusSelection: Equatable {
        case window(id: Int)
        /// More than one candidate and nothing to separate them. Capture must
        /// stay silent rather than OCR both and label the result with one.
        case ambiguous
        case notFound
    }

    /// The one window the user is reading.
    ///
    /// Capture used to take every window owned by the front app and merge them
    /// into a single OCR blob, so a claim about one browser tab could be
    /// attributed to another — invisibly, because the text simply describes
    /// something else.
    ///
    /// - Parameter focusedBounds: the Accessibility API's focused-window
    ///   rectangle when it is available. Bounds rarely agree to the pixel
    ///   (shadows, title bars, rounding), so the best overlap wins.
    static func selectFocusedWindow(
        _ windows: [WindowRef],
        frontPID: Int,
        focusedBounds: CGRect?
    ) -> FocusSelection {
        let candidates = windows.filter {
            $0.ownerPID == frontPID
                && $0.isOnScreen
                && $0.layer < Self.overlayLayerFloor
                && $0.bounds.width > 1
                && $0.bounds.height > 1
        }
        guard !candidates.isEmpty else { return .notFound }

        if let focusedBounds, focusedBounds.width > 1, focusedBounds.height > 1 {
            var ranked: [(window: WindowRef, score: CGFloat)] = []
            for candidate in candidates {
                ranked.append((candidate, overlapRatio(candidate.bounds, focusedBounds)))
            }
            ranked.sort { $0.score > $1.score }
            guard let best = ranked.first, best.score >= minimumOverlap else {
                // Accessibility says focus is somewhere none of these windows
                // are. That is a real disagreement about what the user is
                // looking at, and answering it by returning whatever is left
                // would be confidently wrong.
                return .ambiguous
            }
            let runnerUp: CGFloat = ranked.dropFirst().first?.score ?? 0
            guard best.score - runnerUp >= minimumMargin else { return .ambiguous }
            return .window(id: best.window.id)
        }

        guard candidates.count == 1 else { return .ambiguous }
        return .window(id: candidates[0].id)
    }

    /// The display the window is actually on — not `displays.first`, which is
    /// simply the wrong screen for anyone with a second monitor. A window
    /// spanning two displays belongs to whichever shows more of it; one that is
    /// on no display at all (a monitor was just unplugged) resolves to nothing
    /// rather than to an arbitrary monitor.
    static func displayContaining(_ bounds: CGRect, displays: [DisplayRef]) -> DisplayRef? {
        var ranked: [(display: DisplayRef, area: CGFloat)] = []
        for display in displays {
            let hit: CGRect = display.frame.intersection(bounds)
            guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }
            ranked.append((display, hit.width * hit.height))
        }
        ranked.sort { $0.area > $1.area }
        guard let best = ranked.first else { return nil }
        // A window split evenly across two screens has no answer, and picking
        // whichever the system happened to list first is not one.
        let runnerUp: CGFloat = ranked.dropFirst().first?.area ?? 0
        guard best.area > runnerUp else { return nil }
        return best.display
    }

    /// Window levels at or above this are chrome, not content: menu-bar extras,
    /// tooltips, popovers. Below it sit ordinary document windows *and* the
    /// floating, utility and modal levels — a save sheet, a settings dialog or
    /// a form is exactly the window the agent is most likely to have something
    /// useful to say about, and an earlier `layer == 0` rule discarded all of
    /// them and read the document underneath instead.
    static let overlayLayerFloor = 20

    /// How much of the focused rectangle a window must account for before it
    /// counts as that window at all.
    static let minimumOverlap: CGFloat = 0.6

    /// How far ahead of the runner-up the winner must be. Two windows at
    /// identical bounds both score a perfect match, and the order a system API
    /// returned them in must not decide which of the user's windows gets read.
    static let minimumMargin: CGFloat = 0.15

    /// Intersection as a fraction of the larger rectangle, so a small window
    /// sitting inside a big one does not score as a match.
    private static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let hit = a.intersection(b)
        guard !hit.isNull else { return 0 }
        let larger = max(a.width * a.height, b.width * b.height)
        guard larger > 0 else { return 0 }
        return (hit.width * hit.height) / larger
    }

    /// IDs of windows to exclude from the capture: everything NOT owned by the
    /// front application (identified by `frontPID`).
    static func windowsToExclude(_ windows: [WindowRef], frontPID: Int) -> [Int] {
        windows.filter { $0.ownerPID != frontPID }.map { $0.id }
    }
}
