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

    /// From a settled context to something shown. Past this the user has moved
    /// on and a comment is worse than silence, so late work is dropped rather
    /// than delivered.
    static let endToEndDeadline: TimeInterval = 10

    /// Oldest capture a comment may still be delivered about. The proactive
    /// pipeline legitimately takes tens of seconds — investigation rounds are
    /// slow — but past two minutes "about what you are looking at" is no
    /// longer true no matter what the window title says.
    static let maxResultAgeSeconds: TimeInterval = 120
}
