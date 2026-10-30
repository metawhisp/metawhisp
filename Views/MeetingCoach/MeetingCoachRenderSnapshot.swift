import Foundation

/// A single display revision. The controller measures this value before installing
/// it; actions still reach the original state and transcript ownership stays there.
@MainActor
struct MeetingCoachRenderSnapshot: Equatable {
    let selectedTab: MeetingCoachState.Tab
    let isHalted: Bool
    let displayedBlocks: [MeetingAnswerBlock]
    let renderedBlocks: [AttributedString]
    let displayedHeard: String?
    let displayedQuestion: String?
    let showsThinkingPlaceholder: Bool
    let status: String?
    let canRequestAnswers: Bool
    let canExpandLatest: Bool
    let isAskOpen: Bool
    let questionPlaceholder: String
    let transcriptTail: [LiveMeetingTranscript.Line]
    let isExpanded: Bool
    let screenContextEnabled: Bool
    let busyRequest: MeetingCoachBusyRequest?
    let repeatPulses: [MeetingAnswerAction: Int]
    let panelHidden: Bool
    let hasUnseenAnswer: Bool
    let isStopping: Bool
    let requestID: UUID?
    let generation: Int?
    let isDraft: Bool
    let shouldShowPanel: Bool

    init(state: MeetingCoachState, expanded: Bool, screenContextEnabled: Bool) {
        selectedTab = state.selectedTab
        isHalted = state.isHalted
        displayedBlocks = state.displayedBlocks
        renderedBlocks = state.renderedBlocks
        displayedHeard = state.displayedHeard
        displayedQuestion = state.displayedQuestion
        showsThinkingPlaceholder = state.showsThinkingPlaceholder
        status = state.status
        canRequestAnswers = state.canRequestAnswers
        canExpandLatest = state.canExpandLatest
        isAskOpen = state.isAskOpen
        questionPlaceholder = state.questionPlaceholder
        transcriptTail = state.selectedTab == .transcript && !state.isHalted ? state.transcriptTail : []
        isExpanded = expanded
        self.screenContextEnabled = screenContextEnabled
        busyRequest = state.busyRequest
        repeatPulses = Dictionary(uniqueKeysWithValues: [MeetingAnswerAction.questions, .recap, .more, .screen]
            .map { ($0, state.repeatPulse(for: $0)) })
        panelHidden = state.panelHidden
        hasUnseenAnswer = state.hasUnseenAnswer
        isStopping = state.isStopping
        let displayedDraft = state.displayedDraft
        requestID = displayedDraft?.requestID ?? state.answers.first?.id
        generation = displayedDraft?.generation ?? state.answers.first?.generation
        isDraft = displayedDraft != nil
        shouldShowPanel = state.shouldShowPanel(isExpanded: expanded)
    }

    func repeatPulse(for action: MeetingAnswerAction) -> Int { repeatPulses[action, default: 0] }

    /// Inputs that can change measured height. Header feedback and native editing
    /// update content independently without restarting a running frame animation.
    struct Layout: Equatable {
        let selectedTab: MeetingCoachState.Tab
        let isHalted: Bool
        let blocks: [MeetingAnswerBlock]
        let heard: String?
        let question: String?
        let showsThinking: Bool
        let status: String?
        let canRequestAnswers: Bool
        let isAskOpen: Bool
        let transcript: [LiveMeetingTranscript.Line]
        let isExpanded: Bool
        let screenContextEnabled: Bool
    }

    var layout: Layout {
        let answers = selectedTab == .answers || isHalted
        return Layout(selectedTab: selectedTab, isHalted: isHalted,
            blocks: answers ? displayedBlocks : [], heard: answers ? displayedHeard : nil,
            question: answers ? displayedQuestion : nil, showsThinking: answers && showsThinkingPlaceholder,
            status: answers ? status : nil, canRequestAnswers: answers && canRequestAnswers,
            isAskOpen: answers && isAskOpen, transcript: transcriptTail,
            isExpanded: isExpanded, screenContextEnabled: answers && screenContextEnabled)
    }
}
