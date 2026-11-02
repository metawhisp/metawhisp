import XCTest
@testable import MetaWhisp

/// The wiring half of the four hotkey switches: what the panel's chips do to
/// the live key handlers of `HotkeyService`.
///
/// The rules live in `HotkeyGates`, pinned pure by `HotkeyGatesTests`; these
/// drive the real service through `handleDeviceFlags` — the seam the global
/// monitors feed — with the switches flipped in `AppSettings` exactly the way
/// the panel flips them.
@MainActor
final class HotkeyServiceGatingTests: XCTestCase {

    /// What each callback did while the test ran.
    private final class Counts {
        var toggle = 0, pttStart = 0, pttStop = 0
        var translateTap = 0, translateHold = 0
        var voiceQuestionStart = 0, voiceQuestionStop = 0
    }

    private var settings: AppSettings { .shared }

    /// What the switches were on arrival, put back on the way out.
    private var saved: (mode: String, transcribe: Bool, translate: Bool,
                        voiceQuestion: Bool, autoTranslate: Bool, holdMs: Double)!

    private var made: [HotkeyService] = []

    override func setUp() {
        super.setUp()
        saved = (settings.hotkeyMode, settings.transcribeHotkeyEnabled,
                 settings.translateHotkeyEnabled, settings.voiceQuestionHotkeyEnabled,
                 settings.autoTranslateHotkeyEnabled, settings.voiceQuestionHoldMs)
        // A known starting point: every action on, Toggle mode, a hold short
        // enough that the tests can wait it out.
        settings.hotkeyMode = "toggle"
        settings.transcribeHotkeyEnabled = true
        settings.translateHotkeyEnabled = true
        settings.voiceQuestionHotkeyEnabled = true
        settings.autoTranslateHotkeyEnabled = true
        settings.voiceQuestionHoldMs = 100
    }

    override func tearDown() {
        made.forEach { $0.unregister() }
        made = []
        settings.hotkeyMode = saved.mode
        settings.transcribeHotkeyEnabled = saved.transcribe
        settings.translateHotkeyEnabled = saved.translate
        settings.voiceQuestionHotkeyEnabled = saved.voiceQuestion
        settings.autoTranslateHotkeyEnabled = saved.autoTranslate
        settings.voiceQuestionHoldMs = saved.holdMs
        super.tearDown()
    }

    /// A live service counting every callback, unregistered on the way out.
    private func makeService() -> (service: HotkeyService, counts: Counts) {
        let counts = Counts()
        let service = HotkeyService()
        service.register(
            onToggle: { counts.toggle += 1 },
            onPTTStart: { counts.pttStart += 1 },
            onPTTStop: { counts.pttStop += 1 },
            onTranslateToggle: { counts.translateTap += 1 },
            onTranslateLongPress: { counts.translateHold += 1 },
            onVoiceQuestionStart: { counts.voiceQuestionStart += 1 },
            onVoiceQuestionStop: { counts.voiceQuestionStop += 1 }
        )
        made.append(service)
        return (service, counts)
    }

    /// Both actions of a key off → the key is not the app's, tap or hold:
    /// the down is ignored, so nothing is armed and the up settles nothing.
    func testAKeyWhoseActionsAreAllOffIsIgnoredEndToEnd() async {
        settings.transcribeHotkeyEnabled = false
        settings.voiceQuestionHotkeyEnabled = false
        settings.translateHotkeyEnabled = false
        settings.autoTranslateHotkeyEnabled = false
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // Right ⌘ down
        service.handleDeviceFlags(0)    // … up
        service.handleDeviceFlags(0x40) // Right ⌥ down
        service.handleDeviceFlags(0)    // … up

        // Long enough for a wrongly armed hold to have fired.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counts.toggle, 0)
        XCTAssertEqual(counts.voiceQuestionStart, 0)
        XCTAssertEqual(counts.translateTap, 0)
        XCTAssertEqual(counts.translateHold, 0)
    }

    /// The switches decide on the way down, and a hold already in flight
    /// completes: with both of Right ⌘'s actions flipped off mid-hold, the
    /// release must still stop the voice question — a recording cannot
    /// outlive its key.
    func testAReleaseCompletesAVoiceQuestionSpeakingWhenBothSwitchesFlipOffMidHold() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // down: hold armed for 100 ms
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counts.voiceQuestionStart, 1, "the hold should be speaking by now")

        settings.transcribeHotkeyEnabled = false
        settings.voiceQuestionHotkeyEnabled = false
        service.handleDeviceFlags(0) // up, with both actions now off
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(counts.voiceQuestionStop, 1, "the stop must fire whatever the switches now say")
        XCTAssertEqual(counts.toggle, 0, "and the off tap must not fire on the way out")
    }

    /// The hold timer re-reads its switch when it fires: a voice question
    /// switched off inside its own arming window never starts.
    func testTheHoldTimerHonoursASwitchFlippedOffInsideItsWindow() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // hold armed for 100 ms
        try? await Task.sleep(for: .milliseconds(30))
        settings.voiceQuestionHotkeyEnabled = false
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(counts.voiceQuestionStart, 0, "an off action never fires")
    }

    /// The Push-to-Talk delayed start re-reads its switch too: dictation
    /// switched off inside the 0.15 s window never opens the mic.
    func testThePushToTalkDelayedStartHonoursASwitchFlippedOffInsideItsWindow() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // delayed start armed for 0.15 s
        try? await Task.sleep(for: .milliseconds(30))
        settings.transcribeHotkeyEnabled = false
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(counts.pttStart, 0, "an off action never fires")
    }

    /// The Right ⌥ long-press re-reads its switch as well: auto-translate
    /// switched off inside its 1.5 s window never starts.
    func testTheRightOptionLongPressHonoursASwitchFlippedOffInsideItsWindow() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x40) // long-press armed for 1.5 s
        try? await Task.sleep(for: .milliseconds(30))
        settings.autoTranslateHotkeyEnabled = false
        try? await Task.sleep(for: .milliseconds(1600))

        XCTAssertEqual(counts.translateHold, 0, "an off action never fires")
    }
}
