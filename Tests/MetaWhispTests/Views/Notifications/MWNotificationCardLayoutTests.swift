import XCTest
import AppKit
@testable import MetaWhisp

/// The card lays itself out with manual frames — there is no Auto Layout to
/// catch a mistake, because Auto Layout is what crashed Tahoe here. A wrong
/// number does not throw; it just puts text under the close button or off the
/// bottom edge, on someone's screen, silently.
@MainActor
final class MWNotificationCardLayoutTests: XCTestCase {

    private func makeCard(title: String, body: String,
                          sourceApp: String? = nil) -> MWNotificationCardView {
        MWNotificationCardView(
            notification: MWNotification(kind: .advice, title: title, body: body,
                                         sourceApp: sourceApp),
            onClose: {}, onTap: nil, onHover: { _ in })
    }

    /// Every piece has to sit inside the card it belongs to. Manual frames put
    /// content wherever the arithmetic says, including outside the view.
    func testNothingIsLaidOutBeyondTheCard() {
        let card = makeCard(title: "Ads payment declined",
                            body: "The card was refused — the campaign stops within the hour",
                            sourceApp: "Chrome")
        let box = card.bounds
        XCTAssertGreaterThan(box.height, 0)
        for view in card.subviews where !view.isHidden {
            XCTAssertTrue(box.contains(view.frame.insetBy(dx: 0.5, dy: 0.5)),
                          "\(type(of: view)) at \(view.frame) escapes \(box)")
        }
    }

    /// The provenance line stops short of the close button. It used to be
    /// given the full remaining width, so a long app name slid underneath the
    /// X and the user could not tell what they were about to click.
    func testTheSourceLineDoesNotRunUnderTheCloseButton() {
        let card = makeCard(title: "Ads payment declined", body: "Short",
                            sourceApp: "A Very Long Application Name Indeed")
        let fields = card.subviews.compactMap { $0 as? NSTextField }
        let source = try? XCTUnwrap(fields.first { $0.stringValue.contains("·") })
        let close = card.subviews.compactMap { $0 as? NSButton }.first
        guard let source, let close else { return XCTFail("card lost a subview") }
        XCTAssertLessThanOrEqual(source.frame.maxX, close.frame.minX,
                                 "the citation slides under the dismiss control")
    }

    /// A card with no body must not reserve the gap and height of one, or it
    /// carries a band of empty glass under a single line of text.
    func testABodylessCardIsShorterThanOneWithABody() {
        let withBody = makeCard(title: "Recording saved", body: "27 minutes")
        let without = makeCard(title: "Recording saved", body: "")
        XCTAssertLessThan(without.measuredHeight, withBody.measuredHeight)
        XCTAssertGreaterThan(without.measuredHeight, 0)
    }

    /// Longer text makes a taller card. The stack positions cards from this
    /// number, so a height that ignores its content overlaps its neighbour.
    func testHeightFollowsTheTextItHasToHold() {
        let short = makeCard(title: "Task added", body: "One line")
        let long = makeCard(
            title: "Task added",
            body: String(repeating: "a sentence that has to wrap several times ", count: 4))
        XCTAssertGreaterThan(long.measuredHeight, short.measuredHeight)
        XCTAssertEqual(long.frame.height, long.measuredHeight, accuracy: 0.001,
                       "the frame and the reported height must be the same number")
    }

    /// A card that asserts nothing about the screen cites nothing — the badge
    /// stands alone rather than printing an empty line beside itself.
    func testOnlyACardWithASourceShowsACitation() {
        let cited = makeCard(title: "Ads payment declined", body: "x", sourceApp: "Chrome")
        let plain = makeCard(title: "Recording saved", body: "x")
        let visibleText: (MWNotificationCardView) -> [String] = { card in
            card.subviews.compactMap { $0 as? NSTextField }
                .filter { !$0.isHidden }.map(\.stringValue)
        }
        XCTAssertTrue(visibleText(cited).contains { $0.hasPrefix("Chrome · ") })
        XCTAssertFalse(visibleText(plain).contains { $0.contains(" · ") })
    }

    /// The tint and the sheen have to be ABOVE the blur or the card is a flat
    /// frosted rectangle. Ordering them as loose sublayers of the view that
    /// also holds the blur does not achieve that: a subview has no backing
    /// layer until it joins a window, so at build time the blur is not in the
    /// sublayer stack at all and AppKit inserts it later wherever it likes.
    /// Sibling subview order is the one rule that does hold, so the gradients
    /// live on their own view added after the blur — and this pins that.
    func testTheTintAndSheenSitAboveTheBlur() {
        let card = makeCard(title: "Ads payment declined", body: "The card was refused",
                            sourceApp: "Chrome")
        card.layoutSubtreeIfNeeded()
        guard let clip = card.subviews.first else { return XCTFail("the glass is gone") }
        let blurIndex = clip.subviews.firstIndex { $0 is NSVisualEffectView }
        guard let blurIndex else { return XCTFail("no blur — the card is not glass") }

        // Whichever sibling carries the gradients must come after the blur.
        let gradientHosts = clip.subviews.enumerated().filter { _, view in
            view.layer?.sublayers?.contains(where: { $0 is CAGradientLayer }) ?? false
        }
        XCTAssertFalse(gradientHosts.isEmpty, "the glass lost its tint and sheen")
        for (index, _) in gradientHosts {
            XCTAssertGreaterThan(index, blurIndex,
                                 "the tint is behind the blur and cannot be seen")
        }
    }

    /// None of the three glass layers may win a hit test, or which one happens
    /// to be on top decides whether a click opens the comment.
    func testTheGlassNeverAnswersAClick() {
        let card = makeCard(title: "Ads payment declined", body: "The card was refused",
                            sourceApp: "Chrome")
        card.layoutSubtreeIfNeeded()
        let middle = NSPoint(x: card.bounds.midX, y: card.bounds.midY)
        for view in card.subviews where !(view is NSControl) && !(view is NSTextField) {
            XCTAssertNil(view.hitTest(middle),
                         "\(type(of: view)) intercepts clicks meant for the card")
        }
    }
}
