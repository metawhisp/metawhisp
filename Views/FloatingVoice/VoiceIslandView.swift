import SwiftUI

/// ITER-078 — the Island: the voice window as the owner chose it on
/// 2026-09-28 (canvas "Jev agent interface", board 7). It fills its window,
/// whose frame the controller animates from `VoiceIslandPresenter.shape`; this
/// view draws the stage inside it. Glass in MetaWhisp's appearance (its Theme
/// setting, as every MetaWhisp window), text in semantic colours, characters
/// in the system's monospaced face.
struct VoiceIslandView: View {
    @ObservedObject var presenter: VoiceIslandPresenter
    @ObservedObject var state: VoiceQuestionState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let radius = presenter.shape?.cornerRadius ?? 7
        ZStack {
            content
                .id(presenter.stage)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(glass)
        .overlay(alignment: .top) {
            // The rim: a thin light along the top edge.
            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.9))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: presenter.stage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice question")
        .accessibilityValue(stageName)
    }

    @ViewBuilder
    private var glass: some View {
        if colorScheme == .dark {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255).opacity(0.72))
        } else {
            Rectangle().fill(.regularMaterial)
                .overlay(Color(white: 0.985).opacity(0.62))
        }
    }

    // MARK: - Stages

    @ViewBuilder
    private var content: some View {
        switch presenter.stage {
        case .seed, nil:
            Color.clear
        case .listening:
            listening
        case .transcribing:
            // The bits are decoration: VoiceOver says "Transcribing" instead.
            streamRow(label: "TRANSCRIBING", text: VoiceIsland.bitStream(count: 60, frame: presenter.frame),
                      spoken: nil)
        case .decoding:
            // The words are the user's, decoding out of the bits.
            streamRow(label: "YOU",
                      text: VoiceIsland.decode(state.transcript, progress: presenter.decodeProgress,
                                               frame: presenter.frame),
                      spoken: state.transcript)
        case .thinking:
            thinking
        case .answer:
            answer
        case .error:
            IslandError(text: errorText, retriesByVoice: state.errorRetriesByVoice) { height in
                presenter.errorContentHeight = height
            }
        }
    }

    private var listening: some View {
        HStack(spacing: 10) {
            IslandDot(color: MW.live, breathes: !reduceMotion)
            Text(VoiceIsland.wave(levels: presenter.levels))
                .font(.system(size: 12, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            Text("Listening…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
    }

    /// `spoken` is what VoiceOver reads for `text`; nil hides it.
    private func streamRow(label: String, text: String, spoken: String?) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityHidden(spoken == nil)
                .accessibilityLabel(spoken ?? "")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    /// The ticker alone: the design's label named Jev, and a voice question
    /// is not answered by Jev yet (it routes from ITER-076 Stage 4).
    private var thinking: some View {
        Text(VoiceIsland.ticker(frame: presenter.frame))
            .font(.system(size: 12, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
            .modifier(Breathing(active: !reduceMotion))
    }

    private var answer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IslandDot(color: .green, breathes: false)
                Text(state.isSpeaking ? "SPEAKING" : "ANSWER")
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if state.isSpeaking {
                    Button {
                        AppDelegate.shared?.ttsService.stop()
                        VoiceQuestionState.shared.isSpeaking = false
                    } label: {
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(Capsule().fill(MW.live))
                    }
                    .buttonStyle(.plain)
                    .help("Stop speaking (Space)")
                }
                EscButton()
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !state.transcript.isEmpty {
                        Text(state.transcript)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(answerText)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Laid out at the panel's own width, so it is measured once,
                // not at every width the window passes while it grows.
                .frame(width: VoiceIsland.answerWidth - 36, alignment: .leading)
                .padding(.bottom, 16)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: AnswerHeightKey.self, value: ceil(proxy.size.height) + 40)
                    }
                )
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(AnswerHeightKey.self) { height in
            presenter.answerContentHeight = height
        }
    }

    private var answerText: String {
        if case .answered(let text) = state.phase { return text }
        return ""
    }

    private var errorText: String {
        if case .error(let text) = state.phase { return text }
        return ""
    }

    private var stageName: String {
        switch presenter.stage {
        case .seed, .listening: return "Listening"
        case .transcribing, .decoding: return "Transcribing"
        case .thinking: return "Thinking"
        case .answer: return state.isSpeaking ? "Speaking the answer" : "Answer"
        case .error: return "Error"
        case nil: return ""
        }
    }
}

/// The answer panel's content height, header included, for the window.
private struct AnswerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The error goes flat and says why, in full; "Hold Right ⌘ to try again" only
/// when asking again by voice can fix it. The window shakes the whole island.
private struct IslandError: View {
    let text: String
    let retriesByVoice: Bool
    let measured: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 12) {
            IslandDot(color: MW.live, breathes: false)
            Text(VoiceIsland.flatLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.quaternary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    // Five lines and the hint fill the tallest error panel.
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                if retriesByVoice {
                    Text("Hold Right ⌘ to try again")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            EscButton()
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        // Laid out at the panel's own width, and measured there.
        .frame(width: 480)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ErrorHeightKey.self, value: ceil(proxy.size.height))
            }
        )
        .onPreferenceChange(ErrorHeightKey.self) { measured($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A status dot, breathing while it is live.
private struct IslandDot: View {
    let color: Color
    let breathes: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 4)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard breathes else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// The thinking capsule breathes while it waits.
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.6 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Closes the island; the Esc key does the same.
private struct EscButton: View {
    var body: some View {
        Button {
            VoiceQuestionState.shared.dismiss()
        } label: {
            Text("Esc")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.primary.opacity(0.12), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}
