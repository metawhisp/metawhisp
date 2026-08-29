import Foundation

/// Every timing decision the Screen Agent makes, in one place.
///
/// These were about to become magic numbers scattered across a capture service,
/// a queue and a director, which is how the meeting path ended up with a chunk
/// size and a request timeout that contradicted each other for months without
/// anyone noticing. Naming them together means a change to one is a change made
/// in sight of the others.
///
/// Proposed starting values from the ITER-065 spec, not measured behavior.
/// Moving them is a product decision that wants replay or live evidence.
enum ScreenAgentTimingPolicy {

    /// How long a window must hold still before it is worth reading. Focus
    /// changes arrive in bursts as the user tabs through windows.
    static let settleSeconds: TimeInterval = 0.75

    /// How often to re-check a window whose title has not moved. Content can
    /// change with nothing in the title to show for it — a new message in an
    /// open channel is exactly this case.
    static let sameWindowProbeSeconds: TimeInterval = 3

    /// How long the probe may keep saying "nothing moved" before the window is
    /// read regardless of how identical it looks.
    ///
    /// A gate with no ceiling starves. "The picture has not changed" stays true
    /// for exactly as long as somebody reads one document, and reading is what
    /// sitting still in front of a document looks like — so an hour of the
    /// user's deepest work produced no rows at all.
    ///
    /// Half of `ContextVisitCoordinator.maxGapSeconds`, derived rather than
    /// picked round: a gap past that ends the visit and the same window becomes
    /// news again, so forcing at half of it keeps a continuously-read window
    /// inside one unbroken visit even when a tick is lost to a slow OCR pass.
    /// It also bounds the cost exactly — at most one extra read per interval,
    /// and only while a window is otherwise being suppressed.
    ///
    /// Measured from the last row that actually landed, so the first ceiling on
    /// a freshly opened window runs one poll longer than this: the probe needs a
    /// baseline before it can suppress anything. 150 + one poll is still well
    /// inside the visit gap, which is the property that matters.
    static let forcedReadSeconds: TimeInterval = 150

    /// From a settled context to something shown. Past this the user has moved
    /// on and a comment is worse than silence, so late work is dropped rather
    /// than delivered.
    static let endToEndDeadline: TimeInterval = 10

    /// Oldest capture a comment may still be delivered about.
    ///
    /// Staleness is primarily the context-ID check — switching windows retires
    /// a run instantly. This age cap is the backstop for the cases where the
    /// ID cannot move (sleep, lock). It must comfortably exceed the
    /// investigator's real latency: five rounds at up to 45 seconds each meant
    /// a two-minute cap was silencing runs the user was still sitting in front
    /// of, on the very screen the comment was about.
    static let maxResultAgeSeconds: TimeInterval = 600
}
