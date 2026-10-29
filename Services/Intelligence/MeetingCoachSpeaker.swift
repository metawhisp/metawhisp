import Combine
import Foundation

/// Speaker polling invalidates its capsule label and wave, never the answer tree.
@MainActor
final class MeetingCoachSpeakerModel: ObservableObject {
    @Published private(set) var speaker: MeetingCoachSpeaker = .unavailable

    func setSpeaker(_ speaker: MeetingCoachSpeaker) {
        guard self.speaker != speaker else { return }
        self.speaker = speaker
    }
}

enum MeetingCoachSpeaker: Equatable, Sendable {
    case me, them, both, quiet, unavailable

    var label: String? {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        case .both: return "Both"
        case .quiet: return "Quiet"
        case .unavailable: return nil
        }
    }

    static func project(me: Bool, them: Bool) -> Self {
        switch (me, them) {
        case (true, true): return .both
        case (true, false): return .me
        case (false, true): return .them
        case (false, false): return .quiet
        }
    }
}
