import SwiftUI

/// Floating overlay shown during an active meeting. Renders a stack of
/// LLM-generated suggestions plus a thin live transcript footer. Renders only
/// when `MeetingCoachState.shared.isVisible == true`.
///
/// Visual: glass card, ~360pt wide, anchored to bottom-right of the screen by
/// the controlling NSWindow. Newest suggestion at the TOP of the stack with a
/// short fade-in; older items fade slightly. Transcript footer at the bottom
/// shows the last ~200 chars of speech so the user can see the LLM's context.
struct MeetingCoachView: View {
    @ObservedObject var state: MeetingCoachState
    /// Closure to fire when the user clicks the STOP pill in the header.
    /// Wired by the window controller to `AppDelegate.toggleMeetingRecording`.
    var onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.suggestions.isEmpty {
                emptyState
            } else {
                suggestionList
            }
            if !state.transcriptTail.isEmpty {
                Divider().background(MW.hairlineColor)
                transcriptFooter
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MW.rLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MW.rLarge, style: .continuous)
                .strokeBorder(MW.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
        // Generous outer padding (was 12) so the 28pt-radius shadow has room
        // to render on every side of the card before the host window edge.
        .padding(.horizontal, 36)
        .padding(.vertical, 40)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isProcessing ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
                .shadow(color: state.isProcessing ? Color.orange.opacity(0.6) : Color.green.opacity(0.6), radius: 4)
            Text("MEETING COPILOT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(MW.textMuted)
            Spacer()
            if state.isProcessing {
                Text("THINKING…")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(MW.textMuted)
                    .transition(.opacity)
            }
            // STOP pill — manual escape hatch so user never gets a stuck
            // overlay if auto-stop heuristics miss the call end.
            if let onStop {
                Button(action: onStop) {
                    Text("STOP")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.red.opacity(0.85))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        Text("Listening… first suggestion appears in ~30 sec")
            .font(.system(size: 12))
            .foregroundStyle(MW.textMuted)
            .padding(.vertical, 4)
    }

    private var suggestionList: some View {
        // Newest first.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.suggestions.reversed()) { item in
                SuggestionRow(item: item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: state.suggestions.count)
    }

    private var transcriptFooter: some View {
        Text(state.transcriptTail)
            .font(.system(size: 10.5))
            .foregroundStyle(MW.textDim)
            .lineLimit(2)
            .truncationMode(.head)
    }
}

/// A single suggestion row. Kind drives accent color + label.
private struct SuggestionRow: View {
    let item: MeetingCoachState.Suggestion

    private var accent: Color {
        switch item.kind {
        case .question:  return Color.blue
        case .attention: return Color.orange
        case .missed:    return Color.purple
        case .followUp:  return Color.green
        }
    }

    private var label: String {
        switch item.kind {
        case .question:  return "ASK"
        case .attention: return "NOTICE"
        case .missed:    return "MISSED"
        case .followUp:  return "FOLLOW-UP"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(accent.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(accent.opacity(0.35), lineWidth: 0.5)
                )
                .padding(.top, 1)
            Text(item.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MW.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }
}
