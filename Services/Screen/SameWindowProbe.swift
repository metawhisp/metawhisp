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

    /// Why the window is being read, which is not the same question as whether
    /// to read it. A forced read exists so an hour of reading is not a hole in
    /// history — nothing on the screen changed, so there is nothing for the
    /// agent to say about it and it is not woken.
    enum Verdict: Equatable {
        case quiet
        case moved
        case forced

        var shouldRead: Bool { self != .quiet }
    }

    private var lastLookedAt: Date?
    private var baseline: ScreenContentFingerprint?
    /// When this probe last let a read through — a change, a forced read, or
    /// the first look that established the baseline. The ceiling is measured
    /// from here, so a window that keeps being read never accumulates one.
    private var lastReleasedAt: Date?

    /// Clock only. Called before a screenshot is taken, not after.
    func shouldLook(at now: Date) -> Bool {
        guard let lastLookedAt else { return true }
        return now.timeIntervalSince(lastLookedAt)
            >= ScreenAgentTimingPolicy.sameWindowProbeSeconds
    }

    /// Store what the window looks like now and say what that means. `.quiet`
    /// on the first call: there is nothing to be different from yet.
    mutating func look(at fingerprint: ScreenContentFingerprint,
                       now: Date) -> Verdict {
        defer {
            baseline = fingerprint
            lastLookedAt = now
        }
        guard let baseline else {
            // The first look is the baseline, and the capture that opened this
            // window has just happened — so the ceiling starts counting here.
            lastReleasedAt = now
            return .quiet
        }
        if fingerprint.differs(from: baseline) {
            lastReleasedAt = now
            return .moved
        }
        guard forcedReadIsDue(at: now) else { return .quiet }
        lastReleasedAt = now
        return .forced
    }

    /// Whether the quiet answer has been held long enough that the window must
    /// be read anyway. Wall-clock, so a wake from sleep or an NTP correction
    /// can put `now` behind the last release: a backwards jump counts as due
    /// rather than wedging the probe shut until real time catches up.
    private func forcedReadIsDue(at now: Date) -> Bool {
        guard let lastReleasedAt else { return true }
        let elapsed = now.timeIntervalSince(lastReleasedAt)
        return elapsed < 0 || elapsed >= ScreenAgentTimingPolicy.forcedReadSeconds
    }

    /// The baseline belongs to the window it was taken from. Comparing one
    /// window's picture against another's reports a change every time.
    mutating func reset() {
        baseline = nil
        lastLookedAt = nil
        lastReleasedAt = nil
    }
}
