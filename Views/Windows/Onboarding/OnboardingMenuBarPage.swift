import SwiftUI

/// Screen 5: Where to find MetaWhisp — show menubar location.
struct OnboardingMenuBarPage: View {
    let appeared: Bool
    @State private var showArrow = false
    @State private var showText = false
    @State private var arrowBounce = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            OnboardingHeader(
                label: "ALMOST DONE",
                title: "Where to find MetaWhisp",
                appeared: appeared
            )

            Spacer().frame(height: 40)

            // Simulated menubar
            menuBarSimulation
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.2), value: appeared)

            Spacer().frame(height: 24)

            // Arrow pointing up — aligned right under MW icon
            if showArrow {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(MW.idle)
                            .offset(y: arrowBounce ? -6 : 0)

                        Text("MW")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(MW.idle)
                    }
                    Spacer().frame(width: 130) // align under MW icon in simulated menubar
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer().frame(height: 24)

            // Explanation
            if showText {
                VStack(spacing: 12) {
                    infoRow(icon: "menubar.rectangle",
                            text: "MetaWhisp lives in your menu bar — top right corner")
                    infoRow(icon: "keyboard",
                            text: "Just press your hotkey anywhere — no need to open the app")
                    infoRow(icon: "moon.fill",
                            text: "It's always running quietly in the background")
                }
                .padding(.horizontal, 60)
                .transition(.opacity)
            }

            Spacer()
        }
        .onChange(of: appeared) { _, val in if val { startAnimation() } }
    }

    // MARK: - Menubar Simulation

    private var menuBarSimulation: some View {
        HStack(spacing: 0) {
            Spacer()

            // System tray icons simulation
            HStack(spacing: 14) {
                Image(systemName: "wifi").font(.system(size: 12, weight: .medium))
                Image(systemName: "battery.75percent").font(.system(size: 14, weight: .medium))
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))

                // MetaWhisp icon — highlighted
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(MW.idle.opacity(0.15))
                        .frame(width: 28, height: 22)

                    Text("MW")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(MW.idle)
                }

                Text("Sun 12:00")
                    .font(.system(size: 12, weight: .medium, design: .default))
            }
            .foregroundStyle(MW.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(MW.surface.opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(MW.border, lineWidth: MW.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer().frame(width: 40)
        }
    }

    // MARK: - Info Row

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(MW.textSecondary)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MW.textSecondary)
            Spacer()
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        showArrow = false; showText = false; arrowBounce = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { showArrow = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.3)) {
                arrowBounce = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.5)) { showText = true }
        }
    }
}
