import SwiftUI

/// Floating UI for voice-question flow — the AI dialogue overlay.
/// Visually distinct from the dictation pill: larger, rounded, "conversation" metaphor
/// (sparkles + bubble icons) instead of a thin recording strip.
///
/// spec://BACKLOG#Phase6
struct FloatingVoiceView: View {
    @ObservedObject var state: VoiceQuestionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !state.transcript.isEmpty {
                speechBlock(label: "YOU", icon: "person.fill", text: state.transcript, isUser: true)
            }

            if case .answered(let text) = state.phase {
                speechBlock(label: "METACHAT", icon: "sparkles", text: text, isUser: false)
            } else if case .error(let text) = state.phase {
                errorBlock(text)
            }
        }
        .padding(18)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 620, alignment: .topLeading)
        .background(
            ZStack {
                // Base surface, slightly lifted vs main window for "above the page" feel.
                MW.elevated.opacity(0.98)
                // Very subtle top highlight hinting at AI / active state.
                LinearGradient(
                    colors: [Color.white.opacity(0.04), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(MW.borderLight.opacity(0.5), lineWidth: MW.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            headerIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("METACHAT")
                    .font(MW.monoSm).tracking(2).foregroundStyle(MW.textMuted)
                Text(title)
                    .font(MW.monoLg).tracking(1.0).foregroundStyle(MW.textPrimary)
            }

            Spacer()

            statusChip
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        switch state.phase {
        case .listening:
            // Pulsing mic + waveform ring — makes "now talking" obvious.
            ZStack {
                PulseRing()
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MW.textPrimary)
            }
        case .transcribing:
            Image(systemName: "waveform.path")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MW.textSecondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .thinking:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MW.textSecondary)
                .symbolEffect(.pulse, options: .repeating)
        case .answered:
            Image(systemName: state.isSpeaking ? "speaker.wave.2.fill" : "bubble.left.and.bubble.right.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MW.textPrimary)
        case .error:
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.red.opacity(0.85))
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(MW.textMuted)
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        HStack(spacing: 6) {
            if state.isSpeaking {
                Button {
                    AppDelegate.shared?.ttsService.stop()
                    VoiceQuestionState.shared.isSpeaking = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("STOP").font(MW.label).tracking(0.8)
                    }
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(MW.surface.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(MW.borderLight, lineWidth: MW.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Stop speaking (Space)")
            }
            Text("Esc")
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textMuted)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(MW.border, lineWidth: MW.hairline)
                )
        }
    }

    private var title: String {
        switch state.phase {
        case .idle: return "READY"
        case .listening: return "LISTENING"
        case .transcribing: return "TRANSCRIBING"
        case .thinking: return "THINKING"
        case .answered: return state.isSpeaking ? "SPEAKING" : "ANSWERED"
        case .error: return "ERROR"
        }
    }

    // MARK: - Speech blocks

    private func speechBlock(label: String, icon: String, text: String, isUser: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isUser ? MW.textMuted : MW.textSecondary)
                .frame(width: 18, height: 18, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(MW.label).tracking(0.9)
                    .foregroundStyle(isUser ? MW.textMuted : MW.textSecondary)
                Text(text)
                    .font(MW.mono)
                    .foregroundStyle(MW.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isUser
                ? MW.surface.opacity(0.5)
                : MW.surface.opacity(0.9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isUser ? MW.border : MW.borderLight, lineWidth: MW.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func errorBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.85))
                .frame(width: 18, height: 18, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(MW.monoSm).foregroundStyle(.red.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.4), lineWidth: MW.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Pulse ring (listening indicator)

private struct PulseRing: View {
    @State private var scale: CGFloat = 0.8
    @State private var opacity: Double = 0.8

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(opacity), lineWidth: 1.2)
                .frame(width: 22, height: 22)
                .scaleEffect(scale)
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                scale = 1.35
                opacity = 0.0
            }
        }
    }
}
