import XCTest
@testable import MetaWhisp

/// ITER-087 — the window's two looks as plain values, so a test can read what the screen will draw.
/// The owner's rules (2026-11-25): no blue in the product; the dark look is near-black ("depth"), panels drawn by a
/// thin edge; the light look is white frosted glass with a soft shadow; a selection in the dark look is the user's
/// own accent, whatever colour they chose in Settings.
final class DesignPaletteTests: XCTestCase {
    private let looks: [(name: String, palette: MW.Palette)] = [("dark", .dark), ("light", .light)]

    func testNoNeutralTheWindowDrawsLeansBlue() {
        for look in looks {
            for (index, colour) in look.palette.neutrals.enumerated() {
                XCTAssertLessThanOrEqual(colour.b - max(colour.r, colour.g), 0.01,
                                         "\(look.name) neutral #\(index) leans blue: \(colour)")
            }
        }
    }

    func testTheDarkWallIsNearBlackAndOpaque() {
        for colour in [MW.Palette.dark.wallTop, MW.Palette.dark.wallBottom] {
            XCTAssertLessThanOrEqual(max(colour.r, colour.g, colour.b), 0.05, "\(colour)")
            XCTAssertEqual(colour.a, 1, "the wall is the window's ground: nothing shows through it")
        }
    }

    func testTheLightWallIsLightAndOpaque() {
        for colour in [MW.Palette.light.wallTop, MW.Palette.light.wallBottom] {
            XCTAssertGreaterThanOrEqual(min(colour.r, colour.g, colour.b), 0.9, "\(colour)")
            XCTAssertEqual(colour.a, 1)
        }
    }

    func testTheLightPanelsAreWhiteFrostedGlassWithAShadow() {
        let light = MW.Palette.light
        for colour in [light.panelTop, light.panelBottom, light.sidebar] {
            XCTAssertGreaterThanOrEqual(min(colour.r, colour.g, colour.b), 0.99, "white: \(colour)")
            XCTAssertGreaterThan(colour.a, 0.5, "\(colour)")
            XCTAssertLessThan(colour.a, 1, "frosted, not solid: \(colour)")
        }
        XCTAssertGreaterThan(light.shadow.a, 0, "a white panel on a light wall needs a shadow to stand out")
    }

    func testTheDarkPanelsAreDrawnByAnEdgeAndAFaintGradientWithoutShadow() {
        let dark = MW.Palette.dark
        XCTAssertLessThan(dark.panelTop.a, 0.1)
        XCTAssertLessThan(dark.panelBottom.a, dark.panelTop.a, "the panel fades downward")
        XCTAssertGreaterThan(dark.edge.a, 0)
        XCTAssertGreaterThan(dark.highlight.a, 0)
        XCTAssertEqual(dark.shadow.a, 0)
    }

    func testASelectionIsTheAccentInTheDarkAndAWhitePillInTheLight() {
        guard case let .accent(fill, ring, _) = MW.Palette.dark.selection else {
            return XCTFail("the dark selection must be built from the user's accent")
        }
        XCTAssertGreaterThan(fill, 0)
        XCTAssertGreaterThan(ring, fill, "the ring reads stronger than the tint")
        guard case let .raised(pill, _, shadow) = MW.Palette.light.selection else {
            return XCTFail("the light selection is a raised white pill")
        }
        XCTAssertEqual(pill, RGBA.white(1))
        XCTAssertGreaterThan(shadow.a, 0)
    }

    func testTheWallGlowsInTheAccentInBothLooks() {
        XCTAssertGreaterThan(MW.Palette.dark.glow, 0)
        XCTAssertGreaterThan(MW.Palette.light.glow, 0)
        XCTAssertGreaterThan(MW.Palette.dark.glow, MW.Palette.light.glow, "the glow carries the dark look")
    }

    /// `MW.surface` and `MW.elevated` fill rows, fields and highlights inside panels on every screen. In the dark look
    /// they are see-through white, so they lift off the near-black wall instead of sitting on it as grey blocks; on
    /// onboarding's own 0.07 ground that still reads as the grey it had (decision 4: onboarding keeps its look).
    func testTheInnerFillsAreSeeThroughWhiteInTheDarkAndWhiteInTheLight() {
        let dark = MW.Palette.dark
        for colour in [dark.surface, dark.elevated] {
            XCTAssertEqual([colour.r, colour.g, colour.b], [1, 1, 1], "\(colour)")
            XCTAssertLessThan(colour.a, 0.2, "\(colour)")
        }
        XCTAssertGreaterThan(dark.elevated.a, dark.surface.a, "elevated sits above surface")
        let onOnboarding = 0.07 * (1 - dark.elevated.a) + dark.elevated.a
        XCTAssertEqual(onOnboarding, 0.18, accuracy: 0.03, "elevated over onboarding's ground stays the grey it was")
        let light = MW.Palette.light
        for colour in [light.surface, light.elevated] {
            XCTAssertGreaterThanOrEqual(min(colour.r, colour.g, colour.b), 0.99, "\(colour)")
            XCTAssertEqual(colour.a, 1, "\(colour)")
        }
    }

    /// Independent review, P2: in the light look a resting chip was a 0.99 white and the chosen one a 1.0 white, told
    /// apart by text colour alone. The resting chip sits on a grey groove, so the raised white pill stands out.
    func testALightSelectionStandsOutFromItsRestingChip() {
        let light = MW.Palette.light
        func over(_ top: RGBA, _ base: Double) -> Double { base * (1 - top.a) + top.r * top.a }
        let panel = over(light.panelTop, light.wallTop.r)
        let resting = over(light.rest, panel)
        guard case let .raised(fill, _, _) = light.selection else { return XCTFail("light selection is a pill") }
        XCTAssertGreaterThanOrEqual(over(fill, panel) - resting, 0.04, "a chosen chip is visibly brighter than a resting one")
    }

    func testADarkRestingChipIsTheInnerFill() {
        XCTAssertEqual(MW.Palette.dark.rest, MW.Palette.dark.surface)
    }

    /// Re-review, P2: with Mono the accent is the primary text colour — white in the dark look — so a switch tinted
    /// with it is a white track under a white knob. Controls take a grey for Mono and the chosen colour otherwise.
    func testMonoIsTheOnlyAccentThatControlsTintGrey() {
        XCTAssertTrue(MW.accentIsMono("mono"))
        XCTAssertTrue(MW.accentIsMono("no-such-preset"), "an unknown id falls back to Mono")
        for preset in ["warmOrange", "electric", "mint", "violet"] {
            XCTAssertFalse(MW.accentIsMono(preset), preset)
        }
    }

    /// Re-review, P2: a standalone chip at rest (`.outline`) sat transparent on a white panel in the light look and read
    /// like the white selected pill; in the light look it rests on the grey groove too.
    func testALightOutlineChipRestsOnTheGroove() {
        XCTAssertEqual(MW.Palette.light.outlineRest, MW.Palette.light.rest)
        XCTAssertEqual(MW.Palette.dark.outlineRest, .clear, "the dark look's resting chip is drawn by its edge")
    }

    /// Owner on the test build (2026-11-25): "more black, less green" — the popover was flooded green. The
    /// dark wall is black with one faint accent glow in a corner; no second glow.
    func testTheDarkWallIsBlackWithOneFaintGlow() {
        XCTAssertLessThanOrEqual(MW.Palette.dark.glow, 0.16)
        XCTAssertEqual(MW.Palette.dark.lowGlow, 0, "one glow, in the top-right corner")
        XCTAssertLessThanOrEqual(MW.Palette.light.glow, MW.Palette.dark.glow)
    }

    /// The glow reaches a corner of any surface, never the whole of it: a fixed 520 pt glow covered the 320 pt popover.
    func testTheGlowStaysInACornerOfAnySurface() {
        for size in [CGSize(width: 320, height: 330), CGSize(width: 960, height: 640), CGSize(width: 1600, height: 1000)] {
            XCTAssertLessThanOrEqual(PageWash.glowRadius(for: size), max(size.width, size.height) * 0.5, "\(size)")
        }
        XCTAssertLessThan(PageWash.glowRadius(for: CGSize(width: 320, height: 330)), 200, "the popover's glow is a corner")
    }

    /// Text on an accent fill (the Get Pro button, an Active badge) stays readable on every accent: dark on a light
    /// accent, white on a dark one; Mono is white in the dark look and black in the light one.
    func testTextOnTheAccentIsReadableOnEveryAccent() {
        XCTAssertTrue(MW.accentTextIsDark("mint", dark: true))
        XCTAssertTrue(MW.accentTextIsDark("warmOrange", dark: false))
        XCTAssertFalse(MW.accentTextIsDark("violet", dark: true))
        XCTAssertFalse(MW.accentTextIsDark("electric", dark: false))
        XCTAssertTrue(MW.accentTextIsDark("mono", dark: true), "Mono's fill is white in the dark look")
        XCTAssertFalse(MW.accentTextIsDark("mono", dark: false), "and black in the light look")
    }

    func testThePaletteFollowsTheAppearance() {
        XCTAssertEqual(MW.Palette.of(dark: true), .dark)
        XCTAssertEqual(MW.Palette.of(dark: false), .light)
        XCTAssertNotEqual(MW.Palette.dark, MW.Palette.light)
    }
}
