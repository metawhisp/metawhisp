import Foundation
import os

/// Only closed transition names and counts cross the diagnostic boundary.
/// Request identity, transcript, answer, and question content never enter it.
@MainActor
final class MeetingCoachTransitionDiagnostics {
    enum Kind: String { case hover, answer, delta, ask, tab, hide, show }
    enum Phase { case begin, end }
    struct Event {
        let id: Int
        let kind: Kind
        let phase: Phase
        let frameCommits: Int
    }
    final class Interval {
        fileprivate let id: Int
        fileprivate let kind: Kind
        fileprivate let signpostID: OSSignpostID
        fileprivate var frameCommits = 0
        fileprivate var ended = false

        fileprivate init(id: Int, kind: Kind, log: OSLog) {
            self.id = id
            self.kind = kind
            signpostID = OSSignpostID(log: log)
        }
    }

    private static let log = OSLog(subsystem: "com.metawhisp", category: "MeetingCardTransitions")
    private let eventSink: (Event) -> Void
    private let debugSink: (String) -> Void
    private var nextID = 0

    init(eventSink: @escaping (Event) -> Void = { _ in },
         debugSink: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.eventSink = eventSink
        self.debugSink = debugSink
    }

    func begin(_ kind: Kind) -> Interval {
        nextID += 1
        let interval = Interval(id: nextID, kind: kind, log: Self.log)
        os_signpost(.begin, log: Self.log, name: "MeetingCardTransition", signpostID: interval.signpostID,
                    "kind=%{public}@", kind.rawValue as NSString)
        eventSink(Event(id: interval.id, kind: kind, phase: .begin, frameCommits: 0))
        return interval
    }

    func committedFrames(_ interval: Interval?) {
        guard let interval, !interval.ended else { return }
        interval.frameCommits += 1
    }

    func end(_ interval: Interval?) {
        guard let interval, !interval.ended else { return }
        interval.ended = true
        os_signpost(.end, log: Self.log, name: "MeetingCardTransition", signpostID: interval.signpostID,
                    "kind=%{public}@", interval.kind.rawValue as NSString)
        eventSink(Event(id: interval.id, kind: interval.kind, phase: .end, frameCommits: interval.frameCommits))
        #if DEBUG
        debugSink("[MeetingCard] transition=\(interval.kind.rawValue) frame_commits=\(interval.frameCommits)")
        #endif
    }
}
