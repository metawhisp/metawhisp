import SwiftUI

/// Screen 0: Welcome — animated logo, typewriter title, feature chips.
struct OnboardingWelcomePage: View {
    let appeared: Bool
    @State private var titleText = ""
    @State private var shimmerPhase: CGFloat = 0
    @State private var showTagline = false
    @State private var showFeatures = false

    private let fullTitle = "METAWHISP"

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon with bounce
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .white.opacity(0.06), radius: 30)
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.6, dampingFraction: 0.65).delay(0.1), value: appeared)

            Spacer().frame(height: 20)

            // Typewriter title with shimmer
            ZStack {
                Text(titleText)
                    .font(.system(size: 36, weight: .heavy, design: .monospaced))
                    .foregroundStyle(MW.textPrimary)

                if titleText == fullTitle {
                    shimmerOverlay
                }
            }
            .frame(height: 44)

            Spacer().frame(height: 12)

            Text("Voice-to-text that lives on your Mac.")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(MW.textSecondary)
                .opacity(showTagline ? 1 : 0)
                .offset(y: showTagline ? 0 : 10)

            Spacer().frame(height: 28)

            HStack(spacing: 16) {
                featureChip(icon: "waveform", text: "Transcribe")
                featureChip(icon: "globe", text: "Translate")
                featureChip(icon: "text.quote", text: "Rewrite")
                featureChip(icon: "lock.shield", text: "Private")
            }
            .opacity(showFeatures ? 1 : 0)
            .offset(y: showFeatures ? 0 : 12)

            Spacer()
        }
        .padding(.horizontal, MW.sp32)
        .onChange(of: appeared) { _, val in if val { startSequence() } }
    }

    // MARK: - Helpers

    private var shimmerOverlay: some View {
        Text(fullTitle)
            .font(.system(size: 36, weight: .heavy, design: .monospaced))
            .foregroundStyle(.clear)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, shimmerPhase - 0.15)),
                            .init(color: .white.opacity(0.4), location: shimmerPhase),
                            .init(color: .clear, location: min(1, shimmerPhase + 0.15)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(
                        Text(fullTitle)
                            .font(.system(size: 36, weight: .heavy, design: .monospaced))
                    )
                }
            }
    }

    private func featureChip(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(MW.textSecondary)
            Text(text.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(MW.textMuted)
                .tracking(0.8)
        }
        .frame(width: 80, height: 64)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    private func startSequence() {
        titleText = ""; showTagline = false; showFeatures = false; shimmerPhase = 0
        for (i, ch) in fullTitle.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.05) {
                titleText += String(ch)
            }
        }
        let done = 0.4 + Double(fullTitle.count) * 0.05 + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + done) {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { shimmerPhase = 1.3 }
            withAnimation(.easeOut(duration: 0.5)) { showTagline = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + done + 0.3) {
            withAnimation(.easeOut(duration: 0.5)) { showFeatures = true }
        }
    }
}
