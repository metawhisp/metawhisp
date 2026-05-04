import SwiftUI

/// MetaWhisp Design System — **Liquid Glass** (replaces the prior BLOCKS style).
///
/// Philosophy:
/// - Monochrome translucent panels — depth via material weight + continuous corners
///   + subtle rim, NOT via colored fills. One brand accent only.
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

    /// Returns true if current appearance is dark.
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Color tokens
    //
    // Kept as `Color` so direct `.background(MW.surface)` call sites still work.
    // Where possible new code uses material-based modifiers (`mwCard`, `glassChip`).

    /// Page background — soft monochrome wash. Supports the translucent panels above.
    static var bg: Color { isDark ? Color(w: 0.07) : Color(w: 0.95) }
    /// Surface — used directly when material isn't applicable (e.g. solid pickers).
    static var surface: Color { isDark ? Color(w: 0.13) : Color(w: 0.99) }
    /// Slightly raised surface — selected rows, highlighted chips.
    static var elevated: Color { isDark ? Color(w: 0.18) : Color(w: 1.0) }
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

    /// Sidebar / segmented-control SELECTED-row fill. Distinct from `subtle`:
    /// `subtle` is a generic in-panel highlight, `selectFill` is the canonical
    /// "this row is active" treatment. Mirrors `--select-fill`.
    static var selectFill: Color { Color.primary.opacity(0.10) }

    /// Border for the selected row. Mirrors `--select-rim`.
    static var selectRim: Color { Color.primary.opacity(0.16) }

    /// Inner specular highlight color (top-down white gradient on glass cards).
    /// Slightly stronger in light mode to read against bright wash. Mirrors
    /// `--rim-inner` in tokens.css.
    static var rimInner: Color { isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.55) }

    // MARK: - Accent (5 presets, runtime-switchable)

    /// Brand accent. Reads from `AppSettings.shared.accentColor` so the user can
    /// pick from 5 presets in Settings → Appearance. Default preset `mono` keeps
    /// the existing monochrome look (textPrimary) for back-compat — switching to
    /// `warmOrange` / `electric` / `mint` / `violet` colors every accent-using surface.
    static var accent: Color {
        accentPresetColor(AppSettings.shared.accentColor)
    }

    /// 16% alpha tint of `accent` — soft fill for chips marked active /
    /// CTA backgrounds / accent badges. Mirrors `--accent-soft`.
    static var accentSoft: Color { accent.opacity(0.16) }

    /// 45% alpha tint of `accent` — rim for accent-soft backgrounds. Mirrors `--accent-rim`.
    static var accentRim: Color { accent.opacity(0.45) }

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
    /// Medium caps label — slightly larger pill / chip.
    static let labelMd = Font.system(size: 12, weight: .medium)

    // Legacy aliases — same behaviors as above.
    static let title = monoXl
    static let headline = monoLg
    static let body = mono
    static let caption = monoSm
    static let micro = Font.system(size: 10, weight: .regular)

    // Data — monospace, ONLY for numbers / timestamps / percentages.
    static let dataLarge = Font.system(size: 26, weight: .semibold, design: .monospaced)
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

// MARK: - Color convenience

extension Color {
    init(w: CGFloat, a: CGFloat = 1.0) {
        self.init(red: w, green: w, blue: w, opacity: a)
    }
}

// MARK: - Glass panel modifier
//
// `mwCard` was the BLOCKS card (solid `MW.surface` fill + Rectangle border).
// It now renders a Liquid Glass panel: thin material + continuous corner +
// subtle specular rim + soft shadow. Three elevations.

enum GlassElevation { case flat, raised, hero }

private extension GlassElevation {
    var material: Material {
        switch self {
        case .flat:   return .ultraThinMaterial
        case .raised: return .thinMaterial
        case .hero:   return .regularMaterial
        }
    }
}

struct MWCardModifier: ViewModifier {
    var radius: CGFloat = MW.rMedium
    var elevation: GlassElevation = .raised

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(elevation.material)
                    // Specular top highlight — what makes glass read as glass.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.30),
                                         Color.white.opacity(0.04),
                                         Color.white.opacity(0)],
                                startPoint: .top, endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .blendMode(.overlay)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(MW.border, lineWidth: 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(GlassShadowsModifier(elevation: elevation))
    }
}

/// Per-elevation shadow stack lifted from `tokens.css`. Spec requires two
/// shadow layers for `.raised` and `.hero` (a wide soft halo + a tight close
/// one) to read as glass against any wash. Dark theme uses heavier shadows
/// because the wash itself is dark and would otherwise eat the elevation.
///
/// Values mirror tokens.css `--shadow-flat / --shadow-raised / --shadow-hero`.
/// SwiftUI `.shadow()` modifiers chain — each adds a layer behind the previous.
private struct GlassShadowsModifier: ViewModifier {
    let elevation: GlassElevation

    @ViewBuilder
    func body(content: Content) -> some View {
        let dark = MW.isDark
        switch elevation {
        case .flat:
            content
                .shadow(color: .black.opacity(dark ? 0.20 : 0.04), radius: 2, x: 0, y: 1)
        case .raised:
            content
                .shadow(color: .black.opacity(dark ? 0.36 : 0.10), radius: 24, x: 0, y: 8)
                .shadow(color: .black.opacity(dark ? 0.24 : 0.06), radius: 6,  x: 0, y: 2)
        case .hero:
            content
                .shadow(color: .black.opacity(dark ? 0.55 : 0.16), radius: 60, x: 0, y: 24)
                .shadow(color: .black.opacity(dark ? 0.35 : 0.08), radius: 16, x: 0, y: 6)
        }
    }
}

/// Small uppercase tracked label.
struct MWBadgeModifier: ViewModifier {
    var color: Color = MW.textMuted
    func body(content: Content) -> some View {
        content
            .font(MW.label)
            .foregroundStyle(color)
            .textCase(.uppercase)
            .tracking(1.2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if selected {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(selected ? 0.22 : 0.10), lineWidth: 0.5)
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
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(MW.textPrimary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(MW.border, lineWidth: 0.5)
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
                Text(label).font(MW.label).tracking(1.0).textCase(.uppercase)
            }
            .foregroundStyle(isActive ? Color.primary : MW.textSecondary)
            .padding(.horizontal, MW.sp12)
            .padding(.vertical, MW.sp6)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if isActive {
                        RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                    RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isActive ? 0.24 : 0.10), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
