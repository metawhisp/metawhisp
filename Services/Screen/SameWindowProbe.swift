import CoreGraphics
import Foundation

/// Whether a window whose title has not moved is worth reading again.
///
/// Capture fires on the title changing, so a new message in an already-open
/// channel — same app, same title, same frame — has never been captured at all.
/// `ScreenContentFingerprint` was written for this case and was never called
/// from production; this is the piece that was missing between them.
///
/// It answers two separate questions, in this order, because they cost
/// different amounts. *Should I look?* is a clock check and is free. *Did it
/// move?* needs a screenshot, and a screenshot is the reason the cadence gate
/// comes first.
///
/// Deliberately conservative in one direction: the first look at a window is a
/// baseline, never a verdict. Reporting a change with nothing to compare
/// against would capture every window the moment it went quiet, which is the
/// storm this exists to avoid.
struct SameWindowProbe {

    private var lastLookedAt: Date?
    private var baseline: ScreenContentFingerprint?

    /// Clock only. Called before a screenshot is taken, not after.
    func shouldLook(at now: Date) -> Bool {
        guard let lastLookedAt else { return true }
        return now.timeIntervalSince(lastLookedAt)
            >= ScreenAgentTimingPolicy.sameWindowProbeSeconds
    }

    /// Store what the window looks like now and say whether that is different
    /// from what it looked like before. `false` on the first call: there is
    /// nothing to be different from yet.
    mutating func contentMoved(to fingerprint: ScreenContentFingerprint,
                               at now: Date) -> Bool {
        defer {
            baseline = fingerprint
            lastLookedAt = now
        }
        guard let baseline else { return false }
        return fingerprint.differs(from: baseline)
    }

    /// The baseline belongs to the window it was taken from. Comparing one
    /// window's picture against another's reports a change every time.
    mutating func reset() {
        baseline = nil
        lastLookedAt = nil
    }
}
