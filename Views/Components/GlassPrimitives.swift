import SwiftUI

// MARK: - Glass Primitives (design spec 2026-04-26 § 6 Component recipes)
//
// Reusable building blocks lifted from the Liquid Glass spec. Used by every
// page rebuild in §7 mapping table. Keep these dumb / stateless — page-level
// state lives in the parent view.

// ─────────────────────────────────────────────────────────────────────────
// SidebarItem — sidebar nav row.
// Active state = glass-flat fill + hairline rim, primary text + icon.
// Inactive = no fill, secondary text/icon. Hover state handled by parent.
// ─────────────────────────────────────────────────────────────────────────

struct SidebarItem: View {
    let title: String
    let icon: String
    let isActive: Bool
    /// The folded sidebar of a narrow window: the icon alone, the title as its tooltip and spoken name.
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14)
                    .foregroundStyle(isActive ? MW.accent : MW.textSecondary)
                if !compact {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? MW.textPrimary : MW.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, compact ? 0 : 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .mwSelectable(isActive, radius: MW.rSmall, resting: .none)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
        .accessibilityLabel(title)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// GlassChipButton — pill / segmented chip.
// `radius: 999` for round pills, `MW.rTiny` for square chips.
// `accent: true` paints with accent-soft fill + accent text.
// ─────────────────────────────────────────────────────────────────────────

struct GlassChipButton: View {
    let label: String
    var icon: String? = nil
    var isActive: Bool = false
    var accent: Bool = false
    var radius: CGFloat = 999
    /// One option of a segmented group inside `mwSegmentTrack()`: no box of its own at rest.
    var grouped: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                // A chip's words never break: it keeps its one line, and its row decides what to do when narrow.
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background {
                if accent {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(MW.accentSoft)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(MW.accentRim, lineWidth: 0.5)
                }
            }
            .mwSelectable(isActive && !accent, radius: radius, resting: accent || grouped ? .none : .surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        if accent { return MW.accent }
        return isActive ? MW.textPrimary : MW.textSecondary
    }
}

// ─────────────────────────────────────────────────────────────────────────
// SegmentStrip — a segmented row of chips (Library, Conversations, Workspace).
// While the row fits it is the row; in a narrower window it becomes one chip
// that opens a menu of the options, so no option is cut at the window's edge.
// ─────────────────────────────────────────────────────────────────────────

struct SegmentStrip<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    GlassChipButton(label: title(option), isActive: selection == option, radius: 999, grouped: true) {
                        selection = option
                    }
                }
            }
            .mwSegmentTrack()

            SegmentMenu(options: options, selection: $selection, title: title)
        }
    }
}

/// The narrow form of a segmented row: one chip naming the chosen option, opening a menu of all of them.
struct SegmentMenu<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(title(option)) { selection = option }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(selection))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(MW.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .mwSelectable(true, radius: 999)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// ─────────────────────────────────────────────────────────────────────────
// StatusPill — Ready / Recording / Processing / Translating.
// Capsule shape, dot + label. Recording uses live-red fill (alert).
// ─────────────────────────────────────────────────────────────────────────

enum StatusPillState: String {
    case ready, recording, processing, postProcessing

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .recording: return "Recording"
        case .processing: return "Transcribing"
        case .postProcessing: return "Processing"
        }
    }

    var dotColor: Color {
        switch self {
        case .ready: return MW.ok
        case .recording: return MW.live
        case .processing: return MW.processing
        case .postProcessing: return MW.ok
        }
    }

    /// Recording state gets a red-tinted capsule fill so it screams.
    /// Other states use the inner fill — the dot does the signaling.
    var fillColor: AnyShapeStyle {
        switch self {
        case .recording: return AnyShapeStyle(MW.live.opacity(0.14))
        default: return AnyShapeStyle(MW.surface)
        }
    }

    var rimColor: Color {
        switch self {
        case .recording: return MW.live.opacity(0.4)
        default: return MW.border
        }
    }

    var labelColor: Color {
        switch self {
        case .recording: return MW.live
        default: return MW.textPrimary
        }
    }
}

struct StatusPill: View {
    let state: StatusPillState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: state.dotColor.opacity(0.6), radius: 4)
            Text(state.label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(state.labelColor)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(state.fillColor))
        .overlay(Capsule(style: .continuous).strokeBorder(state.rimColor, lineWidth: 0.5))
    }
}

// ─────────────────────────────────────────────────────────────────────────
// PageHeader — page title + optional right-aligned slot.
// 28pt bold sans, -0.4 tracking. Right slot for chips / status / actions.
// ─────────────────────────────────────────────────────────────────────────

struct PageHeader<Right: View>: View {
    let title: String
    @ViewBuilder let right: () -> Right

    init(_ title: String, @ViewBuilder right: @escaping () -> Right) {
        self.title = title
        self.right = right
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(MW.textPrimary)
            Spacer()
            right()
        }
        .padding(.bottom, MW.sp16)
    }
}

extension PageHeader where Right == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// SegmentedGlass — pill-shaped segmented control (Settings tab bar).
// All segments inside one capsule on the palette's track; the active
// segment is drawn by mwSelectable (ITER-087), primary text.
// ─────────────────────────────────────────────────────────────────────────

struct SegmentedGlass<T: Hashable>: View {
    let segments: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments, id: \.value) { seg in
                let isActive = selection == seg.value
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selection = seg.value
                    }
                } label: {
                    Text(seg.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isActive ? MW.textPrimary : MW.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .mwSelectable(isActive, radius: 999, resting: .none)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(MW.palette.track.color))
        .overlay(Capsule(style: .continuous).strokeBorder(MW.palette.edge.color, lineWidth: 1))
    }
}

// ─────────────────────────────────────────────────────────────────────────
// AccentSwatch — single circular swatch for the Settings accent picker.
// 5 of these in a row. Selected gets an outer ring.
// ─────────────────────────────────────────────────────────────────────────

struct AccentSwatch: View {
    let presetID: String
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(MW.accentPresetColor(presetID))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(MW.border, lineWidth: 0.5)
                        )
                    if isSelected {
                        Circle()
                            .strokeBorder(MW.textPrimary, lineWidth: 1.4)
                            .frame(width: 30, height: 30)
                    }
                }
                .frame(width: 32, height: 32)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? MW.textPrimary : MW.textMuted)
            }
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// PageWash — the wall: the one ground of the main window, the popover and
// the sheets (ITER-087). The palette's opaque wall with a glow of the user's
// accent at the top right; in the dark look a fainter accent glow at the
// bottom left, in the light look a neutral shade there. No screen paints
// its own ground over it (WindowWallGuardTests).
// ─────────────────────────────────────────────────────────────────────────

struct PageWash: View {
    /// The accent and the look are dependencies of the wall, so changing either draws it again (owner, 2026-11-25:
    /// the glow stayed mint after the accent became violet).
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    /// How far the glow reaches: a corner of the surface, never the whole of it. A fixed 520 pt glow flooded the
    /// 320 pt popover green (owner, 2026-11-25: "more black, less green").
    static func glowRadius(for size: CGSize) -> CGFloat { max(size.width, size.height) * 0.45 }

    var body: some View {
        GeometryReader { geometry in
            let look = MW.Palette.of(dark: colorScheme == .dark)
            let accent = MW.accentPresetColor(settings.accentColor)
            let reach = Self.glowRadius(for: geometry.size)
            ZStack {
                LinearGradient(
                    colors: [look.wallTop.color, look.wallBottom.color],
                    startPoint: .top, endPoint: .bottom
                )
                RadialGradient(
                    colors: [accent.opacity(look.glow), .clear],
                    center: UnitPoint(x: 0.96, y: 0),
                    startRadius: 0, endRadius: reach
                )
                RadialGradient(
                    colors: [accent.opacity(look.lowGlow), .clear],
                    center: UnitPoint(x: 0, y: 1),
                    startRadius: 0, endRadius: reach
                )
                RadialGradient(
                    colors: [look.shade.color, .clear],
                    center: UnitPoint(x: 0, y: 1),
                    startRadius: 0, endRadius: reach
                )
            }
        }
        .ignoresSafeArea()
    }
}
