import SwiftUI

/// Screen 1: Transcribe + Translate combined demo.
struct OnboardingFeaturesPage: View {
    let appeared: Bool
    @State private var step = 0
    @State private var demoText = ""
    @State private var pillPulse = false
    @State private var micBars: [CGFloat] = [0.3, 0.5, 0.4, 0.6, 0.3]
    @State private var showTranslate = false
    @State private var translatedText = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            OnboardingHeader(
                label: "HOW IT WORKS",
                title: "Speak. Get text. Anywhere.",
                appeared: appeared
            )

            Spacer().frame(height: 28)

            // Transcribe demo
            transcribeSection
                .padding(.horizontal, 40)

            Spacer().frame(height: 20)

            // Translate teaser
            if showTranslate {
                translateSection
                    .padding(.horizontal, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer().frame(height: 16)

            // App badges
            if step >= 3 {
                appBadges.transition(.opacity)
            }

            Spacer()
        }
        .onChange(of: appeared) { _, val in if val { startDemo() } }
    }

    // MARK: - Transcribe Section

    private var transcribeSection: some View {
        VStack(spacing: 14) {
            // Step 1: Hotkey
            if step >= 1 {
                HStack(spacing: 10) {
                    Keycap(text: "Right ⌘")
                        .scaleEffect(step == 1 ? 1.12 : 1.0)
                        .animation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true), value: step)
                    Text("tap to record, tap again to stop")
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    Spacer()
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Step 2: Recording pill
            if step >= 2 {
                recordingPill.transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Step 3: Result
            if step >= 3 {
                resultField.transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var recordingPill: some View {
        HStack(spacing: 8) {
            Circle().fill(MW.recording).frame(width: 8, height: 8).opacity(pillPulse ? 1 : 0.4)
            Text("RECORDING").font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(MW.textPrimary).tracking(1)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1).fill(MW.recording.opacity(0.6))
                        .frame(width: 3, height: micBars[i] * 16)
                }
            }.frame(height: 16)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(MW.surface)
        .overlay(Capsule().stroke(MW.recording.opacity(0.3), lineWidth: 1))
        .clipShape(Capsule())
    }

    private var resultField: some View {
        HStack(spacing: 0) {
            Text(demoText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(MW.textPrimary)
            if demoText.count < 28 {
                Rectangle().fill(MW.textPrimary).frame(width: 1, height: 15).opacity(0.8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.idle.opacity(0.3), lineWidth: MW.hairline))
    }

    // MARK: - Translate Section

    private var translateSection: some View {
        HStack(spacing: 10) {
            Keycap(text: "Right ⌥")
            VStack(alignment: .leading, spacing: 4) {
                Text("Translate your voice")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(MW.textPrimary)
                if !translatedText.isEmpty {
                    HStack(spacing: 6) {
                        Text("🇺🇸→🇩🇪").font(.system(size: 12))
                        Text(translatedText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MW.idle)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    // MARK: - App Badges

    private var appBadges: some View {
        HStack(spacing: 8) {
            ForEach(["Slack", "Chrome", "Notes", "Mail", "VS Code", "Any app"], id: \.self) { name in
                Text(name)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(MW.surface)
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
            }
        }
    }

    // MARK: - Animation

    private func startDemo() {
        step = 0; demoText = ""; pillPulse = false; showTranslate = false; translatedText = ""

        at(0.3) { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { step = 1 } }
        at(0.9) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { step = 2 }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pillPulse = true }
            animateBars()
        }
        at(1.6) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { step = 3 }
            typeDemo("Meeting notes for tomorrow...", speed: 0.04)
        }
        at(3.0) {
            withAnimation(.easeOut(duration: 0.4)) { showTranslate = true }
            typeTranslation("Besprechungsnotizen für morgen...", speed: 0.03, delay: 0.3)
        }
    }

    private func at(_ t: Double, action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: action)
    }

    private func typeDemo(_ text: String, speed: Double) {
        for (i, ch) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * speed) {
                demoText += String(ch)
            }
        }
    }

    private func typeTranslation(_ text: String, speed: Double, delay: Double) {
        for (i, ch) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(i) * speed) {
                translatedText += String(ch)
            }
        }
    }

    private func animateBars() {
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { t in
            if step < 2 { t.invalidate(); return }
            withAnimation(.easeOut(duration: 0.08)) {
                micBars = (0..<5).map { _ in CGFloat.random(in: 0.15...1.0) }
            }
        }
    }
}
