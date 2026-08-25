import Foundation
import SwiftData

/// One stretch of time at one window, as a row.
///
/// The coordinator has held this concept in memory since ITER-065; nothing
/// durable ever recorded it, so a card could not point at the visit that
/// produced it and the daily analysis rebuilt visits from app names and
/// five-minute gaps — a second, disagreeing reality. This row is the one
/// identity both consume (ITER-071 §2: immutable visit IDs, measured
/// start/end, accepted frame IDs).
///
/// Named `…Record` because `ContextVisit` is the coordinator's pinned value
/// struct — same precedent as `ScreenAgentDeliveryRecord`. Deliberate
/// deviation from plan §8's file name, recorded in PROGRESS.
///
/// No OCR text and no screen content lives here — identity, timings and
/// reason codes only. `windowID`/`displayID` are provenance for the row and
/// are never fed back into coordinator sightings (nil/non-nil asymmetry in
/// window matching would open a new visit every tick).
@Model
final class ContextVisitRecord {
    /// The coordinator's own visit identity, immutable for the visit's life.
    @Attribute(.unique) var id: UUID
    /// Latest committed generation — bumped when the same window's content
    /// changed. Distinct from `captureEpoch` (the purge/stop fence): the two
    /// must never be conflated.
    var generation: Int

    var bundleID: String
    var appName: String
    var rawTitle: String
    var normalizedTitle: String?
    var windowID: Int?
    var displayID: Int?

    var startedAt: Date
    var lastObservedAt: Date
    var endedAt: Date?

    /// Why the visit ended, when it did: context_switch, gap_expired,
    /// startup_reconcile. Reason codes only.
    var invalidationReason: String?
    /// Outcome of the visit's most recent capture, from ScreenCaptureOutcome.
    var captureState: String

    /// The newest ScreenContext row this visit produced.
    var latestScreenContextID: UUID?
    /// Accepted frame IDs, bounded — the ITER-071 §2 contract.
    var frameIDsJSON: String
    /// In-process change token; never comparable across launches. Stays nil
    /// until the content-fingerprint iteration lands.
    var latestContentHash: Int?

    static let maxFrameIDs = 32

    init(
        id: UUID,
        generation: Int,
        bundleID: String,
        appName: String,
        rawTitle: String,
        normalizedTitle: String?,
        windowID: Int? = nil,
        displayID: Int? = nil,
        startedAt: Date,
        captureState: String = ""
    ) {
        self.id = id
        self.generation = generation
        self.bundleID = bundleID
        self.appName = appName
        self.rawTitle = rawTitle
        self.normalizedTitle = normalizedTitle
        self.windowID = windowID
        self.displayID = displayID
        self.startedAt = startedAt
        self.lastObservedAt = startedAt
        self.captureState = captureState
        self.frameIDsJSON = "[]"
    }

    var frameIDs: [UUID] {
        guard let data = frameIDsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }

    /// Append an accepted frame, keeping the newest `maxFrameIDs`.
    func appendFrameID(_ frameID: UUID) {
        var ids = frameIDs
        ids.append(frameID)
        if ids.count > Self.maxFrameIDs {
            ids.removeFirst(ids.count - Self.maxFrameIDs)
        }
        frameIDsJSON =
            (try? String(data: JSONEncoder().encode(ids), encoding: .utf8) ?? "[]") ?? "[]"
    }
}
