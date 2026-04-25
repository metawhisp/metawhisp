import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case library = "Library"
    case tasks = "Tasks"
    case chat = "MetaChat"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .library: "books.vertical"
        case .tasks: "checklist"
        case .chat: "message"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @State private var selected: Screen = .dashboard
    @State private var dark: Bool = true

    var body: some View {
        ZStack {
            // Monochrome hero wash. No rainbow — solid dark (or soft light) so the
            // thin-material panels on top read as calm, not carnival.
            (dark ? Glass.heroBackgroundDark : Glass.heroBackgroundLight)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                Sidebar(selected: $selected, dark: $dark)
                    .frame(width: 236)
                    .padding(.leading, Glass.s12)
                    .padding(.vertical, Glass.s12)

                detail
                    .padding(.horizontal, Glass.s20)
                    .padding(.vertical, Glass.s20)
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .dashboard: DashboardScreen()
        case .library: PlaceholderScreen(title: "Library", subtitle: "Conversations · Screen · Files · Memories · History")
        case .tasks: TasksScreen()
        case .chat: MetaChatScreen()
        case .dictionary: PlaceholderScreen(title: "Dictionary", subtitle: "Custom corrections, brands, and snippets")
        case .settings: SettingsScreen()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selected: Screen
    @Binding var dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: Glass.s10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Glass.rTiny, style: .continuous)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: Glass.rTiny, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    Text("M")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Glass.textPrimary)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MetaWhisp")
                        .font(Glass.bodyMedium)
                        .foregroundStyle(Glass.textPrimary)
                    Text("Liquid")
                        .font(Glass.caption)
                        .foregroundStyle(Glass.textMuted)
                }
                Spacer()
            }
            .padding(.horizontal, Glass.s12)
            .padding(.vertical, Glass.s12)

            GlassDivider()
                .padding(.horizontal, Glass.s8)
                .padding(.bottom, Glass.s6)

            // Nav
            VStack(spacing: 2) {
                ForEach(Screen.allCases) { s in
                    SidebarRow(screen: s, selected: selected == s)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = s }
                }
            }
            .padding(.horizontal, Glass.s6)

            Spacer()

            // Theme + version
            VStack(spacing: Glass.s6) {
                HStack {
                    Image(systemName: dark ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 11))
                    Text(dark ? "Dark" : "Light")
                        .font(Glass.caption)
                    Spacer()
                    Toggle("", isOn: $dark)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .foregroundStyle(Glass.textSecondary)
                .padding(.horizontal, Glass.s12)
                .padding(.vertical, Glass.s8)
                .glassPanel(radius: Glass.rSmall, elevation: .flat)

                HStack {
                    Text("v0.0.1 · mockup")
                        .font(Glass.caption)
                        .foregroundStyle(Glass.textDim)
                    Spacer()
                }
                .padding(.horizontal, Glass.s12)
                .padding(.bottom, Glass.s6)
            }
            .padding(.horizontal, Glass.s6)
            .padding(.bottom, Glass.s6)
        }
        .glassPanel(radius: Glass.rLarge, elevation: .hero)
    }
}

struct SidebarRow: View {
    let screen: Screen
    let selected: Bool

    var body: some View {
        HStack(spacing: Glass.s10) {
            Image(systemName: screen.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
            Text(screen.rawValue)
                .font(Glass.bodyMedium)
            Spacer()
        }
        .foregroundStyle(selected ? Glass.textPrimary : Glass.textSecondary)
        .padding(.horizontal, Glass.s12)
        .padding(.vertical, Glass.s8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Glass.rSmall, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: Glass.rSmall, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    )
            }
        }
    }
}
