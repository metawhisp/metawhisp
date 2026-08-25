import CoreGraphics
import Foundation

/// One stretch of time the user spent looking at one window.
///
/// Nothing in the app had this concept. Screen work was keyed on a raw
/// app-name/window-title pair with no identity and no version, so no piece of
/// code could answer the question everything else depends on: *is the screen
/// this result came from still the screen the user is looking at?*
///
/// Without an answer, a model call that takes twenty seconds comes back and its
/// result is used, whether or not the user moved on ten seconds ago. A comment
/// about a window someone already left is worse than no comment — it is the
/// difference between an assistant and a random banner.
struct ContextVisit: Equatable {
    let id: UUID
    /// Bumped when the same window's content changes. A result carries the
    /// generation it was started for, so a late arrival can be recognised as
    /// belonging to an older version of this window.
    let generation: Int
    let bundleID: String
    let appName: String
    /// Normalized — spinner frames and ticking clocks are removed, so cosmetic
    /// churn cannot masquerade as the user going somewhere.
    let normalizedTitle: String?
    /// Kept for display and for the source label on anything shown to the user.
    let rawTitle: String
    let windowID: UInt32?
    let displayID: UInt32?
    /// Where the window sits on screen. The system's window identity is behind
    /// a private API; its frame is not, and it answers the same two questions:
    /// two windows of one app with the same title are in different places, and
    /// a window that renames its own tab stays in the same place.
    let frame: CGRect?
    let startedAt: Date

    init(id: UUID, generation: Int, bundleID: String, appName: String,
         normalizedTitle: String?, rawTitle: String, windowID: UInt32?,
         displayID: UInt32?, frame: CGRect? = nil, startedAt: Date) {
        self.id = id
        self.generation = generation
        self.bundleID = bundleID
        self.appName = appName
        self.normalizedTitle = normalizedTitle
        self.rawTitle = rawTitle
        self.windowID = windowID
        self.displayID = displayID
        self.frame = frame
        self.startedAt = startedAt
    }
}

/// Turns a stream of "what is in front right now" observations into visits.
///
/// Pure: no clock, no capture, no persistence. Time is passed in so the
/// switching and gap behavior can be tested without waiting for it.
struct ContextVisitCoordinator {

    /// One observation of the frontmost window.
    struct Sighting {
        var bundleID: String
        var appName: String
        var rawTitle: String
        var windowID: UInt32?
        var displayID: UInt32?
        /// Fingerprint of what is actually on screen. Lets a stable-title
        /// window still report that its content moved — a new message in an
        /// open channel changes nothing about the title.
        var contentHash: Int
        /// The focused window's frame, when Accessibility gives one. Read at
        /// the same moment as the title, so both sides of a comparison have it
        /// or neither does — the asymmetry that made window IDs unusable here.
        var frame: CGRect? = nil
    }

    /// What a sighting *would* mean. Nothing is recorded until `commit`.
    ///
    /// `observe` used to mutate on the spot. If the frame it described then
    /// failed to save, the generation and content hash had already moved on, so
    /// the retry compared against state for a frame that was never stored and
    /// concluded nothing had changed — the window went quiet with nothing in
    /// history to show for it. Proposing and committing separately means state
    /// advances only for frames that actually landed.
    enum Proposal: Equatable {
        /// A different window, or the same one after a long absence.
        case opened(ContextVisit)
        /// Same window, new content: same visit, next generation.
        case changed(ContextVisit)
        /// Nothing worth re-reading.
        case unchanged
    }

    /// An absence longer than this ends the visit. Coming back to a window an
    /// hour later is a new visit, not a resumption of the morning's.
    static let maxGapSeconds: Duration = .seconds(300)

    private(set) var current: ContextVisit?
    private var lastContentHash: Int?
    private var lastSeenAt: ContinuousClock.Instant?

    /// What this sighting would mean, without recording anything.
    ///
    /// - Parameter now: a monotonic reading. Freshness must not be affected by
    ///   the wall clock moving: a rollback would otherwise make stale work look
    ///   current again until the clock caught up.
    func propose(_ sighting: Sighting,
                 at now: ContinuousClock.Instant,
                 wallClock: Date) -> Proposal {
        let normalized = WindowTitleNormalizer.normalize(sighting.rawTitle)

        guard let existing = current,
              let seen = lastSeenAt,
              isSameWindow(existing, as: sighting, normalized: normalized),
              existing.displayID == sighting.displayID,
              now >= seen,
              now - seen <= Self.maxGapSeconds
        else {
            return .opened(ContextVisit(
                id: UUID(),
                generation: 0,
                bundleID: sighting.bundleID,
                appName: sighting.appName,
                normalizedTitle: normalized,
                rawTitle: sighting.rawTitle,
                windowID: sighting.windowID,
                displayID: sighting.displayID,
                frame: sighting.frame,
                startedAt: wallClock
            ))
        }

        guard sighting.contentHash != lastContentHash else { return .unchanged }

        return .changed(ContextVisit(
            id: existing.id,
            generation: existing.generation + 1,
            bundleID: existing.bundleID,
            appName: existing.appName,
            normalizedTitle: normalized,
            rawTitle: sighting.rawTitle,
            windowID: existing.windowID,
            displayID: sighting.displayID,
            // The frame follows the window: a nudge or a resize during a visit
            // updates it without ending the visit.
            frame: sighting.frame ?? existing.frame,
            startedAt: existing.startedAt
        ))
    }

    /// Record a proposal whose frame actually landed.
    mutating func commit(_ proposal: Proposal,
                         contentHash: Int,
                         at now: ContinuousClock.Instant) {
        switch proposal {
        case .opened(let visit), .changed(let visit):
            current = visit
            lastContentHash = contentHash
            lastSeenAt = now
        case .unchanged:
            // The window is still there and still the same; keep it alive so a
            // quiet window does not age out while the user is reading it.
            lastSeenAt = max(lastSeenAt ?? now, now)
        }
    }

    /// Whether work started for this exact visit and generation may still be
    /// used. Every await in the agent path is expected to re-ask.
    ///
    /// Freshness expires on its own. Nothing calls back to say a window was
    /// closed, that capture permission was revoked or that the Mac slept, so a
    /// visit that stayed current until someone remembered to invalidate it
    /// would accept late work indefinitely.
    func isCurrent(_ visit: ContextVisit, at now: ContinuousClock.Instant) -> Bool {
        guard current == visit, let seen = lastSeenAt, now >= seen else { return false }
        return now - seen <= Self.maxGapSeconds
    }

    /// Strand everything in flight: screen history deleted, the feature turned
    /// off, the data owner changed. Work that started before this point must
    /// not be able to finish.
    mutating func invalidateAll() {
        current = nil
        lastContentHash = nil
        lastSeenAt = nil
    }

    /// The window ID is authoritative when the system provides one: a tab
    /// switch or a document rename changes the title of the same window, and
    /// that is the visit continuing. The normalized title is the fallback for
    /// when there is no ID to go on.
    private func isSameWindow(_ visit: ContextVisit,
                              as sighting: Sighting,
                              normalized: String?) -> Bool {
        guard visit.bundleID == sighting.bundleID else { return false }
        if let known = visit.windowID, let incoming = sighting.windowID {
            return known == incoming
        }
        // The frame decides when both sides have one. Two mail windows both
        // called "Inbox" sit in different places — treating them as one visit
        // attributes one conversation's text to the other. And a page that
        // renames its own tab has not moved, so the visit continues.
        if let known = visit.frame, let incoming = sighting.frame {
            return Self.framesOverlapEnough(known, incoming)
        }
        // A frame that appeared or stopped being readable is not by itself a
        // different window: that asymmetry is what turned window IDs into a
        // capture storm. Fall back to the title rule.
        return visit.windowID == sighting.windowID && visit.normalizedTitle == normalized
    }

    /// Two frames describe the same window when they mostly cover each other.
    /// A nudge or a small resize keeps the visit; moving a window to the other
    /// half of the screen does not.
    static func framesOverlapEnough(_ a: CGRect, _ b: CGRect,
                                    minimumOverlap: Double = 0.6) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0
        else { return false }
        let overlap = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height + b.width * b.height) - overlap
        guard union > 0 else { return false }
        return overlap / union >= minimumOverlap
    }
}
