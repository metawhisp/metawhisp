import SwiftUI

/// Screen 3 of 4 — one sentence through the real engine, shown here and nowhere else (US3). The step-1 practice
/// records on the app's own microphone and keeps nothing; the box shows what it and the speech model are doing
/// (mockup v6 `voiceLayer`). The 76 pt button or Space records; Esc cancels an attempt and stays on the screen.
struct TryVoiceScreen: View {
    /// What the box shows.
    enum Box: Equatable {
        /// The speech model is on its way: its % while it downloads.
        case preparing(percent: Int?)
        /// The speech model could not be got: why, and Try again.
        case modelProblem(title: String, detail: String?)
        /// A dictation or a meeting has the microphone; the practice gets it when they end (C7).
        case waiting(String)
        /// Ready to record, or recording; `hint` names Right ⌘ only where it works.
        case recorder(listening: Bool, hint: String?)
        case transcribing
        case result(String)
        case noSpeech
        case failed(String)
    }

    static let title = "Try your voice"
    static let next = "Continue"
    static let preparing = "Getting dictation ready…"
    static let resultHeading = "Your words, ready to use."
    static let noSpeech = "No speech detected."
    static let closer = "Try again a little closer to the microphone."
    static let tryAgain = "Try again"
    static let skip = "Skip for now"
    static let example = "For example: “Send the notes tomorrow morning.”"
    static let boxSize = CGSize(width: 624, height: 236)

    /// Right ⌘ is promised only with Accessibility on (C10), and as the hotkey mode works it: tapped, or held.
    static func instruction(_ rightCommand: RightCommand) -> String {
        switch rightCommand {
        case .tap: return "Press the button or Right ⌘, say a sentence, then press again."
        case .hold: return "Hold Right ⌘, say a sentence, release."
        case .unavailable: return "Press the button, say a sentence, then press again."
        }
    }

    /// An attempt under way and its words come first; then the speech model, until it is ready; then the practice
    /// and an attempt that gave no words. "No speech detected" over a model that could not be got hid its Try
    /// again, Sign in and Skip while Continue stayed off (Codex step-2 #5): Right ⌘ starts a practice while the
    /// model is still on its way.
    static func box(phase: PracticeRecorder.Phase, model: ModelPreparer.State, rightCommand: RightCommand) -> Box {
        switch phase {
        case .listening: return .recorder(listening: true, hint: rightCommand == .tap ? "or tap Right ⌘ again" : nil)
        case .transcribing: return .transcribing
        case .result(let text): return .result(text)
        case .ready, .waiting, .noSpeech, .failed: break
        }
        switch model {
        case .downloading(let progress):
            return .preparing(percent: Int((progress * 100).rounded()))
        case .loading:
            return .preparing(percent: nil)
        case .failed(let why):
            return .modelProblem(title: why, detail: nil)
        case .lowDisk:
            return .modelProblem(title: ModelPreparer.lowDiskTitle, detail: ModelPreparer.lowDiskDetail)
        case .ready:
            break
        }
        switch phase {
        case .waiting(let reason): return .waiting(reason)
        case .noSpeech: return .noSpeech
        case .failed(let why): return .failed(why)
        default:
            switch rightCommand {
            case .tap: return .recorder(listening: false, hint: "or tap Right ⌘")
            case .hold: return .recorder(listening: false, hint: "or hold Right ⌘")
            case .unavailable: return .recorder(listening: false, hint: nil)
            }
        }
    }

    /// "Already have Pro? Sign in" — for the model wait and its problems: a Pro user can dictate on the cloud.
    static func showsSignIn(_ box: Box) -> Bool {
        switch box {
        case .preparing, .modelProblem: return true
        default: return false
        }
    }

    /// "Skip for now": only when the speech model could not be got — offline, a failed download, a full disk —
    /// where the user would have no words to continue with; never while it is on its way.
    static func showsSkip(_ box: Box) -> Bool {
        if case .modelProblem = box { return true }
        return false
    }

    /// Continue opens on the user's own words.
    static func continueEnabled(_ phase: PracticeRecorder.Phase) -> Bool {
        if case .result = phase { return true }
        return false
    }

    /// What VoiceOver says when the box changes state: once per state — a download's next percent, or the hint
    /// following Accessibility, is the same state — and nothing as the screen appears (VoiceOver reads it then).
    static func announcement(_ old: Box, _ new: Box) -> String? {
        guard kind(old) != kind(new) else { return nil }
        switch new {
        case .preparing, .recorder, .transcribing: return label(new)
        case .modelProblem(let title, let detail): return [title, detail].compactMap { $0 }.joined(separator: " ")
        case .waiting(let reason), .failed(let reason): return reason
        case .result(let text): return "\(resultHeading) \(text)"
        case .noSpeech: return "\(noSpeech) \(closer)"
        }
    }

    /// A box's state, without what changes inside one.
    private static func kind(_ box: Box) -> String {
        switch box {
        case .preparing: "preparing"
        case .modelProblem: "model problem"
        case .waiting: "waiting"
        case .recorder(let listening, _): listening ? "listening" : "ready"
        case .transcribing: "transcribing"
        case .result: "result"
        case .noSpeech: "no speech"
        case .failed: "failed"
        }
    }

    /// The record button's words, under it and for VoiceOver.
    static func label(_ box: Box) -> String? {
        switch box {
        case .recorder(let listening, _): return listening ? "Listening… tap to stop" : "Start recording"
        case .transcribing: return "Transcribing…"
        case .preparing: return preparing
        default: return nil
        }
    }

    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var practice: PracticeRecorder
    @ObservedObject var preparer: ModelPreparer
    /// The practice's microphone, for the wave and the halo.
    @ObservedObject var microphone: AudioRecordingService

    var body: some View {
        let rightCommand = RightCommand.current(accessibility: flow.permissions.accessibility,
                                                hotkeyMode: AppSettings.shared.hotkeyMode)
        let box = Self.box(phase: practice.phase, model: preparer.state, rightCommand: rightCommand)
        OnboardingPage {
            VStack(spacing: 0) {
                OnboardingTitle(text: Self.title)
                KeyedText(text: Self.instruction(rightCommand), font: .system(size: 15))
                    .foregroundStyle(MW.textSecondary)
                    .padding(.top, 10)
                BoxView(box: box, level: microphone.audioLevel, bars: microphone.audioBars, record: flow.record,
                        tryAgain: flow.record, retryModel: preparer.retry, signIn: flow.signIn, skip: flow.skipPractice)
                    .padding(.top, 22)
                if flow.accountLinkShown {
                    AccountLinkFallback().padding(.top, 10)
                }
                Text(Self.example)
                    .font(.system(size: 13))
                    .foregroundStyle(MW.textSecondary)
                    .padding(.top, 12)
            }
        } leading: {
            Button("Back") { flow.back() }.buttonStyle(OnboardingTextButtonStyle())
        } center: {
            Button { flow.next() } label: { ArrowLabel(text: Self.next) }
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.continueEnabled(practice.phase))
        }
        .background {
            // Esc: the attempt under way is cancelled; the screen stays.
            Button("") { flow.cancelAttempt() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: box) { old, new in
            if let words = Self.announcement(old, new) {
                AccessibilityNotification.Announcement(words).post()
            }
        }
        .overlay {
            if practice.phase == .listening {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MW.recording.opacity(0.55), lineWidth: 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    /// The 624 × 236 box. A long text scrolls inside it; the box keeps its size (C9).
    struct BoxView: View {
        /// The gap between the wave, the record button and its words — the mockup's rhythm (`.voice .lay`).
        static let rhythm: CGFloat = 5

        let box: Box
        let level: Float
        var bars: [Float] = []
        let record: () -> Void
        let tryAgain: () -> Void
        let retryModel: () -> Void
        let signIn: () -> Void
        let skip: () -> Void

        var body: some View {
            content
                .frame(width: TryVoiceScreen.boxSize.width, height: TryVoiceScreen.boxSize.height)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MW.surface))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }

        @ViewBuilder
        private var content: some View {
            switch box {
            case .preparing(let percent):
                VStack(spacing: Self.rhythm) {
                    RecordButton(state: .busy, level: 0, label: TryVoiceScreen.preparing, action: {}).disabled(true)
                    VStack(spacing: 6) {
                        Heading(text: TryVoiceScreen.preparing)
                        if let percent {
                            ProgressBar(fraction: Double(percent) / 100).padding(.top, 6)
                            Text("\(percent)%").font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(Color.primary.opacity(0.55))
                        }
                    }
                    AlreadyHaveProButton(action: signIn)
                }
            case .modelProblem(let title, let detail):
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Heading(text: title)
                        if let detail { Detail(text: detail) }
                    }
                    TryAgainButton(action: retryModel, recordsOnSpace: false)
                    AlreadyHaveProButton(action: signIn)
                    if TryVoiceScreen.showsSkip(box) {
                        Button(TryVoiceScreen.skip, action: skip)
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.62))
                    }
                }
            case .waiting(let reason):
                VStack(spacing: Self.rhythm) {
                    RecordButton(state: .idle, level: 0, label: reason, action: record).disabled(true)
                    Heading(text: reason)
                }
            case .recorder(let listening, let hint):
                VStack(spacing: Self.rhythm) {
                    Wave(bars: listening ? bars : [])
                    RecordButton(state: listening ? .listening : .idle, level: listening ? level : 0,
                                 label: TryVoiceScreen.label(box) ?? "", action: record)
                    VStack(spacing: 4) {
                        Heading(text: TryVoiceScreen.label(box) ?? "")
                        KeyedText(text: hint ?? " ", font: .system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.62))
                    }
                }
            case .transcribing:
                VStack(spacing: Self.rhythm) {
                    Wave(bars: [])
                    RecordButton(state: .busy, level: 0, label: TryVoiceScreen.label(box) ?? "", action: {}).disabled(true)
                    VStack(spacing: 4) {
                        Heading(text: TryVoiceScreen.label(box) ?? "")
                        Detail(text: " ")
                    }
                }
            case .result(let text):
                ZStack(alignment: .bottomTrailing) {
                    // A sentence or two sits in the middle of the box, as the mockup has it; a longer text starts at
                    // the top and scrolls in the room above Try again.
                    ViewThatFits(in: .vertical) {
                        ResultWords(text: text, scrolls: false).padding(.horizontal, 30).padding(.vertical, 64)
                        ResultWords(text: text, scrolls: true).padding(.horizontal, 30).padding(.top, 26)
                            .padding(.bottom, 64)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    TryAgainButton(action: tryAgain, recordsOnSpace: true)
                        .padding(.trailing, 20)
                        .padding(.bottom, 18)
                }
            case .noSpeech:
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Heading(text: TryVoiceScreen.noSpeech)
                        Detail(text: TryVoiceScreen.closer)
                    }
                    TryAgainButton(action: tryAgain, recordsOnSpace: true)
                }
            case .failed(let why):
                VStack(spacing: 14) {
                    Heading(text: why).padding(.horizontal, 40)
                    TryAgainButton(action: tryAgain, recordsOnSpace: true)
                }
            }
        }
    }
}

/// The words the practice heard, under their heading — whole, or in a scroll when they are long.
private struct ResultWords: View {
    let text: String
    let scrolls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(TryVoiceScreen.resultHeading).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MW.textSecondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MW.idle)
            }
            if scrolls {
                ScrollView { words }
            } else {
                words
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var words: some View {
        Text(text)
            .font(.system(size: 26))
            .tracking(-0.3)
            .foregroundStyle(MW.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Heading: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(MW.textPrimary)
            .multilineTextAlignment(.center)
    }
}

private struct Detail: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.62)).multilineTextAlignment(.center)
    }
}

private struct TryAgainButton: View {
    let action: () -> Void
    /// Space records here too, where Try again is a new recording.
    let recordsOnSpace: Bool

    var body: some View {
        let button = Button(action: action) {
            Label(TryVoiceScreen.tryAgain, systemImage: "arrow.clockwise")
        }
        .buttonStyle(RowButtonStyle(prominent: false))
        if recordsOnSpace {
            button.keyboardShortcut(.space, modifiers: [])
        } else {
            button
        }
    }
}

/// "Already have Pro? Sign in".
struct AlreadyHaveProButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The mockup sets "Sign in" a little apart from the question.
            HStack(spacing: 8) {
                Text("Already have Pro?").foregroundStyle(MW.textSecondary)
                Text("Sign in").fontWeight(.semibold).foregroundStyle(MW.textPrimary)
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .frame(minHeight: 32)
    }
}

/// The 76 pt record button: white with a red dot to start, red with a white square while it listens — its halo
/// breathing with the voice — and a spinner while it waits.
private struct RecordButton: View {
    enum Look { case idle, listening, busy }

    let state: Look
    let level: Float
    /// What it does now, for VoiceOver.
    let label: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                if state == .listening {
                    Circle()
                        .stroke(MW.recording.opacity(0.55), lineWidth: 2)
                        .frame(width: 94, height: 94)
                        .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(level) * 0.42)
                        .opacity(0.18 + Double(level) * 0.8)
                }
                Circle()
                    .fill(fill)
                    .frame(width: 76, height: 76)
                    .shadow(color: shadow, radius: 15, y: 14)
                switch state {
                case .idle:
                    Circle().fill(MW.recording).frame(width: 26, height: 26)
                case .listening:
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white).frame(width: 22, height: 22)
                case .busy:
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])   // Space records; a disabled button takes no key
        .accessibilityLabel(label)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .idle: AnyShapeStyle(LinearGradient(colors: [.white, Color(w: 0.91)], startPoint: .top, endPoint: .bottom))
        case .listening: AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.37),
                                                               Color(red: 0.9, green: 0.21, blue: 0.17)],
                                                      startPoint: .top, endPoint: .bottom))
        case .busy: AnyShapeStyle(Color.primary.opacity(0.1))
        }
    }

    private var shadow: Color {
        switch state {
        case .idle: .black.opacity(0.4)
        case .listening: MW.recording.opacity(0.35)
        case .busy: .clear
        }
    }
}

/// The model's download, as the mockup draws it: a thin bar, 200 pt.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.14))
            Capsule().fill(MW.textPrimary).frame(width: 200 * min(max(fraction, 0), 1))
        }
        .frame(width: 200, height: 4)
        .accessibilityHidden(true)
    }
}

/// The voice above the button: the microphone's bars while it listens, a flat line otherwise.
private struct Wave: View {
    let bars: [Float]

    var body: some View {
        // 24 bars 8 pt apart: as wide as the mockup's wave.
        HStack(spacing: 5) {
            ForEach(0..<24, id: \.self) { index in
                let value = index < bars.count ? CGFloat(bars[index]) : 0
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MW.textPrimary)
                    .frame(width: 3, height: max(2, 2 + value * 38))
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}
