import Observation
import SwiftUI

/// MetaWhisp Design System — **Liquid Glass** (replaces the prior BLOCKS style).
///
/// Philosophy:
/// - Two looks from one palette (`MW.Palette`, ITER-087): dark — a near-black wall, panels drawn by a thin edge;
///   light — white frosted panels with a soft shadow. No blue. One accent, the user's own choice.
/// - Apple type scale: SF Pro for prose; SF Mono **only** for tabular data
///   (numbers, timestamps, percentages). The legacy `MW.mono*` tokens are now
///   sans-serif so existing call sites get readable text without rewrites.
/// - 4-pt spacing grid. Continuous (squircle) corner curves.
///
/// API stability: every public symbol from the prior BLOCKS system is preserved
/// to keep the 78+ existing call sites compiling. The values + modifier
/// implementations change underneath. New tokens (`dataLarge`, `dataMedium`,
/// `dataSmall`, `glassChip`) are additive.
enum MW {

    // MARK: - Appearance

    /// Returns true if current appearance is dark. Reading it registers the look as a dependency (`LookState`).
    static var isDark: Bool {
        _ = LookState.shared.revision
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Color tokens
    //
    // Kept as `Color` so direct `.background(MW.surface)` call sites still work.
    // Where possible new code uses material-based modifiers (`mwCard`, `glassChip`).

    /// Onboarding's own ground. The window, the popover and the sheets stand on `PageWash` instead (ITER-087).
    static var bg: Color { isDark ? Color(w: 0.07) : Color(w: 0.95) }
    /// Surface — a fill inside a panel (a field, a row). See-through white in the dark look (ITER-087).
    static var surface: Color { palette.surface.color }
    /// Slightly raised surface — selected rows, highlighted chips. See-through white in the dark look (ITER-087).
    static var elevated: Color { palette.elevated.color }
    /// Hairline border — adaptive low-opacity primary.
    static var border: Color { Color.primary.opacity(0.10) }
    /// Stronger border — selected / focused.
    static var borderLight: Color { Color.primary.opacity(0.20) }

    // Text — adaptive via Color.primary opacity.
    static var textPrimary: Color { Color.primary }
    static var textSecondary: Color { Color.primary.opacity(0.72) }
    static var textMuted: Color { Color.primary.opacity(0.50) }
    static var textDim: Color { Color.primary.opacity(0.32) }

    /// Faint translucent fill — used for inline highlights inside panels.
    static var subtle: Color { Color.primary.opacity(0.06) }
    static var cardBg: Color { surface }

    // MARK: - New Liquid Glass tokens (design spec 2026-04-26)

    /// Hairline divider — thinner / fainter than `border`. Used for in-panel
    /// row separators. Mirrors `--hairline` in tokens.css.
    static var hairlineColor: Color { Color.primary.opacity(0.06) }

    /// Inner specular highlight color (top-down white gradient on glass cards).
    /// Slightly stronger in light mode to read against bright wash. Mirrors
    /// `--rim-inner` in tokens.css.
    static var rimInner: Color { isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.55) }

    // MARK: - Accent (5 presets, runtime-switchable)

    /// Brand accent. Reads from `AppSettings.shared.accentColor` so the user can
    /// pick from 5 presets in Settings. New users get `mint` (ITER-087); `mono`
    /// is the primary text colour.
    static var accent: Color {
        _ = LookState.shared.revision
        return accentPresetColor(AppSettings.shared.accentColor)
    }

    /// 16% alpha tint of `accent` — soft fill for chips marked active /
    /// CTA backgrounds / accent badges. Mirrors `--accent-soft`.
    static var accentSoft: Color { accent.opacity(0.16) }

    /// 45% alpha tint of `accent` — rim for accent-soft backgrounds. Mirrors `--accent-rim`.
    static var accentRim: Color { accent.opacity(0.45) }

    /// The window's and the popover's "on / ready / active / pro" colour: the user's accent (owner, 2026-11-25:
    /// "in Violet there must be no green; green only in Green"). The recording indicator and onboarding keep
    /// their fixed green, `idle` (decision 4).
    static var ok: Color { accent }

    /// Text or a glyph drawn on an accent fill (the Get Pro button, an Active badge).
    static var onAccent: Color { accentTextIsDark(AppSettings.shared.accentColor, dark: isDark) ? .black : .white }

    /// Whether text on a fill of this accent is dark: on Mint and Orange (light accents) and on Mono in the dark look
    /// (white there); white on Electric, Violet and Mono in the light look (black there).
    static func accentTextIsDark(_ preset: String, dark: Bool) -> Bool {
        if accentIsMono(preset) { return dark }
        return preset == "mint" || preset == "warmOrange"
    }

    /// Whether a preset id is Mono — "mono" or an unknown id, which falls back to it.
    static func accentIsMono(_ preset: String) -> Bool {
        !["warmOrange", "electric", "mint", "violet"].contains(preset)
    }

    /// The tint of system controls (switches, progress) and of the app's own switch: the accent, except for Mono,
    /// whose accent is the primary text colour — white in the dark look, so an "on" switch would be a white track
    /// under a white knob. Mono controls take a mid grey (ITER-087 re-review).
    static var controlTint: Color {
        accentIsMono(AppSettings.shared.accentColor) ? Color.primary.opacity(0.55) : accent
    }

    /// Resolves a preset id to its `Color`. Public so a future Settings picker
    /// can show the swatches. Unknown id falls back to `mono`.
    static func accentPresetColor(_ preset: String) -> Color {
        switch preset {
        case "warmOrange": return Color(red: 0.88, green: 0.54, blue: 0.28)
        case "electric":   return Color(red: 0.30, green: 0.55, blue: 1.00)
        case "mint":       return Color(red: 0.10, green: 0.78, blue: 0.55)
        case "violet":     return Color(red: 0.65, green: 0.40, blue: 1.00)
        case "mono":       return Color.primary
        default:           return Color.primary
        }
    }

    /// Stable id list for the Settings picker / future Appearance row.
    /// Order matches the design spec swatches.
    static let accentPresets: [(id: String, label: String)] = [
        ("mono",       "Mono"),
        ("warmOrange", "Orange"),
        ("electric",   "Electric"),
        ("mint",       "Mint"),
        ("violet",     "Violet"),
    ]

    // MARK: - Status colors
    //
    // Spec hex values (Apple system palette) replace the previous `Color.red /
    // .orange / .blue / .green` aliases — those produced inconsistent shades
    // across light/dark and lost the slight desaturation the spec asks for.

    /// Recording / live / alert. `--status-alert` #FF453A.
    static let live = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let recording = Color(red: 1.00, green: 0.27, blue: 0.23)
    /// Mid-pipeline state. `--status-warn` #FF9F0A.
    static let processing = Color(red: 1.00, green: 0.62, blue: 0.04)
    /// Post-processing / informational. `--status-info` #5AC8FA.
    static let postProcess = Color(red: 0.35, green: 0.78, blue: 0.98)
    /// Idle / ready / success. `--status-ok` #34C759.
    static let idle = Color(red: 0.20, green: 0.78, blue: 0.35)

    // MARK: - Typography
    //
    // Sans-serif (SF Pro) for prose. The legacy `mono*` token names point to
    // sans variants so existing prose call sites stop displaying as terminal
    // output. Use the `data*` tokens explicitly when you need mono for numbers.

    /// Body text — paragraphs, descriptions, chat bodies, default for most strings.
    static let mono = Font.system(size: 13, weight: .regular)
    /// Caption — secondary meta, hints, footnotes.
    static let monoSm = Font.system(size: 11, weight: .regular)
    /// Card heading — within cards / groups.
    static let monoLg = Font.system(size: 16, weight: .semibold)
    /// Section title — between card heading and display.
    static let monoXl = Font.system(size: 22, weight: .semibold)
    /// Display — big page title, one per screen.
    static let monoTitle = Font.system(size: 28, weight: .bold)
    /// Tiny caps label — tracked, ≤2 words. Uppercase pills.
    static let label = Font.system(size: 10, weight: .semibold)
    /// Micro-label — a section header or a tile caption, in SF Mono caps (`mwBadge`, ITER-087).
    static let microLabel = Font.system(size: 9.5, weight: .semibold, design: .monospaced)
    /// Medium caps label — slightly larger pill / chip.
    static let labelMd = Font.system(size: 12, weight: .medium)

    // Legacy aliases — same behaviors as above.
    static let title = monoXl
    static let headline = monoLg
    static let body = mono
    static let caption = monoSm
    static let micro = Font.system(size: 10, weight: .regular)

    // Data — numbers / timestamps / percentages. The big number is SF Pro bold with digits of one width
    // (ITER-087); the small ones stay monospace.
    static let dataLarge = Font.system(size: 26, weight: .bold).monospacedDigit()
    static let dataMedium = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let dataSmall = Font.system(size: 11, weight: .regular, design: .monospaced)

    // MARK: - Spacing (4-pt grid)
    static let sp2: CGFloat = 2
    static let sp4: CGFloat = 4
    static let sp6: CGFloat = 6
    static let sp8: CGFloat = 8
    static let sp10: CGFloat = 10
    static let sp12: CGFloat = 12
    static let sp16: CGFloat = 16
    static let sp20: CGFloat = 20
    static let sp24: CGFloat = 24
    static let sp32: CGFloat = 32
    static let sp40: CGFloat = 40
    // Legacy aliases
    static let spaceXs: CGFloat = 2
    static let spaceSm: CGFloat = 4
    static let spaceMd: CGFloat = 8
    static let spaceLg: CGFloat = 16
    static let spaceXl: CGFloat = 24

    // MARK: - Radii (continuous / squircle)
    /// Chip / pill / inline button.
    static let rTiny: CGFloat = 8
    /// Row-level / small card.
    static let rSmall: CGFloat = 14
    /// Standard card.
    static let rMedium: CGFloat = 20
    /// Hero / sidebar container.
    static let rLarge: CGFloat = 28
    // Legacy names — values raised so existing call sites pick up the new corners.
    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 14
    static let radiusLg: CGFloat = 20

    // MARK: - Lines
    static let hairline: CGFloat = 0.5
    static let thinBorder: CGFloat = 1.0

    // MARK: - State color
    //
    // Pills design spec § 8 STAGE_META mapping:
    //   idle          → status-ok       (green  #34C759)
    //   recording     → status-alert    (red    #FF453A)   ← live recording
    //   processing    → status-info     (blue   #5AC8FA)   ← transcribing
    //   postProcessing→ accent          (warm orange / preset) ← translating
    // Recording is the user-action state → red. Transcribing is informational
    // (waiting on Whisper) → blue. Translating is "we're producing the user's
    // own voice in another language" → accent (their personal color).
    static func stateColor(_ stage: String) -> Color {
        switch stage {
        case "recording": return recording           // red
        case "processing": return postProcess        // blue (transcribing per new spec)
        case "postProcessing": return accent         // accent (translating per new spec)
        default: return idle                         // green
        }
    }

    // MARK: - Theme
    static func applyTheme(_ theme: String) {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil // follows system
        }
    }
}

// MARK: - Look state (ITER-087)

/// What every colour token depends on — the accent the user chose and the app's appearance — as one observable
/// revision. `MW.accent` and `MW.isDark` (and so every token built on them: `MW.ok`, `MW.palette`, `MW.surface` …)
/// read `revision`, so SwiftUI draws again any view that drew with a token when either changes. Read as plain statics,
/// the tokens were invisible to SwiftUI: after the owner chose Orange the meeting-minutes bar stayed violet
/// (2026-11-25), and only the views that happened to observe the settings followed.
@Observable
final class LookState {
    static let shared = LookState()

    /// Bumped whenever the accent or the appearance changes.
    private(set) var revision = 0

    @ObservationIgnored private var appearance: NSKeyValueObservation?
    @ObservationIgnored private var accent: DefaultsKeyObserver?

    private init() {
        appearance = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.changed()
        }
        accent = DefaultsKeyObserver(key: "accentColor") { [weak self] in self?.changed() }
    }

    private func changed() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { [weak self] in self?.revision += 1 } }
    }
}

/// Calls back when one UserDefaults key changes (an `@AppStorage` write included).
private final class DefaultsKeyObserver: NSObject {
    private let key: String
    private let onChange: () -> Void

    init(key: String, onChange: @escaping () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit { UserDefaults.standard.removeObserver(self, forKeyPath: key) }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onChange()
    }
}

// MARK: - Palette (ITER-087)
//
// The window's two looks as plain numbers, so a test can read what the screen will draw.
// Dark ("depth"): a near-black wall, panels drawn by a faint white gradient and a thin edge, no shadow.
// Light: a light wall, white frosted panels with a soft shadow.
// Only neutrals live here — no blue (owner, 2026-11-25). The accent is the user's own choice in Settings and is
// applied on top through `MW.accent`; the palette says only how strongly.

/// A colour as sRGB numbers, 0…1.
struct RGBA: Equatable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static func white(_ a: Double) -> RGBA { RGBA(1, 1, 1, a) }
    static func black(_ a: Double) -> RGBA { RGBA(0, 0, 0, a) }
    static let clear = RGBA(0, 0, 0, 0)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

extension MW {
    /// How a selected row, tab or tile is marked.
    enum Selection: Equatable {
        /// A tint of the user's accent with a ring of it, and a faint glow (dark).
        case accent(fill: Double, ring: Double, glow: Double)
        /// A raised white pill with a hairline ring and a soft shadow (light).
        case raised(fill: RGBA, ring: RGBA, shadow: RGBA)
    }

    struct Palette: Equatable {
        /// The window's ground, top to bottom; opaque.
        let wallTop: RGBA
        let wallBottom: RGBA
        /// Accent opacity of the glow at the wall's top right.
        let glow: Double
        /// Accent opacity of the second, fainter glow at the bottom left.
        let lowGlow: Double
        /// A neutral shade at the bottom left.
        let shade: RGBA
        /// A panel's fill, top to bottom.
        let panelTop: RGBA
        let panelBottom: RGBA
        /// A panel's outline and its top inner highlight.
        let edge: RGBA
        let highlight: RGBA
        /// The sidebar's fill.
        let sidebar: RGBA
        /// A panel's drop shadow (clear in the dark look).
        let shadow: RGBA
        /// The groove a segmented control's segments sit in.
        let track: RGBA
        /// Fills inside a panel: `MW.surface` (a field, a row) and `MW.elevated` (a raised row or chip).
        let surface: RGBA
        let elevated: RGBA
        /// A selectable chip or button at rest: the inner fill in the dark look, a grey groove in the light look, so
        /// the raised white pill of a selection stands out from it.
        let rest: RGBA
        /// A standalone chip at rest: clear in the dark look (its edge draws it), the groove in the light look.
        let outlineRest: RGBA
        let selection: Selection

        /// Every neutral this look draws.
        var neutrals: [RGBA] {
            var all = [wallTop, wallBottom, shade, panelTop, panelBottom, edge, highlight, sidebar, shadow, track,
                       surface, elevated, rest, outlineRest]
            if case let .raised(fill, ring, shadow) = selection { all += [fill, ring, shadow] }
            return all
        }

        static let dark = Palette(
            wallTop: RGBA(0.027, 0.031, 0.039),
            wallBottom: RGBA(0.027, 0.031, 0.039),
            glow: 0.14,
            lowGlow: 0,
            shade: .clear,
            panelTop: .white(0.055),
            panelBottom: .white(0.018),
            edge: .white(0.08),
            highlight: .white(0.07),
            sidebar: .white(0.035),
            shadow: .clear,
            track: .white(0.04),
            surface: .white(0.06),
            elevated: .white(0.10),
            rest: .white(0.06),
            outlineRest: .clear,
            selection: .accent(fill: 0.16, ring: 0.50, glow: 0.22)
        )

        static let light = Palette(
            wallTop: RGBA(0.973, 0.976, 0.973),
            wallBottom: RGBA(0.925, 0.933, 0.929),
            glow: 0.08,
            lowGlow: 0,
            shade: .black(0.05),
            panelTop: .white(0.74),
            panelBottom: .white(0.74),
            edge: .black(0.06),
            highlight: .white(1),
            sidebar: .white(0.60),
            shadow: .black(0.05),
            track: .black(0.05),
            surface: RGBA(0.99, 0.99, 0.99),
            elevated: .white(1),
            rest: .black(0.045),
            outlineRest: .black(0.045),
            selection: .raised(fill: .white(1), ring: .black(0.06), shadow: .black(0.10))
        )

        static func of(dark: Bool) -> Palette { dark ? .dark : .light }
    }

    /// The look for the app's current appearance.
    static var palette: Palette { .of(dark: isDark) }
}

// MARK: - Sentence case (ITER-087)

extension String {
    /// "THIS WEEK" or "this week" → "This week": chips and tabs read in sentence case. For labels that come from an
    /// enum's raw value or from data; the value itself stays as it is.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst().lowercased() }
}

// MARK: - Color convenience

extension Color {
    init(w: CGFloat, a: CGFloat = 1.0) {
        self.init(red: w, green: w, blue: w, opacity: a)
    }
}

// MARK: - Panel modifier (ITER-087)
//
// `mwCard` draws a panel from the palette: in the dark look a faint white
// gradient, a thin edge and a top highlight, no shadow; in the light look
// white frosted glass with a soft shadow. `.hero` is the sidebar.

enum GlassElevation { case flat, raised, hero }

struct MWCardModifier: ViewModifier {
    var radius: CGFloat = MW.rMedium
    var elevation: GlassElevation = .raised
    /// The look is read from the environment, so a theme change draws the panel again.
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let look = MW.Palette.of(dark: colorScheme == .dark)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .clipShape(shape)
            .background {
                shape
                    .fill(elevation == .hero
                          ? AnyShapeStyle(look.sidebar.color)
                          : AnyShapeStyle(LinearGradient(colors: [look.panelTop.color, look.panelBottom.color],
                                                         startPoint: .top, endPoint: .bottom)))
                    .modifier(PanelShadowModifier(elevation: elevation, shadow: look.shadow))
            }
            .overlay {
                ZStack {
                    // The top highlight: an inner line that fades out down the sides.
                    shape.strokeBorder(
                        LinearGradient(colors: [look.highlight.color, look.highlight.color.opacity(0)],
                                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)),
                        lineWidth: 1)
                    shape.strokeBorder(look.edge.color, lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
    }
}

/// The panel's drop shadow, on its shape only: none in the dark look (the edge carries the panel), a close one and
/// a wide soft one in the light look, where a white panel on a light wall needs it to stand out.
private struct PanelShadowModifier: ViewModifier {
    let elevation: GlassElevation
    let shadow: RGBA

    func body(content: Content) -> some View {
        let lit = shadow.a > 0
        let wide: CGFloat = elevation == .hero ? 30 : 22
        return content
            .shadow(color: lit ? Color.black.opacity(0.04) : .clear, radius: 2, x: 0, y: 1)
            .shadow(color: lit && elevation != .flat ? shadow.color : .clear, radius: wide, x: 0, y: wide / 3)
    }
}

/// Micro-label — a section header or a tile caption: SF Mono caps, tracked (ITER-087). It wins the room it needs
/// beside other text, and in a box too narrow for it it shrinks a little before it would be cut ("TRANSC…").
struct MWBadgeModifier: ViewModifier {
    var color: Color = MW.textMuted
    func body(content: Content) -> some View {
        content
            .font(MW.microLabel)
            .foregroundStyle(color)
            .textCase(.uppercase)
            .tracking(0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
    }
}

/// Chip — small interactive surface (tab, pill, secondary button).
struct MWChipModifier: ViewModifier {
    var selected: Bool = false
    var radius: CGFloat = MW.rTiny
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MW.sp10)
            .padding(.vertical, 5)
            .mwSelectable(selected, radius: radius, resting: .surface)
    }
}

/// The capsule a segmented group sits in; its look follows the theme (see `mwSegmentTrack()`).
struct MWSegmentTrackModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let look = MW.Palette.of(dark: colorScheme == .dark)
        return content
            .padding(3)
            .background(Capsule(style: .continuous).fill(look.track.color))
            .overlay(Capsule(style: .continuous).strokeBorder(look.edge.color, lineWidth: 1))
    }
}

// MARK: - Selection (ITER-087)
//
// One owner for "this tab / chip / tile / row is the chosen one" (SelectionLookGuardTests): in the dark look the
// user's accent tinted with a ring of it and a faint glow; in the light look a raised white pill. Unselected, a
// surface shows its resting look.

/// What an unselected selectable surface shows.
enum MWResting {
    /// Nothing: a row in a list.
    case none
    /// A thin edge: a standalone chip.
    case outline
    /// The inner fill with an edge: a button or a chip on a panel.
    case surface
    /// A panel: a tile.
    case panel
}

struct MWSelectableModifier: ViewModifier {
    let selected: Bool
    var radius: CGFloat = MW.rTiny
    var resting: MWResting = .outline
    /// The accent and the look are read here as dependencies, so changing either draws the selection again. Read
    /// from the static tokens, a selection kept the old accent after the user picked another (owner, 2026-11-25).
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let look = MW.Palette.of(dark: colorScheme == .dark)
        let accent = MW.accentPresetColor(settings.accentColor)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content.background {
            if selected {
                switch look.selection {
                case let .accent(fill, ring, glow):
                    shape.fill(accent.opacity(fill))
                        .overlay(shape.strokeBorder(accent.opacity(ring), lineWidth: 1))
                        .shadow(color: accent.opacity(glow), radius: 8)
                case let .raised(fill, ring, shadow):
                    // A tile (resting as a panel) is as white as the pill, so it is marked by a ring of the accent.
                    shape.fill(fill.color)
                        .overlay(resting == .panel
                                 ? shape.strokeBorder(accent.opacity(0.55), lineWidth: 1.5)
                                 : shape.strokeBorder(ring.color, lineWidth: 0.5))
                        .shadow(color: shadow.color, radius: 3, x: 0, y: 1)
                }
            } else {
                switch resting {
                case .none:
                    Color.clear
                case .outline:
                    shape.fill(look.outlineRest.color).overlay(shape.strokeBorder(look.edge.color, lineWidth: 1))
                case .surface:
                    shape.fill(look.rest.color).overlay(shape.strokeBorder(look.edge.color, lineWidth: 1))
                case .panel:
                    shape.fill(LinearGradient(colors: [look.panelTop.color, look.panelBottom.color],
                                              startPoint: .top, endPoint: .bottom))
                        .overlay(shape.strokeBorder(look.edge.color, lineWidth: 1))
                }
            }
        }
    }
}

extension View {
    /// Glass panel — thin material + continuous corner + specular rim + shadow.
    /// Replaces the prior BLOCKS card. Keep the same call sites.
    func mwCard(radius: CGFloat = MW.rMedium,
                elevation: GlassElevation = .raised) -> some View {
        modifier(MWCardModifier(radius: radius, elevation: elevation))
    }
    /// Tracked uppercase label badge.
    func mwBadge(color: Color = MW.textMuted) -> some View {
        modifier(MWBadgeModifier(color: color))
    }
    /// Alias of `mwCard` — preserved for legacy call sites.
    func blocksPanel(radius: CGFloat = MW.rMedium) -> some View {
        modifier(MWCardModifier(radius: radius, elevation: .raised))
    }
    /// Alias of `mwBadge` — preserved for legacy call sites.
    func blocksLabel() -> some View {
        modifier(MWBadgeModifier())
    }
    /// Glass chip — small interactive surface for tabs, pills, secondary buttons.
    func glassChip(selected: Bool = false, radius: CGFloat = MW.rTiny) -> some View {
        modifier(MWChipModifier(selected: selected, radius: radius))
    }
    /// A segmented group (board 10): the options of one choice sit in one capsule on the palette's groove; the chosen
    /// one is drawn by `mwSelectable(…, radius: 999, resting: .none)`, the others have no box of their own.
    func mwSegmentTrack() -> some View {
        modifier(MWSegmentTrackModifier())
    }
    /// A selectable surface: the palette's selection when `selected`, else its resting look (ITER-087).
    func mwSelectable(_ selected: Bool, radius: CGFloat = MW.rTiny, resting: MWResting = .outline) -> some View {
        modifier(MWSelectableModifier(selected: selected, radius: radius, resting: resting))
    }
}

/// Hairline horizontal divider — for use inside glass panels (between rows).
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(MW.border)
            .frame(height: 0.5)
    }
}

// MARK: - Keycap (kept for hotkey labels)

struct Keycap: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let look = MW.Palette.of(dark: colorScheme == .dark)
        return
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(MW.textPrimary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(look.elevated.color)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(look.edge.color, lineWidth: 1)
            }
    }
}

// MARK: - BlocksButton (kept for legacy call sites; restyled as glass chip-like)

struct BlocksButton: View {
    let label: String
    var icon: String? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MW.sp4) {
                if let icon { Image(systemName: icon).font(.system(size: 10)) }
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isActive ? Color.primary : MW.textSecondary)
            .padding(.horizontal, MW.sp12)
            .padding(.vertical, MW.sp6)
            .mwSelectable(isActive, radius: MW.rTiny, resting: .surface)
        }
        .buttonStyle(.plain)
    }
}
