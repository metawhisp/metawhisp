import SwiftUI

/// MetaWhisp Design System — BLOCKS monochromatic style with Dark/Light/Auto theme.
enum MW {

    // MARK: - Dynamic Palette

    /// Returns true if current appearance is dark
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var bg: Color { isDark ? Color(w: 0.04) : Color(w: 0.96) }
    static var surface: Color { isDark ? Color(w: 0.08) : Color(w: 0.92) }
    static var elevated: Color { isDark ? Color(w: 0.12) : Color(w: 0.88) }
    static var border: Color { isDark ? Color(w: 1.0, a: 0.10) : Color(w: 0.0, a: 0.10) }
    static var borderLight: Color { isDark ? Color(w: 1.0, a: 0.20) : Color(w: 0.0, a: 0.20) }
    static var textPrimary: Color { isDark ? Color(w: 0.92) : Color(w: 0.08) }
    static var textSecondary: Color { isDark ? Color(w: 0.50) : Color(w: 0.40) }
    static var textMuted: Color { isDark ? Color(w: 0.30) : Color(w: 0.60) }

    // Accents — same for both themes
    static let live = Color.red
    static var accent: Color { textPrimary }
    static let recording = Color.red
    static let processing = Color.orange
    static let postProcess = Color.blue
    static let idle = Color.green
    static var subtle: Color { isDark ? Color(w: 1.0, a: 0.05) : Color(w: 0.0, a: 0.05) }
    static var cardBg: Color { surface }

    // MARK: - Typography (monospaced)

    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoSm = Font.system(size: 9, weight: .regular, design: .monospaced)
    static let monoLg = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let monoXl = Font.system(size: 20, weight: .bold, design: .monospaced)
    static let monoTitle = Font.system(size: 32, weight: .bold, design: .monospaced)
    static let label = Font.system(size: 9, weight: .semibold, design: .rounded)
    static let labelMd = Font.system(size: 11, weight: .medium, design: .rounded)

    // Legacy aliases
    static let title = Font.system(size: 18, weight: .semibold, design: .monospaced)
    static let headline = Font.system(size: 15, weight: .medium, design: .monospaced)
    static let body = mono
    static let caption = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let micro = Font.system(size: 10, weight: .regular, design: .monospaced)

    // MARK: - Spacing

    static let sp4: CGFloat = 4
    static let sp8: CGFloat = 8
    static let sp12: CGFloat = 12
    static let sp16: CGFloat = 16
    static let sp24: CGFloat = 24
    static let sp32: CGFloat = 32
    static let spaceXs: CGFloat = 2
    static let spaceSm: CGFloat = 4
    static let spaceMd: CGFloat = 8
    static let spaceLg: CGFloat = 16
    static let spaceXl: CGFloat = 24

    // MARK: - Radii & Lines

    static let hairline: CGFloat = 0.5
    static let thinBorder: CGFloat = 1.0
    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 6
    static let radiusLg: CGFloat = 10

    // MARK: - State Color

    static func stateColor(_ stage: String) -> Color {
        switch stage {
        case "recording": return recording
        case "processing": return processing
        case "postProcessing": return postProcess
        default: return idle
        }
    }

    // MARK: - Theme Management

    static func applyTheme(_ theme: String) {
        switch theme {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default: // auto
            NSApp.appearance = nil // follows system
        }
    }
}

// MARK: - Convenience Color Init

extension Color {
    init(w: CGFloat, a: CGFloat = 1.0) {
        self.init(red: w, green: w, blue: w, opacity: a)
    }
}

// MARK: - View Modifiers

/// BLOCKS-style panel: dark fill + hairline border.
struct MWCardModifier: ViewModifier {
    var radius: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .background(MW.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(MW.border, lineWidth: MW.hairline))
    }
}

/// Small uppercase label (BLOCKS style).
struct MWBadgeModifier: ViewModifier {
    var color: Color = MW.textMuted
    func body(content: Content) -> some View {
        content
            .font(MW.label)
            .foregroundStyle(color)
            .textCase(.uppercase)
            .tracking(1.5)
    }
}

extension View {
    func mwCard(radius: CGFloat = 0) -> some View { modifier(MWCardModifier(radius: radius)) }
    func mwBadge(color: Color = MW.textMuted) -> some View { modifier(MWBadgeModifier(color: color)) }
    func blocksPanel(radius: CGFloat = 0) -> some View { modifier(MWCardModifier(radius: radius)) }
    func blocksLabel() -> some View { modifier(MWBadgeModifier()) }
}

// MARK: - Keycap View

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(MW.textPrimary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MW.elevated)
            .overlay(Rectangle().stroke(MW.borderLight, lineWidth: MW.hairline))
            .shadow(color: .black.opacity(0.4), radius: 0, y: 1)
    }
}

// MARK: - BlocksButton

struct BlocksButton: View {
    let label: String
    var icon: String? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MW.sp4) {
                if let icon { Image(systemName: icon).font(.system(size: 9)) }
                Text(label).font(MW.label).tracking(1.2)
            }
            .foregroundStyle(isActive ? (MW.isDark ? Color.black : Color.white) : MW.textSecondary)
            .padding(.horizontal, MW.sp12)
            .padding(.vertical, MW.sp8)
            .background(isActive ? (MW.isDark ? Color.white : Color.black) : .clear)
            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
        }
        .buttonStyle(.plain)
    }
}
