import Carbon.HIToolbox
import Foundation
import XCTest
@testable import MetaWhisp

/// The fakes the live hints' wiring tests run on: the two streams, the
/// shortcut and the advice service.
///
/// They are fakes, not mocks: they keep what they were given, so a test can
/// read what the session did with them.
@MainActor
final class FakeLiveHintsStream: LiveHintsAudioStream {
    private var samples: [Float] = []
    /// The silence of a channel that joined late.
    var placedLeadingSilence: Int = 0

    /// Every read of the stream, with the level of what it brought.
    private(set) var reads: [(from: Int, count: Int, rms: Float)] = []

    var currentSampleCount: Int { samples.count }

    /// The channel joins the meeting late: the silence of the part it missed
    /// sits at the front of its buffer, exactly as the capture service does it.
    func joinLate(afterSamples count: Int) {
        placedLeadingSilence = count
        samples = [Float](repeating: 0, count: count)
    }

    /// Adds samples to the stream.
    func append(_ new: [Float]) {
        samples.append(contentsOf: new)
    }

    /// The capture was restarted: the buffer and its padding are replaced.
    ///
    /// The new buffer starts empty — with the silence of the part the
    /// channel missed at its front, when it joins late. It may also hold the
    /// audio the new capture already took.
    func replaceBuffer(leadingSilence: Int = 0, alreadyHolding held: Int = 0) {
        placedLeadingSilence = leadingSilence
        samples = [Float](repeating: 0, count: leadingSilence + held)
    }

    func peekSamples(from: Int, count: Int) -> [Float] {
        guard count > 0, from < samples.count else { return [] }
        let start = max(0, from)
        let end = min(samples.count, start + count)
        let slice = Array(samples[start..<end])
        reads.append((from: start, count: slice.count, rms: SpeechActivity.rootMeanSquare(slice)))
        return slice
    }
}

/// The shortcut the tests press.
@MainActor
final class FakeLiveHintsHotkey: MeetingHelpShortcut {
    /// The registrations that were taken.
    private(set) var registrations: [(keyCode: Int, modifiers: Int)] = []
    /// Every registration that was asked for, the failed ones included.
    private(set) var attempts: [(keyCode: Int, modifiers: Int)] = []
    private(set) var unregistered = 0
    var shortcutLabel: String?
    var onPress: (() -> Void)?
    /// How many registrations fail before one is taken.
    var failuresLeft = 0
    /// Whether a combo is registered right now.
    private var isRegistered = false
    /// The owner that holds the registration right now.
    private var currentOwner: UUID?

    @discardableResult
    func register(keyCode: Int, modifiers: Int, owner: UUID) -> Bool {
        attempts.append((keyCode, modifiers))
        // The real shortcut takes the old combo back before it registers the
        // new one — and it takes it back even when the new one fails.
        if isRegistered { unregistered += 1 }
        isRegistered = false
        currentOwner = nil
        shortcutLabel = nil
        if failuresLeft > 0 {
            failuresLeft -= 1
            return false
        }
        isRegistered = true
        currentOwner = owner
        registrations.append((keyCode, modifiers))
        shortcutLabel = MeetingHelpLabel.label(keyCode: keyCode, modifiers: modifiers)
        return true
    }

    @discardableResult
    func unregister(owner: UUID) -> Bool {
        // Only the owner that holds the registration may take it back.
        guard currentOwner == owner else { return false }
        currentOwner = nil
        guard isRegistered else { return false }
        isRegistered = false
        unregistered += 1
        shortcutLabel = nil
        onPress = nil
        return true
    }

    /// A press of the shortcut.
    func press() {
        onPress?()
    }
}

/// The advice service the tests watch.
@MainActor
final class FakeLiveHintsAdvice: LiveHintsAdvice {
    private(set) var calls: [(text: String, source: String)] = []

    func triggerOnTranscription(text: String, source: String) {
        calls.append((text, source))
    }
}

/// An environment of fakes: the session runs on it without a window server,
/// an engine or a network.
@MainActor
struct FakeLiveHintsEnvironment {
    let mic = FakeLiveHintsStream()
    let system = FakeLiveHintsStream()
    let hotkey = FakeLiveHintsHotkey()
    let advice = FakeLiveHintsAdvice()
    let state = MeetingCoachState()
    let pro = FakeRoute(routeName: "pro")
    let combo = LiveValueBox(MeetingHelpCombo(keyCode: MeetingHelpDefaults.keyCode,
                                              modifiers: MeetingHelpDefaults.modifiers))
    /// The defaults the switch of the automatic answers lives in.
    ///
    /// Its own suite: the tests must not touch the settings of the user.
    let defaults = UserDefaults(suiteName: "MetaWhispTests.liveHints")!
    /// The key the switch of the automatic answers is stored under.
    let autoAnswerKey = "meetingAutoAnswer"
    /// Whether the app may take a shortcut at all.
    let globalInputEnabled = LiveValueBox(true)
    /// The time now. The tests move it by hand.
    let clock = LiveValueBox(Date())
    /// The engine the fake answers with.
    var engine: FakeLiveEngine = FakeLiveEngine()
    /// How often the advice service hears the meeting.
    var adviceInterval: Duration = .seconds(30)
    /// The dictation pause windows.
    var pauseWindows: @MainActor @Sendable () -> [LiveSampleRange] = { [] }

    /// Every test starts with the automatic answers on.
    init() {
        defaults.set(true, forKey: autoAnswerKey)
    }

    /// The environment the session runs on.
    func environment() -> LiveHintsEnvironment {
        let routes = MeetingAnswerRoutes()
        routes.pro = pro
        routes.ownKey = nil
        routes.local = nil
        // The engine, the interval and the windows are read here, on the
        // main actor: the closures below run off it.
        let engine = self.engine
        let interval = self.adviceInterval
        let windows = self.pauseWindows
        let defaults = self.defaults
        let autoAnswerKey = self.autoAnswerKey
        let comboBox = self.combo
        let clockBox = self.clock
        let globalInput = self.globalInputEnabled
        return LiveHintsEnvironment(
            mic: mic,
            system: system,
            pauseWindows: { windows() },
            generation: { 1 },
            engine: { engine },
            language: { nil },
            promptWords: { _ in [] },
            isAutoOn: { defaults.bool(forKey: autoAnswerKey) },
            autoAnswerDefaults: defaults,
            autoAnswerKey: autoAnswerKey,
            globalInputEnabled: { globalInput.value },
            clock: { clockBox.value },
            relevantMemories: { _ in "" },
            advice: advice,
            hotkey: hotkey,
            state: state,
            routes: routes,
            combo: { comboBox.value },
            adviceInterval: interval)
    }
}
