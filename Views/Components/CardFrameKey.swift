import SwiftUI

/// PreferenceKey for bubbling the *actual rendered frame* of a SwiftUI card
/// (typically a pill wrapped in `.padding(N)` shadow envelope) up to its
/// enclosing `ClickThroughHostingView`.
///
/// Why this exists: the hosting view used to estimate the card's region by
/// applying a fixed `shadowInset` to its own bounds. That worked only when
/// the panel was tightly sized to the content. For dynamically sized cards
/// (e.g. MeetingCoach where the number of suggestions changes the height)
/// the inset-from-bounds heuristic over-estimates the click area and the
/// user sees a large invisible halo that still eats clicks.
///
/// With this key:
///   1. The SwiftUI view emits its real frame via `GeometryReader` +
///      `preference(key:value:)`.
///   2. `MeetingCoachView` (or any other coach-style view) exposes an
///      `onCardFrameChange: ((CGRect) -> Void)?` callback that the parent
///      hooks up to push the rect into `ClickThroughHostingView.cardRect`.
///   3. The hosting view recomputes its tracking area to match the
///      actual card rect, so click-through works pixel-perfectly.
struct CardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        // Last writer wins. There's only ever one card per coach-style view,
        // so a simple overwrite is correct (and avoids growing the rect
        // across union calls when SwiftUI re-emits during animation).
        value = nextValue()
    }
}

/// Named SwiftUI coordinate space that pairs with `CardFrameKey`. The card's
/// `GeometryReader` measures its frame in this space; the host's outer
/// container declares it via `.coordinateSpace(name:)`. The hostingView's
/// `bounds` and this coordinate space share the same origin (top-left of
/// the SwiftUI canvas, which IS the hostingView's content rect), so the
/// emitted rect is directly usable as the tracking-area rect in AppKit.
enum CardCoordinateSpace {
    static let name = "MetaWhisp.CardHost"
}
