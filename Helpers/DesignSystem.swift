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
    static var accent: Color { textPrimary }

    // Status — only for state dots / inline indicators, never as panel fills.
    static let live = Color.red
    static let recording = Color.red
    static let processing = Color.orange
    static let postProcess = Color.blue
    static let idle = Color.green

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
    static func stateColor(_ stage: String) -> Color {
        switch stage {
        case "recording": return recording
        case "processing": return processing
        case "postProcessing": return postProcess
        default: return idle
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
    var shadowOpacity: Double {
        switch self { case .flat: 0.04; case .raised: 0.10; case .hero: 0.16 }
    }
    var shadowRadius: CGFloat {
        switch self { case .flat: 4; case .raised: 16; case .hero: 28 }
    }
    var shadowY: CGFloat {
        switch self { case .flat: 1; case .raised: 6; case .hero: 12 }
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
            .shadow(color: Color.black.opacity(elevation.shadowOpacity),
                    radius: elevation.shadowRadius, x: 0, y: elevation.shadowY)
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
