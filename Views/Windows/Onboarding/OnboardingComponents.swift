import SwiftUI

// MARK: - Checkmark Shape

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.78))
        path.addLine(to: CGPoint(x: rect.width * 0.85, y: rect.height * 0.22))
        return path
    }
}

// MARK: - Dot Indicator

struct OnboardingDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == current ? Color.white : MW.textMuted.opacity(0.25))
                    .frame(width: i == current ? 24 : 6, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: current)
            }
        }
    }
}

// MARK: - Section Header

struct OnboardingHeader: View {
    let label: String
    let title: String
    let appeared: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(MW.textMuted).tracking(2)
                .opacity(appeared ? 1 : 0)
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(MW.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(granted ? MW.idle : MW.textSecondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MW.textPrimary)
                Text(description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(MW.idle)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: action) {
                    Text("ALLOW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(MW.surface)
        .overlay(Rectangle().stroke(granted ? MW.idle.opacity(0.3) : MW.border, lineWidth: MW.hairline))
    }
}
