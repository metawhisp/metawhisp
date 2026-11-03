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
        var events: [String] = []
        var toggle = 0, pttStart = 0, pttStop = 0
        var translateTap = 0, translateHold = 0
        var voiceQuestionStart = 0, voiceQuestionStop = 0
    }

    private var settings: AppSettings { .shared }

    /// What the switches were on arrival, put back on the way out.
    private var saved: (mode: String, transcribe: Bool, translate: Bool,
                        voiceQuestion: Bool, autoTranslate: Bool, holdMs: Double)!

    private var made: [HotkeyService] = []
    private var scheduler: ManualHotkeyScheduler!

    override func setUp() {
        super.setUp()
        saved = (settings.hotkeyMode, settings.transcribeHotkeyEnabled,
                 settings.translateHotkeyEnabled, settings.voiceQuestionHotkeyEnabled,
                 settings.autoTranslateHotkeyEnabled, settings.voiceQuestionHoldMs)
        scheduler = ManualHotkeyScheduler()
        // A known starting point: every action on, Toggle mode, a 0.5 s hold.
        settings.hotkeyMode = "toggle"
        settings.transcribeHotkeyEnabled = true
        settings.translateHotkeyEnabled = true
        settings.voiceQuestionHotkeyEnabled = true
        settings.autoTranslateHotkeyEnabled = true
        settings.voiceQuestionHoldMs = 500
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
        let scheduler = scheduler!
        let service = HotkeyService(schedule: scheduler.schedule, clock: { scheduler.now })
        service.register(
            onToggle: { counts.toggle += 1 },
            onPTTStart: { counts.pttStart += 1; counts.events.append("pttStart") },
            onPTTStop: { counts.pttStop += 1; counts.events.append("pttStop") },
            onTranslateToggle: { counts.translateTap += 1; counts.events.append("translateTap") },
            onTranslateLongPress: { counts.translateHold += 1 },
            onVoiceQuestionStart: { counts.voiceQuestionStart += 1 },
            onVoiceQuestionStop: { counts.voiceQuestionStop += 1 }
        )
        made.append(service)
        return (service, counts)
    }

    func testTranslateTapPrecedesPTTStartBeforeEitherCallbackRuns() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x40)
        service.handleDeviceFlags(0) // Queue the translated tap, without yielding.
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.15) // The hold fires before the tap task can run.
        XCTAssertEqual(counts.events, [], "callbacks must leave the event-monitor stack")
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.events, ["translateTap", "pttStart"])
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.events, ["translateTap", "pttStart", "pttStop"])
    }

    func testPushToTalkStartsAtExactly150Milliseconds() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10)
        scheduler.advance(to: 0.149)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 0, "PTT must not start before 0.15 s")

        scheduler.advance(to: 0.15)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 1, "PTT must start at 0.15 s")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStop, 1)
    }

    func testVoiceQuestionStartsAtExactly500Milliseconds() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10)
        scheduler.advance(to: 0.499)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStart, 0, "The question must not start before 0.5 s")

        scheduler.advance(to: 0.5)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStart, 1, "The question must start at 0.5 s")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStop, 1)
    }

    func testAutoTranslateFiresAtExactly1500Milliseconds() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x40)
        scheduler.advance(to: 1.499)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateHold, 0, "Auto-translate must not fire before 1.5 s")

        scheduler.advance(to: 1.5)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateHold, 1, "Auto-translate must fire at 1.5 s")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateTap, 0)
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

        // Keep both keys down past the longest delay (Right Option: 1.5 s).
        // Releasing first would cancel a wrongly armed timer and hide the bug.
        service.handleDeviceFlags(0x50)
        scheduler.advance(by: 1.7)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.toggle, 0)
        XCTAssertEqual(counts.voiceQuestionStart, 0)
        XCTAssertEqual(counts.translateTap, 0)
        XCTAssertEqual(counts.translateHold, 0)
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 0)
        XCTAssertEqual(counts.pttStop, 0)
        XCTAssertEqual(counts.voiceQuestionStop, 0)
    }

    /// The switches decide on the way down, and a hold already in flight
    /// completes: with both of Right ⌘'s actions flipped off mid-hold, the
    /// release must still stop the voice question — a recording cannot
    /// outlive its key.
    func testAReleaseCompletesAVoiceQuestionSpeakingWhenBothSwitchesFlipOffMidHold() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // down: hold armed for 500 ms
        scheduler.advance(by: 0.5)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStart, 1, "the hold should be speaking by now")

        settings.transcribeHotkeyEnabled = false
        settings.voiceQuestionHotkeyEnabled = false
        service.handleDeviceFlags(0) // up, with both actions now off
        await service.waitForPendingCallbacks()

        XCTAssertEqual(counts.voiceQuestionStop, 1, "the stop must fire whatever the switches now say")
        XCTAssertEqual(counts.toggle, 0, "and the off tap must not fire on the way out")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStop, 1, "a repeated release must not stop twice")
    }

    /// The hold timer re-reads its switch when it fires: a voice question
    /// switched off inside its own arming window never starts.
    func testTheHoldTimerHonoursASwitchFlippedOffInsideItsWindow() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // hold armed for 500 ms
        scheduler.advance(by: 0.03)
        await service.waitForPendingCallbacks()
        settings.voiceQuestionHotkeyEnabled = false
        scheduler.advance(by: 0.5)
        await service.waitForPendingCallbacks()

        XCTAssertEqual(counts.voiceQuestionStart, 0, "an off action never fires")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStop, 0, "this hold never started a voice question")
    }

    /// The Push-to-Talk delayed start re-reads its switch too: dictation
    /// switched off inside the 0.15 s window never opens the mic.
    func testThePushToTalkDelayedStartHonoursASwitchFlippedOffInsideItsWindow() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x10) // delayed start armed for 0.15 s
        scheduler.advance(by: 0.03)
        await service.waitForPendingCallbacks()
        settings.transcribeHotkeyEnabled = false
        scheduler.advance(by: 0.3)
        await service.waitForPendingCallbacks()

        XCTAssertEqual(counts.pttStart, 0, "an off action never fires")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStop, 0, "this hold never started a recording")
    }

    /// The Right ⌥ long-press re-reads its switch as well: auto-translate
    /// switched off inside its 1.5 s window never starts.
    func testTheRightOptionLongPressHonoursASwitchFlippedOffInsideItsWindow() async {
        let (service, counts) = makeService()

        service.handleDeviceFlags(0x40) // long-press armed for 1.5 s
        scheduler.advance(by: 0.03)
        await service.waitForPendingCallbacks()
        settings.autoTranslateHotkeyEnabled = false
        scheduler.advance(by: 1.6)
        await service.waitForPendingCallbacks()

        XCTAssertEqual(counts.translateHold, 0, "an off action never fires")
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateTap, 0)
        XCTAssertEqual(counts.pttStop, 0)
        XCTAssertEqual(counts.voiceQuestionStop, 0)
    }

    func testPushToTalkReleaseAtTwoTenthsStopsTheStartedHold() async {
        await checkPushToTalkRelease(disableAfterStart: false)
    }

    func testPushToTalkReleaseStillStopsAfterItsSwitchTurnsOff() async {
        await checkPushToTalkRelease(disableAfterStart: true)
    }

    private func checkPushToTalkRelease(disableAfterStart: Bool) async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.2)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 1, "the 150 ms delayed start must have fired")
        if disableAfterStart { settings.transcribeHotkeyEnabled = false }
        service.handleDeviceFlags(0)
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 1)
        XCTAssertEqual(counts.pttStop, 1, "only the hold that started may stop, exactly once")

        settings.transcribeHotkeyEnabled = true
        service.handleDeviceFlags(0x10)
        service.handleDeviceFlags(0)
        scheduler.advance(by: 0.2)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 1, "the next short tap must not inherit the previous start")
        XCTAssertEqual(counts.pttStop, 1, "the release must reset ownership")
    }

    func testPushToTalkTapBeforeTheDelayDoesNotStartOrStop() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.03)
        await service.waitForPendingCallbacks()
        service.handleDeviceFlags(0)
        scheduler.advance(by: 0.2)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 0)
        XCTAssertEqual(counts.pttStop, 0)
    }

    func testPushToTalkCancelledTimerCannotStartTheNextShortHold() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.1)
        await service.waitForPendingCallbacks()
        service.handleDeviceFlags(0)
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.1)
        await service.waitForPendingCallbacks()
        service.handleDeviceFlags(0)
        scheduler.advance(by: 0.2)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 0, "a canceled timer belongs only to the previous hold")
        XCTAssertEqual(counts.pttStop, 0)
    }

    func testVoiceQuestionShortTapNeverStopsAnUnstartedHold() async {
        settings.transcribeHotkeyEnabled = false
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        service.handleDeviceFlags(0)
        scheduler.advance(by: 0.5)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStart, 0)
        XCTAssertEqual(counts.voiceQuestionStop, 0)
    }

    func testRightCommandReleaseKeepsTheModeThatStartedTheHold() async {
        for mode in ["pushToTalk", "toggle"] {
            settings.hotkeyMode = mode
            let (service, counts) = makeService()
            service.handleDeviceFlags(0x10)
            scheduler.advance(by: mode == "toggle" ? 0.5 : 0.2)
            await service.waitForPendingCallbacks()
            settings.hotkeyMode = mode == "toggle" ? "pushToTalk" : "toggle"
            service.handleDeviceFlags(0)
            await service.waitForPendingCallbacks()
            XCTAssertEqual(counts.pttStart, mode == "pushToTalk" ? 1 : 0)
            XCTAssertEqual(counts.pttStop, counts.pttStart)
            XCTAssertEqual(counts.voiceQuestionStart, mode == "toggle" ? 1 : 0)
            XCTAssertEqual(counts.voiceQuestionStop, counts.voiceQuestionStart)
            XCTAssertEqual(counts.toggle, 0)
        }
    }

    func testUnregisterStopsAnActivePTTHoldExactlyOnce() async {
        await checkUnregister(mode: "pushToTalk", deliverStartFirst: true)
    }

    func testUnregisterStopsAnActiveVoiceQuestionExactlyOnce() async {
        await checkUnregister(mode: "toggle", deliverStartFirst: true)
    }

    func testUnregisterPreservesQueuedStartStopPairsBeforeReregistering() async {
        for mode in ["pushToTalk", "toggle"] {
            await checkUnregister(mode: mode, deliverStartFirst: false)
        }
    }

    private func checkUnregister(mode: String, deliverStartFirst: Bool) async {
        settings.hotkeyMode = mode
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: mode == "pushToTalk" ? 0.2 : 0.5)
        if deliverStartFirst {
            await service.waitForPendingCallbacks()
            XCTAssertEqual(counts.pttStart + counts.voiceQuestionStart, 1)
        } else {
            XCTAssertEqual(counts.pttStart + counts.voiceQuestionStart, 0)
        }
        service.unregister()
        service.unregister() // Teardown is idempotent even before callbacks drain.
        var replacementStops = 0
        if !deliverStartFirst {
            service.register(onToggle: {}, onPTTStart: {}, onPTTStop: { replacementStops += 1 },
                             onTranslateToggle: {}, onTranslateLongPress: {},
                             onVoiceQuestionStart: {}, onVoiceQuestionStop: { replacementStops += 1 })
        }
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, mode == "pushToTalk" ? 1 : 0)
        XCTAssertEqual(counts.voiceQuestionStart, mode == "toggle" ? 1 : 0)
        XCTAssertEqual(counts.pttStop, counts.pttStart)
        XCTAssertEqual(counts.voiceQuestionStop, counts.voiceQuestionStart)
        service.handleDeviceFlags(0)
        scheduler.advance(by: 2)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStop + counts.voiceQuestionStop, 1, "release after unregister owes no second stop")
        XCTAssertEqual(replacementStops, 0, "the old hold must keep its captured stop callback")
    }

    func testUnregisterCancelsThePendingPushToTalkHoldBeforeReuse() async {
        settings.hotkeyMode = "pushToTalk"
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.1)
        await service.waitForPendingCallbacks()
        service.unregister()
        service.register(onToggle: {}, onPTTStart: { counts.pttStart += 1; counts.events.append("pttStart") },
                         onPTTStop: { counts.pttStop += 1; counts.events.append("pttStop") }, onTranslateToggle: {},
                         onTranslateLongPress: {}, onVoiceQuestionStart: {}, onVoiceQuestionStop: {})
        service.handleDeviceFlags(0x10)
        scheduler.advance(by: 0.1)
        await service.waitForPendingCallbacks()
        service.handleDeviceFlags(0)
        scheduler.advance(by: 0.2)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.pttStart, 0)
        XCTAssertEqual(counts.pttStop, 0)
    }

    func testReinstallingMonitorsPreservesTheActiveHoldUntilRelease() async {
        for mode in ["pushToTalk", "toggle"] {
            settings.hotkeyMode = mode
            let (service, counts) = makeService()
            service.handleDeviceFlags(0x10)
            scheduler.advance(by: mode == "toggle" ? 0.5 : 0.2)
            await service.waitForPendingCallbacks()
            XCTAssertEqual(counts.pttStart + counts.voiceQuestionStart, 1)
            service.reinstallMonitors()
            service.handleDeviceFlags(0)
            await service.waitForPendingCallbacks()
            XCTAssertEqual(counts.pttStop, counts.pttStart)
            XCTAssertEqual(counts.voiceQuestionStop, counts.voiceQuestionStart)
        }
    }

    func testVoiceQuestionSpoiledHoldNeverStopsAnUnstartedQuestion() async {
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x10)
        service.noteForeignKeyPress()
        scheduler.advance(by: 0.5)
        await service.waitForPendingCallbacks()
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.voiceQuestionStart, 0)
        XCTAssertEqual(counts.voiceQuestionStop, 0)
    }

    func testAutoTranslateFiresOnceAndReleaseDoesNotStopAnotherAction() async {
        let (service, counts) = makeService()
        service.handleDeviceFlags(0x40)
        scheduler.advance(by: 1.7)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateHold, 1)
        settings.autoTranslateHotkeyEnabled = false
        service.handleDeviceFlags(0)
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateHold, 1, "auto-translate is a single callback, with no release stop")
        XCTAssertEqual(counts.translateTap, 0)
        XCTAssertEqual(counts.pttStop, 0)
        XCTAssertEqual(counts.voiceQuestionStop, 0)

        service.handleDeviceFlags(0x40)
        service.handleDeviceFlags(0)
        await service.waitForPendingCallbacks()
        XCTAssertEqual(counts.translateTap, 1, "the next tap must not inherit the fired hold")
    }
}
