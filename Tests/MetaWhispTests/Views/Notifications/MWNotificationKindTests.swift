import XCTest
import SwiftUI
@testable import MetaWhisp

/// The card's own vocabulary: what colour means, what a symbol claims, and how
/// long the thing stays up. All three were decided by accident and all three
/// were telling the user something untrue.
@MainActor
final class MWNotificationKindTests: XCTestCase {

    private let all: [MWNotification.Kind] = [
        .task, .call, .recordingStopped, .recordingOverrun,
        .recap, .advice, .proactive, .signIn
    ]

    /// Colour is a status, not a filing system. Purple meant "this is the
    /// advice sort" and yellow meant "this is the context sort" — a taxonomy
    /// the user has no key to and no reason to learn. Orange on a recording
    /// that outran its calendar slot is different: that is a state of the
    /// world, and it is the only one on this list.
    func testOnlyAStateOfTheWorldGetsColour() {
        let neutral = Self.rgba(MW.textSecondary)
        for kind in all where kind != .recordingOverrun {
            XCTAssertEqual(Self.rgba(kind.accent), neutral, accuracy: 0.001,
                           "\(kind) paints itself instead of staying neutral")
        }
        XCTAssertNotEqual(Self.rgba(MWNotification.Kind.recordingOverrun.accent), neutral,
                          accuracy: 0.001,
                          "a recording past its slot is a state and must read as one")
    }

    /// A symbol is a claim about what happened. A lightbulb claims "here is an
    /// idea"; `proactive` means "you already decided this" or "you are waiting
    /// on this" — the past, not an invention. A stopwatch claims nothing is
    /// wrong while the recording quietly runs over.
    func testSymbolsClaimWhatTheStatusActuallyMeans() {
        XCTAssertEqual(MWNotification.Kind.proactive.icon, "clock.arrow.circlepath")
        XCTAssertEqual(MWNotification.Kind.recordingOverrun.icon, "clock.badge.exclamationmark")
        XCTAssertNotEqual(MWNotification.Kind.proactive.icon, "lightbulb.fill",
                          "memory is not an idea")
    }

    /// Every symbol has to exist on this OS, or the badge renders empty and the
    /// card silently loses the one thing that says what it is.
    func testEverySymbolResolvesOnThisSystem() {
        for kind in all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: kind.icon, accessibilityDescription: nil),
                "\(kind) names a symbol this system does not have: \(kind.icon)")
        }
    }

    /// Forty-five seconds mapped to no deferred operation whatsoever. A surface
    /// that sits that long and then vanishes with no consequence teaches, once
    /// per card, that ignoring it costs nothing. The advice itself is durable —
    /// the card is a pointer to an inbox row that already exists — so a short
    /// life loses nothing, and hovering still pauses it.
    func testACardLivesAsLongAsAnythingElseTheAppShows() {
        XCTAssertEqual(MWNotificationStack.agentCardLifetimeForTests, 6, accuracy: 0.001)
        XCTAssertEqual(MWNotificationStack.agentCardLifetimeForTests,
                       MWNotificationStack.toastLifetimeForTests, accuracy: 0.001,
                       "one number for the whole app beats two nobody can justify")
    }

    // MARK: - helpers

    /// Compare colours as numbers; `Color` equality is identity-ish and would
    /// pass on two different greys.
    private static func rgba(_ color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return ns.redComponent * 1_000_000 + ns.greenComponent * 1_000
             + ns.blueComponent + Double(ns.alphaComponent) * 0.001
    }
}
