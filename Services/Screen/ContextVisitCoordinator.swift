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
    let startedAt: Date
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
    }

    enum Observation: Equatable {
        /// A different window, or the same one after a long absence.
        case opened(ContextVisit)
        /// Same window, new content: same visit, next generation.
        case changed(ContextVisit)
        /// Nothing worth re-reading.
        case unchanged
    }

    /// An absence longer than this ends the visit. Coming back to a window an
    /// hour later is a new visit, not a resumption of the morning's.
    static let maxGapSeconds: TimeInterval = 300

    private(set) var current: ContextVisit?
    private var lastContentHash: Int?
    private var lastSeenAt: Date?

    mutating func observe(_ sighting: Sighting, at now: Date) -> Observation {
        let normalized = WindowTitleNormalizer.normalize(sighting.rawTitle)

        guard let existing = current,
              existing.bundleID == sighting.bundleID,
              existing.windowID == sighting.windowID,
              existing.normalizedTitle == normalized,
              let seen = lastSeenAt,
              now.timeIntervalSince(seen) <= Self.maxGapSeconds
        else {
            return .opened(open(sighting, normalized: normalized, at: now))
        }

        lastSeenAt = now
        guard sighting.contentHash != lastContentHash else { return .unchanged }
        lastContentHash = sighting.contentHash

        let next = ContextVisit(
            id: existing.id,
            generation: existing.generation + 1,
            bundleID: existing.bundleID,
            appName: existing.appName,
            normalizedTitle: existing.normalizedTitle,
            rawTitle: sighting.rawTitle,
            windowID: existing.windowID,
            displayID: sighting.displayID,
            startedAt: existing.startedAt
        )
        current = next
        return .changed(next)
    }

    /// Whether work started for this exact visit and generation may still be
    /// used. Every await in the agent path is expected to re-ask.
    func isCurrent(_ visit: ContextVisit) -> Bool {
        current == visit
    }

    /// Strand everything in flight: screen history deleted, the feature turned
    /// off, the data owner changed. Work that started before this point must
    /// not be able to finish.
    mutating func invalidateAll() {
        current = nil
        lastContentHash = nil
        lastSeenAt = nil
    }

    private mutating func open(_ s: Sighting, normalized: String?, at now: Date) -> ContextVisit {
        let visit = ContextVisit(
            id: UUID(),
            generation: 0,
            bundleID: s.bundleID,
            appName: s.appName,
            normalizedTitle: normalized,
            rawTitle: s.rawTitle,
            windowID: s.windowID,
            displayID: s.displayID,
            startedAt: now
        )
        current = visit
        lastContentHash = s.contentHash
        lastSeenAt = now
        return visit
    }
}
