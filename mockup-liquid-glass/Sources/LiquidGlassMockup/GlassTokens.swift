import SwiftUI

/// Liquid Glass design tokens.
///
/// Philosophy:
/// - Monochrome primary surfaces — glass is white/gray translucency, never tinted
///   rainbow. Tints are reserved for STATUS (green=ok, red=alert) and one brand accent.
/// - Apple type scale: SF Pro Display for large titles, SF Pro Text for body,
///   SF Mono only for tabular data (numbers, timestamps, counts).
/// - Depth through HIERARCHY (material weight, corner radius, shadow) — not color.
/// - 4-pt spacing grid. Continuous (squircle) corners.
enum Glass {
    // MARK: - Spacing (4-pt grid)
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s10: CGFloat = 10
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s40: CGFloat = 40

    // MARK: - Corner radii (continuous / squircle)
    static let rTiny: CGFloat = 8        // inline button, pill
    static let rSmall: CGFloat = 14      // chip, row
    static let rMedium: CGFloat = 20     // card
    static let rLarge: CGFloat = 28      // hero / container

    // MARK: - Typography
    // Apple type scale adapted. Sans-serif for all prose; monospace only for data.

    /// Display — large page titles, one per screen. SF Pro Display auto-kicked in ≥20pt.
    static let display = Font.system(size: 28, weight: .bold)
    /// Section heading — card titles, screen sub-sections.
    static let h1 = Font.system(size: 20, weight: .semibold)
    /// Card heading — within cards / groups.
    static let h2 = Font.system(size: 16, weight: .semibold)
    /// Body prose — paragraphs, descriptions, chat bubbles.
    static let body = Font.system(size: 13, weight: .regular)
    /// Body emphasized — for item labels that carry weight.
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    /// Caption — secondary meta, timestamps when NOT numeric-critical.
    static let caption = Font.system(size: 11, weight: .regular)
    /// Tiny caps label — tracked, ≤2 words. Uppercase section tags, category pills.
    static let label = Font.system(size: 10, weight: .semibold)

    /// Large data — stat values (12, 12.4k, 3). Tabular for row alignment.
    static let dataLarge = Font.system(size: 26, weight: .semibold, design: .monospaced)
    /// Medium data — inline counts, HH:mm.
    static let dataMedium = Font.system(size: 14, weight: .medium, design: .monospaced)
    /// Small data — percentages, compact timestamps.
    static let dataSmall = Font.system(size: 11, weight: .regular, design: .monospaced)

    // MARK: - Palette
    //
    // Monochrome. Adaptive via `.primary`. One accent only.

    static let textPrimary = Color.primary
    static let textSecondary = Color.primary.opacity(0.72)
    static let textMuted = Color.primary.opacity(0.50)
    static let textDim = Color.primary.opacity(0.32)

    /// Single brand accent — restrained, used for selection + CTAs. Not a rainbow.
    static let accent = Color.accentColor

    /// Status colors — for state dots only, not panel backgrounds.
    static let statusOk = Color.green
    static let statusWarn = Color.orange
    static let statusAlert = Color.red

    // MARK: - Materials
    //
    // Three depth tiers. Pick by hierarchy, not aesthetic whim.

    /// Base background: soft environmental wash behind everything. Not a card.
    static let heroBackgroundDark = LinearGradient(
        colors: [
            Color(white: 0.10),
            Color(white: 0.05),
        ],
        startPoint: .top, endPoint: .bottom
    )
    static let heroBackgroundLight = LinearGradient(
        colors: [
            Color(white: 0.97),
            Color(white: 0.92),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Specular rim — subtle top highlight seen on real glass.
    static let edgeHighlight = LinearGradient(
        colors: [
            Color.white.opacity(0.35),
            Color.white.opacity(0.05),
            Color.white.opacity(0),
        ],
        startPoint: .top, endPoint: .center
    )
}

// MARK: - Panel modifiers

/// Primary glass panel. Neutral, monochrome, depth via material + rim + shadow.
struct GlassPanel: ViewModifier {
    enum Elevation { case flat, raised, hero }
    var radius: CGFloat = Glass.rMedium
    var elevation: Elevation = .raised

    private var material: Material {
        switch elevation {
        case .flat: return .ultraThinMaterial
        case .raised: return .thinMaterial
        case .hero: return .regularMaterial
        }
    }

    private var shadowOpacity: Double {
        switch elevation {
        case .flat: return 0.04
        case .raised: return 0.10
        case .hero: return 0.16
        }
    }
    private var shadowRadius: CGFloat {
        switch elevation {
        case .flat: return 4
        case .raised: return 16
        case .hero: return 28
        }
    }
    private var shadowY: CGFloat {
        switch elevation {
        case .flat: return 1
        case .raised: return 6
        case .hero: return 12
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(material)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Glass.edgeHighlight, lineWidth: 1)
                        .blendMode(.overlay)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color.black.opacity(shadowOpacity),
                    radius: shadowRadius, x: 0, y: shadowY)
    }
}

/// Chip — small interactive surface (tab, pill, button).
struct GlassChip: ViewModifier {
    var selected: Bool = false
    var tinted: Bool = false
    var radius: CGFloat = Glass.rTiny

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Glass.s10)
            .padding(.vertical, 5)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if selected {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(selected ? 0.24 : 0.10), lineWidth: 0.5)
                }
            }
    }
}

/// Separator — hairline divider used inside rows.
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}

extension View {
    func glassPanel(radius: CGFloat = Glass.rMedium,
                    elevation: GlassPanel.Elevation = .raised) -> some View {
        modifier(GlassPanel(radius: radius, elevation: elevation))
    }
    func glassChip(selected: Bool = false, radius: CGFloat = Glass.rTiny) -> some View {
        modifier(GlassChip(selected: selected, radius: radius))
    }
}
