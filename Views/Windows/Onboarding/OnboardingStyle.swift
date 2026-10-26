import SwiftUI

/// The first run's look, after the approved mockup (v6): one 624 pt column, a 52 pt capsule for the choice that
/// moves on, SF Pro throughout. Colors follow the appearance, so light mode reads too (H4).
enum OnboardingStyle {
    static let column: CGFloat = 624
    static let title = Font.system(size: 34, weight: .semibold)
    static let body = Font.system(size: 16)
    static let step = Font.system(size: 12, weight: .medium)
}

/// How Right ⌘ dictates on this Mac, for the words that name it: not at all without Accessibility (the shortcut
/// does not reach the app), tapped in the toggle mode, held in push-to-talk.
enum RightCommand: Equatable {
    case unavailable, tap, hold

    static func current(accessibility: Bool, hotkeyMode: String) -> RightCommand {
        guard accessibility else { return .unavailable }
        return hotkeyMode == "pushToTalk" ? .hold : .tap
    }
}

/// How things arrive. With Reduce Motion nothing moves — it fades in where it stands (H3).
enum OnboardingMotion {
    static func offset(_ distance: CGFloat, reduceMotion: Bool) -> CGFloat { reduceMotion ? 0 : distance }
}

/// A part of a screen that arrives: it fades in and, without Reduce Motion, rises 6 pt.
struct Arrival: ViewModifier {
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : OnboardingMotion.offset(6, reduceMotion: reduceMotion))
    }
}

/// One screen: its content in the stage, its buttons in the footer — Back on the left, the choice in the middle.
struct OnboardingPage<Stage: View, Leading: View, Center: View>: View {
    private let stage: Stage
    private let leading: Leading
    private let center: Center

    init(@ViewBuilder stage: () -> Stage, @ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center) {
        self.stage = stage()
        self.leading = leading()
        self.center = center()
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 48)
                .padding(.top, 44)   // the step sits above it
            // Three columns, as the mockup's footer grid: Back, the choice, an empty column as wide as Back's, so
            // the choice sits in the middle — and Tab meets them in that order. The Back column is there on a
            // screen without Back too: an empty `leading` alone takes no room, and the choice went to the left edge
            // (owner 2026-10-25, the welcome).
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    leading
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                center
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 12)
            .frame(height: 100)
        }
    }
}

/// A screen's heading.
struct OnboardingTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OnboardingStyle.title)
            .tracking(-0.5)
            .foregroundStyle(MW.textPrimary)
            .multilineTextAlignment(.center)
    }
}

/// A capsule's label with the arrow after it.
struct ArrowLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
            Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
        }
    }
}

/// The 52 pt capsule: `primary` for the choice that moves on, `glass` for the one beside it.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, glass }

    var kind: Kind = .primary
    var minWidth: CGFloat = 232
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 28)
            .frame(minWidth: minWidth, minHeight: 52)
            .background(Capsule(style: .continuous).fill(fill))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(rim), lineWidth: 0.5))
            .shadow(color: .black.opacity(kind == .primary && isEnabled ? 0.35 : 0), radius: 15, y: 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        guard isEnabled else { return Color.primary.opacity(0.36) }
        switch kind {
        case .primary: return scheme == .dark ? Color(w: 0.07) : .white
        case .glass: return MW.textPrimary
        }
    }

    private var fill: Color {
        guard isEnabled else { return Color.primary.opacity(0.09) }
        switch kind {
        case .primary: return scheme == .dark ? Color(w: 0.96) : Color(w: 0.11)
        case .glass: return Color.primary.opacity(0.08)
        }
    }

    private var rim: Double { kind == .glass || !isEnabled ? 0.2 : 0 }
}

/// The 40 pt button inside a row or a box: prominent (solid) for the one the screen leads with, quiet otherwise.
struct RowButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? (scheme == .dark ? Color(w: 0.07) : .white) : MW.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .background(Capsule(style: .continuous)
                .fill(prominent ? (scheme == .dark ? Color(w: 0.96) : Color(w: 0.11)) : Color.primary.opacity(0.09)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(prominent ? 0 : 0.16), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

/// A permission that is allowed: the green check and the word.
struct AllowedLabel: View {
    var body: some View {
        Label {
            Text("Allowed").font(.system(size: 14, weight: .semibold)).foregroundStyle(MW.textPrimary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(MW.idle)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// A line that shows "Right ⌘" as a key, the way the mockup draws it.
struct KeyedText: View {
    let text: String
    let font: Font

    var body: some View {
        if let key = text.range(of: "Right ⌘") {
            let before = String(text[..<key.lowerBound]), after = String(text[key.upperBound...])
            HStack(spacing: 0) {
                Text(before.trimmingCharacters(in: .whitespaces))
                KeyLabel(text: "Right ⌘")
                    .padding(.leading, before.hasSuffix(" ") ? 5 : 0)
                    .padding(.trailing, after.hasPrefix(" ") ? 5 : 0)
                Text(after.trimmingCharacters(in: .whitespaces))
            }
            .font(font)
        } else {
            Text(text).font(font)
        }
    }
}

/// A key, as in "Right ⌘".
struct KeyLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MW.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// The browser did not open the account page (DOD D2): the address, and Copy.
struct AccountLinkFallback: View {
    var body: some View {
        HStack(spacing: 10) {
            Text(AccountPage.url.absoluteString)
                .font(.system(size: 13))
                .foregroundStyle(MW.textSecondary)
                .textSelection(.enabled)
            Button("Copy") { AccountPage.copy(to: .general) }
                .buttonStyle(RowButtonStyle(prominent: false))
        }
    }
}

/// Back: words only.
struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.6 : 0.86))
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
    }
}

/// The window's own background: the app's page color under a faint wash from the top.
struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            MW.bg
            RadialGradient(colors: [Color(red: 0.47, green: 0.59, blue: 0.80).opacity(0.11), .clear],
                           center: UnitPoint(x: 0.5, y: -0.16), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
