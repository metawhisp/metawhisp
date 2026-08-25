import Foundation

/// How often MetaWhisp is allowed to interrupt, as one choice a person can
/// make.
///
/// The settings had several unrelated cooldown numbers in different places, and
/// no combination of them answered the question anyone actually has: how do I
/// make this quieter? A user who wants fewer interruptions should not have to
/// reason about which of three intervals governs which code path.
enum ScreenAgentPacing: String, CaseIterable, Identifiable {
    case quiet
    case balanced
    case frequent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .frequent: return "Frequent"
        }
    }

    /// Said in time, not in minutes-between-events, because that is how it is
    /// experienced.
    var explanation: String {
        switch self {
        case .quiet: return "At most 10 a day, an hour apart, only when it really matters."
        case .balanced: return "Up to 20 a day, half an hour apart, when there is something worth saying."
        case .frequent: return "As soon as there is something specific — minutes apart, up to 60 a day."
        }
    }

    /// Ported from the reference implementation's measured budget table
    /// (cooldown 60/30/3 minutes for its levels 1/2/4). Not invented.
    var minimumSecondsBetween: TimeInterval {
        switch self {
        case .quiet: return 60 * 60
        case .balanced: return 30 * 60
        case .frequent: return 3 * 60
        }
    }

    /// The reference pairs every cooldown with a daily ceiling (10/20/60 for
    /// the same levels); a cooldown alone bounds the gap, not the day.
    var dailyLimit: Int {
        switch self {
        case .quiet: return 10
        case .balanced: return 20
        case .frequent: return 60
        }
    }

    /// How long the same idea stays suppressed. A quieter setting should also
    /// mean a longer memory for repeats, or the user still gets the same
    /// thought twice in a day they asked to be quiet.
    var duplicateWindowSeconds: TimeInterval {
        switch self {
        case .quiet: return 24 * 3600
        case .balanced: return 6 * 3600
        case .frequent: return 3600
        }
    }

    /// Applied when the user says a comment came at a bad moment. Timing
    /// feedback moves timing; it says nothing about whether the content was
    /// right, so it must not silence that content.
    var quieter: ScreenAgentPacing {
        switch self {
        case .frequent: return .balanced
        case .balanced: return .quiet
        case .quiet: return .quiet
        }
    }
}
