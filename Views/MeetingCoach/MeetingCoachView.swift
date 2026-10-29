import SwiftUI

/// The single visible exchange. Natural height is measured by the controller;
/// every card type shares its viewport and scrolls only beyond that viewport.
@MainActor
struct MeetingCoachView: View {
    @ObservedObject var state: MeetingCoachState
    @ObservedObject var presentation: MeetingCoachPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("screenContextEnabled") private var screenContextEnabled = false
    var snapshot: MeetingCoachRenderSnapshot?
    var drawsSurface = true
    var includesHeader = true
    var reduceMotionOverride: Bool?
    var onQuestionFieldReady: ((MeetingCoachQuestionTextField) -> Void)?

    init(state: MeetingCoachState, presentation: MeetingCoachPresentation? = nil,
         drawsSurface: Bool = true, includesHeader: Bool = true, reduceMotionOverride: Bool? = nil,
         snapshot: MeetingCoachRenderSnapshot? = nil,
         onQuestionFieldReady: ((MeetingCoachQuestionTextField) -> Void)? = nil) {
        self.state = state
        self.snapshot = snapshot
        self.presentation = presentation ?? MeetingCoachPresentation()
        self.drawsSurface = drawsSurface
        self.includesHeader = includesHeader
        self.reduceMotionOverride = reduceMotionOverride
        self.onQuestionFieldReady = onQuestionFieldReady
    }

    private var content: MeetingCoachRenderSnapshot {
        snapshot ?? MeetingCoachRenderSnapshot(state: state, expanded: presentation.isExpanded,
                                               screenContextEnabled: screenContextEnabled)
    }

    var showsScreenButton: Bool { snapshot?.screenContextEnabled ?? screenContextEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if includesHeader { MeetingCoachHeaderView(state: state, snapshot: snapshot) }
            Group {
                if content.selectedTab == .transcript && !content.isHalted {
                    transcriptContent.transition(.opacity)
                } else {
                    answersContent.transition(.opacity)
                }
            }
            .animation(crossFade, value: content.selectedTab)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: 392, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background { if drawsSurface { MeetingCoachPanelSurface() } }
        .focusable(false)
        .textSelection(.disabled)
    }

    private var crossFade: Animation? {
        snapshot != nil || (reduceMotionOverride ?? reduceMotion) ? .easeOut(duration: 0.18) : nil
    }

    private var answersContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = content.displayedQuestion { questionBubble(question) }
            if let heard = content.displayedHeard {
                Text("Them · \(heard)")
                    .font(.system(size: 12))
                    .foregroundStyle(MW.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !content.displayedBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(content.displayedBlocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, rendered: content.renderedBlocks[index])
                    }
                }
            }
            if content.showsThinkingPlaceholder { statusLine("Thinking…") }
            if let status = content.status { statusLine(status) }
            if content.canRequestAnswers {
                Group {
                    if content.isAskOpen {
                        questionField.transition(.opacity)
                    } else if content.isExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            if !content.displayedBlocks.isEmpty || content.status != nil || content.showsThinkingPlaceholder {
                                Rectangle().fill(MW.border).frame(height: 0.5)
                            }
                            actionButtons
                        }
                        .transition(.opacity)
                    }
                }
                .animation(crossFade, value: content.isAskOpen)
                .animation(crossFade, value: content.isExpanded)
            }
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if content.transcriptTail.isEmpty {
                statusLine("No lines yet")
            } else {
                ForEach(Array(content.transcriptTail.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.speaker == .them ? "Them" : "Me")
                            .foregroundStyle(MW.textSecondary)
                            .frame(width: 38, alignment: .leading)
                        Text(line.text).foregroundStyle(MW.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13.5))
                }
            }
        }
    }

    private func questionBubble(_ question: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(question)
                .font(.system(size: 13))
                .foregroundStyle(MW.textPrimary)
                .padding(.vertical, 7).padding(.horizontal, 12)
                .background(.primary.opacity(0.08), in: UnevenRoundedRectangle(
                    topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16))
                .frame(maxWidth: 288, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var questionField: some View {
        HStack(spacing: 6) {
            MeetingCoachQuestionField(state: state, placeholder: content.questionPlaceholder,
                onClose: state.closeAsk, onReady: onQuestionFieldReady)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 26)
                .help(content.questionPlaceholder)
            MeetingCoachButton(title: "Send", isEnabled: !state.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                state.submitQuestion()
            }
            .symbol("arrow.up", accent: true)
            .background(MW.accent, in: Circle())
            MeetingCoachButton(title: "Close question", action: state.closeAsk)
                .symbol("xmark")
                .background(.quaternary, in: Circle())
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(MW.border, lineWidth: 0.5))
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            MeetingCoachButton(title: "Questions") { state.actionPressed(.questions) }.repeatFeedback(content.repeatPulse(for: .questions)).padded(horizontal: 6, vertical: 5).modifier(MeetingCoachChip())
            MeetingCoachButton(title: "Recap") { state.actionPressed(.recap) }.repeatFeedback(content.repeatPulse(for: .recap)).padded(horizontal: 6, vertical: 5).modifier(MeetingCoachChip())
            MeetingCoachButton(title: "More", isEnabled: content.canExpandLatest) {
                state.actionPressed(.more)
            }.repeatFeedback(content.repeatPulse(for: .more)).padded(horizontal: 6, vertical: 5).modifier(MeetingCoachChip())
            if showsScreenButton {
                MeetingCoachButton(title: "Screen", action: state.screenPressed).repeatFeedback(content.repeatPulse(for: .screen)).padded(horizontal: 6, vertical: 5).modifier(MeetingCoachChip())
            }
            MeetingCoachButton(title: "Ask…", action: state.openAsk).padded(horizontal: 6, vertical: 5).modifier(MeetingCoachChip())
        }
        .fixedSize()
    }

    @ViewBuilder
    private func blockView(_ block: MeetingAnswerBlock, rendered: AttributedString) -> some View {
        switch block {
        case .headline:
            Text(rendered)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MW.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(MW.textSecondary).frame(width: 4, height: 4)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(rendered)
                    .font(.system(size: 14))
                    .foregroundStyle(MW.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(rendered)
                .font(.system(size: 14))
                .foregroundStyle(MW.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(MW.textMuted)
            .lineLimit(1).truncationMode(.tail)
    }
}

struct MeetingCoachPanelSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
            .overlay(alignment: .top) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 0.5).padding(.horizontal, 22).padding(.top, 0.5)
            }
    }
}

private struct MeetingCoachChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(MW.border, lineWidth: 0.5))
    }
}

/// The answer as the overlay draws it: the bold sentence that opens it and
/// the catch points, each as attributed text with its bold run kept.
///
/// The markdown is read inline only, and the spaces inside it are kept: a
/// catch point is a fragment, and its words must not run together.
enum MeetingAnswerRender {
    /// The line an earlier answer shows: its headline, or — for an answer
    /// that has none — its first line.
    static func headline(_ answer: MeetingAnswer) -> AttributedString {
        let text = answer.headline ?? answer.blocks.first?.text ?? ""
        return MeetingAnswerContract.rendered(text)
    }

    /// A catch point as the card draws it: the marker and the text.
    static func bullet(_ text: String) -> AttributedString {
        var line = AttributedString("• ")
        line.append(MeetingAnswerContract.rendered(text))
        return line
    }
}
