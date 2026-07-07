import SwiftUI

/// Floating UI for voice-question flow. Liquid Glass redesign 2026-05-01:
/// material backdrop + specular rim + phase-tinted header + Q/A cards.
/// Mirrors MenuBar Variant A chrome system. Mockup at
/// `mockups/voice-and-hotkeys.html`.
///
/// spec://BACKLOG#Phase6
struct FloatingVoiceView: View {
    @ObservedObject var state: VoiceQuestionState

    var body: some View {
        // ITER-050 B2.2 — the card window is sized exactly to the pill
        // (two-window pattern, see FloatingVoiceWindowController), so no
        // centering wrapper and no in-window shadow envelope anymore. The
        // drop shadow is drawn by CardShadowView in the shadow child window.
        pillContent
    }

    private var pillContent: some View {
        VStack(spacing: 0) {
            header

            // Review fix (ITER-050 B2.2): Q/A content scrolls past 380pt
            // instead of growing the card window past the screen — a long
            // dictated question + multi-line answer used to be unbounded
            // (the old fixed window clipped it; the measured card must cap).
            ScrollView {
                cards
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.45))
        .overlay(alignment: .top) {
            // Specular rim — top-down bright→dim white.
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.04), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 100)
            .allowsHitTesting(false)
            .blendMode(.plusLighter)
            .opacity(0.6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Drop shadow lives in the shadow child window (CardShadowView) —
        // ITER-050 B2.2 two-window pattern, same as MeetingCoach.
    }

    private var cards: some View {
        VStack(spacing: 0) {
            // Q card — show user's transcript whenever we have one (transcribing/
            // thinking/answered) plus a "Listening…" placeholder while recording.
            if !state.transcript.isEmpty {
                qaCard(
                    label: "YOU",
                    iconSF: "person.fill",
                    body: state.transcript,
                    dim: false
                )
            } else if case .listening = state.phase {
                qaCard(
                    label: "YOU",
                    iconSF: "person.fill",
                    body: "Listening… release ⌘ to send.",
                    dim: true
                )
            } else if case .transcribing = state.phase {
                qaCard(
                    label: "YOU",
                    iconSF: "person.fill",
                    body: "Transcribing your question…",
                    dim: true
                )
            }

            // A card — METACHAT response.
            if case .thinking = state.phase {
                qaCard(
                    label: "METACHAT",
                    iconSF: "sparkles",
                    body: "Composing answer…",
                    dim: true
                )
            } else if case .answered(let text) = state.phase {
                qaCard(
                    label: "METACHAT",
                    iconSF: "sparkles",
                    body: text,
                    dim: false
                )
            } else if case .error(let text) = state.phase {
                qaCard(
                    label: "ERROR",
                    iconSF: "exclamationmark.triangle.fill",
                    body: text,
                    dim: false,
                    accentOverride: .red
                )
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            phaseDot
            Text("METACHAT")
                .font(MW.monoSm).tracking(1.4)
                .foregroundStyle(MW.textMuted)
            Text(phaseLabel)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(MW.textPrimary)

            Spacer(minLength: 6)

            if state.isSpeaking {
                Button {
                    AppDelegate.shared?.ttsService.stop()
                    VoiceQuestionState.shared.isSpeaking = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 8))
                        Text("STOP").font(.system(size: 10, weight: .bold)).tracking(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(MW.live)
                    )
                }
                .buttonStyle(.plain)
                .help("Stop speaking (Space)")
            }

            Keycap(text: "Esc")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(headerTint)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }

    /// Subtle phase-color glaze on header background. Same idea as the
    /// MeetingCoach overlay's state strip — matches `MW.stateColor` palette.
    @ViewBuilder
    private var headerTint: some View {
        switch state.phase {
        case .listening:
            LinearGradient(
                colors: [MW.live.opacity(0.18), MW.live.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
        case .transcribing, .thinking:
            LinearGradient(
                colors: [MW.processing.opacity(0.18), MW.processing.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
        case .answered:
            LinearGradient(
                colors: [MW.idle.opacity(0.14), MW.idle.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
        case .error:
            LinearGradient(
                colors: [Color.red.opacity(0.18), Color.red.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
        case .idle:
            Color.clear
        }
    }

    @ViewBuilder
    private var phaseDot: some View {
        switch state.phase {
        case .listening:
            FVPulsingDot(color: MW.live, period: 1.0)
        case .transcribing, .thinking:
            Circle().fill(MW.processing).frame(width: 8, height: 8)
                .shadow(color: MW.processing.opacity(0.6), radius: 4)
        case .answered:
            FVPulsingDot(color: MW.idle, period: 1.6)
        case .error:
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .shadow(color: Color.red.opacity(0.6), radius: 4)
        case .idle:
            Circle().fill(MW.textDim).frame(width: 8, height: 8)
        }
    }

    private var phaseLabel: String {
        switch state.phase {
        case .idle: return "READY"
        case .listening: return "LISTENING"
        case .transcribing: return "TRANSCRIBING"
        case .thinking: return "THINKING"
        case .answered: return state.isSpeaking ? "SPEAKING" : "ANSWERED"
        case .error: return "ERROR"
        }
    }

    // MARK: - Q/A card

    private func qaCard(label: String, iconSF: String, body: String, dim: Bool, accentOverride: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconSF)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentOverride ?? MW.accent)
                .frame(width: 22, height: 22, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(MW.label).tracking(1.4)
                    .foregroundStyle(MW.textMuted)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(dim ? MW.textSecondary : MW.textPrimary)
                    .italic(dim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }
}

// MARK: - Phase pulse dot

/// File-private pulse dot — same animation pattern as MenuBarView's variant
/// (kept duplicated here to avoid a shared module-internal dependency for one
/// trivial view).
private struct FVPulsingDot: View {
    let color: Color
    let period: Double
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 4)
            .opacity(dim ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - SwiftUI compat shim

private extension View {
    @ViewBuilder
    func italic(_ on: Bool) -> some View {
        if on { self.italic() } else { self }
    }
}
