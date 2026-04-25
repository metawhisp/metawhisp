import SwiftUI

/// Screen 4: Interactive voice test — cinematic flow.
/// Phase 0: Big pulsing "Press Right ⌘" button
/// Phase 1: Button slides up, "Say something..." + aura pulses with voice
/// Phase 2: "Press Right ⌘ to finish" appears after 3s
/// Phase 3: Result field slides in, text types out, celebration
struct OnboardingTryItPage: View {
    let appeared: Bool
    @ObservedObject var coordinator: TranscriptionCoordinator

    @State private var phase = 0  // 0=waiting, 1=recording, 2=showFinish, 3=result
    @State private var auraPulse: CGFloat = 0.3
    @State private var typedText = ""
    @State private var fullResult = ""
    @State private var showCelebration = false
    @State private var buttonScale: CGFloat = 1.0
    @State private var showFinishTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if phase == 0 {
                phase0View.transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            if phase == 1 || phase == 2 {
                recordingView.transition(.opacity)
            }

            if phase == 3 {
                resultView.transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coordinator.stage) { _, newStage in
            handleStageChange(newStage)
        }
        .onReceive(coordinator.$lastResult) { result in
            if let text = result?.text, !text.isEmpty, phase != 3 {
                showResult(text)
            }
        }
    }

    // MARK: - Phase 0: Press to Start

    private var phase0View: some View {
        VStack(spacing: 24) {
            Text("TRY IT NOW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(MW.textMuted).tracking(2)

            Text("Let's test your voice!")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(MW.textPrimary)

            Spacer().frame(height: 16)

            // Pulsing mic circle
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .frame(width: 140, height: 140)
                    .scaleEffect(buttonScale)
                Circle()
                    .stroke(Color.white.opacity(0.03), lineWidth: 1)
                    .frame(width: 180, height: 180)
                    .scaleEffect(buttonScale * 0.95)

                Circle()
                    .fill(MW.surface)
                    .frame(width: 100, height: 100)
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))

                Image(systemName: "mic.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(MW.textPrimary)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    buttonScale = 1.08
                }
            }

            Spacer().frame(height: 16)

            HStack(spacing: 10) {
                Text("Press").font(.system(size: 14, design: .monospaced)).foregroundStyle(MW.textSecondary)
                Keycap(text: "Right ⌘")
                Text("to start").font(.system(size: 14, design: .monospaced)).foregroundStyle(MW.textSecondary)
            }
        }
    }

    // MARK: - Phase 1-2: Recording

    private var recordingView: some View {
        VStack(spacing: 28) {
            Text("Say something...")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(MW.textPrimary)

            ZStack {
                Circle()
                    .fill(MW.recording.opacity(auraPulse * 0.15))
                    .frame(width: 180, height: 180)
                    .blur(radius: 20)
                Circle()
                    .fill(MW.recording.opacity(auraPulse * 0.25))
                    .frame(width: 130, height: 130)
                    .blur(radius: 12)
                Circle()
                    .fill(MW.recording.opacity(auraPulse * 0.4))
                    .frame(width: 90, height: 90)
                    .blur(radius: 6)

                Circle()
                    .fill(MW.surface)
                    .frame(width: 80, height: 80)
                    .overlay(Circle().stroke(MW.recording.opacity(0.4), lineWidth: 1.5))

                Circle()
                    .fill(MW.recording)
                    .frame(width: 12, height: 12)
                    .shadow(color: MW.recording.opacity(0.6), radius: 6)
            }

            if phase == 2 {
                HStack(spacing: 10) {
                    Text("Press").font(.system(size: 14, design: .monospaced)).foregroundStyle(MW.textSecondary)
                    Keycap(text: "Right ⌘")
                    Text("to finish").font(.system(size: 14, design: .monospaced)).foregroundStyle(MW.textSecondary)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    // MARK: - Phase 3: Result

    private var resultView: some View {
        VStack(spacing: 20) {
            if showCelebration {
                VStack(spacing: 8) {
                    Text("✓")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(MW.idle)
                    Text("It works!")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(MW.idle)
                }
                .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR VOICE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(MW.textMuted).tracking(1)

                HStack(spacing: 0) {
                    Text(typedText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(MW.textPrimary)
                    if typedText.count < fullResult.count {
                        Rectangle().fill(MW.textPrimary).frame(width: 2, height: 18).opacity(0.8)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(16)
                .mwCard(radius: MW.rSmall, elevation: .flat)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(MW.idle.opacity(0.3), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 50)

            Text("Press NEXT to continue →")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(MW.textMuted)
        }
    }

    // MARK: - State Handling

    private func handleStageChange(_ stage: TranscriptionCoordinator.Stage) {
        switch stage {
        case .recording:
            if phase == 0 {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { phase = 1 }
                showFinishTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                    DispatchQueue.main.async {
                        if self.phase == 1 {
                            withAnimation(.easeOut(duration: 0.4)) { self.phase = 2 }
                        }
                    }
                }
                startAuraPulse()
            }
        case .processing, .postProcessing:
            auraPulse = 0.5 // steady glow during processing
        case .idle:
            break
        }
    }

    private func showResult(_ text: String) {
        fullResult = text
        showFinishTimer?.invalidate()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { phase = 3 }

        for (i, ch) in text.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.04) {
                typedText += String(ch)
            }
        }
        let typingDone = 0.3 + Double(text.count) * 0.04 + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + typingDone) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { showCelebration = true }
        }
    }

    private func startAuraPulse() {
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { t in
            if phase >= 3 { t.invalidate(); return }
            // Idle pulse when no audio data
            auraPulse = CGFloat.random(in: 0.2...0.6)
        }
    }
}
