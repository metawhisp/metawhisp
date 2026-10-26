import Combine
import Foundation

/// C6 — the one owner of microphone capture between dictation, meetings and
/// the onboarding practice.
///
/// The practice takes the microphone for as long as its screen is up. Until it
/// gives it back, every other entry point asks here and is refused politely —
/// the record buttons, push-to-talk, the voice question, a meeting's start —
/// and a hotkey drives the practice instead. The practice in turn waits while
/// a dictation or a meeting is under way.
///
/// Each refusal names what ends it: the practice's end (Back, Next, the window
/// closing), or the practice itself going away, gives capture back; the end of
/// the dictation or meeting lets a waiting practice in (`recheck`).
@MainActor
final class CaptureArbiter: ObservableObject {
    static let finishThePracticeFirst = "Finish the practice first"
    static let finishYourDictationFirst = "Finish your dictation first"

    /// The practice that owns capture. Weak: a practice that goes away without
    /// ending takes its claim with it.
    private(set) weak var practice: PracticeRecorder?
    /// A practice waiting for a dictation or a meeting to end.
    private weak var waiting: PracticeRecorder?
    /// Whether a practice owns capture, for whoever showed one of its refusals.
    @Published private(set) var practiceOwnsCapture = false
    /// The lease writer: the practice records or transcribes.
    var onPracticeBusy: ((Bool) -> Void)?

    private let busyElsewhere: () -> Bool

    /// - Parameter busyElsewhere: a dictation or a meeting is recording or
    ///   being transcribed.
    init(busyElsewhere: @escaping () -> Bool) {
        self.busyElsewhere = busyElsewhere
    }

    /// What a dictation or a meeting is told when it asks to start; nil = go.
    var refusal: String? {
        reconcile()
        return practice == nil ? nil : Self.finishThePracticeFirst
    }

    /// A hotkey: the practice's while it owns capture, dictation's otherwise.
    func route(dictation: () -> Void, practice handle: (PracticeRecorder) -> Void) {
        reconcile()
        if let practice { handle(practice) } else { dictation() }
    }

    /// The practice screen asks for the microphone: nil when it has it now,
    /// otherwise what it waits for — `granted()` tells it when it's in.
    func claim(for practice: PracticeRecorder) -> String? {
        reconcile()
        if self.practice === practice { return nil }
        guard self.practice == nil, !busyElsewhere() else {
            waiting = practice
            return Self.finishYourDictationFirst
        }
        grant(practice)
        return nil
    }

    func release(_ practice: PracticeRecorder) {
        if waiting === practice { waiting = nil }
        guard self.practice === practice else { return }
        self.practice = nil
        practiceOwnsCapture = false
        onPracticeBusy?(false)
    }

    /// Something a waiting practice waits for may have ended.
    func recheck() {
        reconcile()
        guard practice == nil, let waiting, !busyElsewhere() else { return }
        self.waiting = nil
        grant(waiting)
        waiting.granted()
    }

    /// The owning practice records or transcribes, or stopped.
    func practice(_ practice: PracticeRecorder, isBusy: Bool) {
        guard self.practice === practice else { return }
        onPracticeBusy?(isBusy)
    }

    func owns(_ practice: PracticeRecorder) -> Bool {
        self.practice === practice
    }

    private func grant(_ practice: PracticeRecorder) {
        self.practice = practice
        practiceOwnsCapture = true
    }

    /// A practice that went away without ending gave capture back.
    private func reconcile() {
        guard practice == nil, practiceOwnsCapture else { return }
        practiceOwnsCapture = false
        onPracticeBusy?(false)
    }
}
