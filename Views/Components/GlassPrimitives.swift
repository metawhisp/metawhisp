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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14)
                    .foregroundStyle(isActive ? MW.textPrimary : MW.textSecondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? MW.textPrimary : MW.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                        .fill(MW.selectFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                                .strokeBorder(MW.selectRim, lineWidth: 0.5)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        if accent { return MW.accent }
        return isActive ? MW.textPrimary : MW.textSecondary
    }
    private var fill: AnyShapeStyle {
        if accent { return AnyShapeStyle(MW.accentSoft) }
        if isActive { return AnyShapeStyle(MW.selectFill) }
        return AnyShapeStyle(.ultraThinMaterial)
    }
    private var stroke: Color {
        if accent { return MW.accentRim }
        if isActive { return MW.selectRim }
        return MW.border
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
        case .ready: return MW.idle
        case .recording: return MW.live
        case .processing: return MW.processing
        case .postProcessing: return MW.postProcess
        }
    }

    /// Recording state gets a red-tinted capsule fill so it screams.
    /// Other states use ultraThinMaterial — the dot does the signaling.
    var fillColor: AnyShapeStyle {
        switch self {
        case .recording: return AnyShapeStyle(MW.live.opacity(0.14))
        default: return AnyShapeStyle(.ultraThinMaterial)
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
// All segments inside a single ultraThin capsule. Active segment has
// raised material + selectRim border + primary text.
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
                        .background {
                            if isActive {
                                Capsule(style: .continuous)
                                    .fill(.thinMaterial)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(MW.selectRim, lineWidth: 0.5)
                                    )
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
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
// PageWash — the radial+linear gradient background for the main window.
// Use as the BACKGROUND-LAYER inside MainWindowView's outer ZStack.
// Reads `MW.accent` so the warm-side wash picks up the user's accent preset.
// ─────────────────────────────────────────────────────────────────────────

struct PageWash: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [MW.bg, MW.bg.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.34, green: 0.47, blue: 0.61).opacity(MW.isDark ? 0.18 : 0.22), .clear],
                center: UnitPoint(x: 0.18, y: -0.10),
                startRadius: 100, endRadius: 700
            )
            RadialGradient(
                colors: [MW.accent.opacity(0.10), .clear],
                center: UnitPoint(x: 1.00, y: 1.10),
                startRadius: 80, endRadius: 600
            )
        }
        .ignoresSafeArea()
    }
}
