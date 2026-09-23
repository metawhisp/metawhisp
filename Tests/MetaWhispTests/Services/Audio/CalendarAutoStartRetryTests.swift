import XCTest
@testable import MetaWhisp

/// A calendar event that fired into an empty room may try again.
///
/// 2026-09-17 08:30: the event fired, ScreenCaptureKit had no displays (lid
/// shut), the mic produced nothing, and the meeting auto-stopped on silence at
/// 08:33 with `mic=0 samples, system=0 samples`. The event had spent its only
/// trigger — when the owner actually joined, nothing started.
///
/// Every gate needs a release: the retry is bounded by a ceiling and spaced by
/// a cooldown, so a meeting nobody is holding is not re-opened every second
/// for an hour.
final class CalendarAutoStartRetryTests: XCTestCase {

    func testAStillRunningEventIsRetriedAfterTheCooldown() {
        XCTAssertTrue(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: CalendarAutoStartRetry.cooldownTicks,
            isRecording: false, eventInProgress: true, declined: false))
    }

    func testTheRetryWaitsForTheCooldown() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: CalendarAutoStartRetry.cooldownTicks - 1,
            isRecording: false, eventInProgress: true, declined: false),
            "retrying every tick would reopen the meeting a thousand times")
    }

    func testNothingIsRetriedWhileAMeetingIsRecording() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: 10_000, isRecording: true, eventInProgress: true, declined: false))
    }

    func testNothingIsRetriedOnceTheEventIsOver() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: 10_000, isRecording: false, eventInProgress: false, declined: false))
    }

    /// The ceiling. Three attempts at a meeting that never produces a sound is
    /// enough; after that the event is left alone.
    func testTheRetriesStopAtTheCeiling() {
        XCTAssertTrue(CalendarAutoStartRetry.shouldRetry(
            attempts: CalendarAutoStartRetry.maxAttempts - 1, ticksSinceLast: 10_000,
            isRecording: false, eventInProgress: true, declined: false))
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: CalendarAutoStartRetry.maxAttempts, ticksSinceLast: 10_000,
            isRecording: false, eventInProgress: true, declined: false),
            "an event that will not record is not worth an endless queue of attempts")
    }
}

/// A retry must never argue with the person.
///
/// Shipped in 1.3.34, the retry had no idea the user could say no. The owner's
/// log, 2026-09-22: a calendar event auto-started at 18:30, the
/// owner stopped it at 18:31:02, it started itself again at 18:31:57, they
/// stopped it at 18:32:23, and it started again at 18:33:10. Three times, while
/// they were not on a call at all.
///
/// The same day at 16:17:30.042 a meeting was stopped and the retry fired at
/// 16:17:30.140 — 98 milliseconds later — because the cooldown had been
/// counting ticks throughout the recording.
final class CalendarRetryRespectsARefusalTests: XCTestCase {

    func testAnEventTheUserTurnedOffIsNeverRetried() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: 10_000, isRecording: false,
            eventInProgress: true, declined: true),
            "the person stopped it by hand — that is the end of the conversation")
    }

    /// The case the retry exists for survives: a meeting that started into an
    /// empty room and auto-stopped on silence is not a refusal.
    func testAnAutomaticFailureIsStillRetried() {
        XCTAssertTrue(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: CalendarAutoStartRetry.cooldownTicks,
            isRecording: false, eventInProgress: true, declined: false))
    }
}

/// Which stops count as "the person said no".
final class StopReasonIsARefusalTests: XCTestCase {

    func testAHandOnTheStopButtonIsARefusal() {
        XCTAssertTrue(CalendarAutoStartRetry.isRefusal(stopReason: "user-toggle"))
        XCTAssertTrue(CalendarAutoStartRetry.isRefusal(stopReason: "dictation-end-card-tap"))
        XCTAssertTrue(CalendarAutoStartRetry.isRefusal(stopReason: "calendar-end-overrun-card-tap:E1"))
    }

    /// A recorder that gave up on its own is exactly the case the retry is for.
    func testTheAppGivingUpOnItsOwnIsNotARefusal() {
        XCTAssertFalse(CalendarAutoStartRetry.isRefusal(stopReason: "recorder-auto-stop:silenceTimeout"))
        XCTAssertFalse(CalendarAutoStartRetry.isRefusal(stopReason: "calendar-end-grace:E1"))
        XCTAssertFalse(CalendarAutoStartRetry.isRefusal(stopReason: "calendar-end-hard-stop:E1"))
        XCTAssertFalse(CalendarAutoStartRetry.isRefusal(stopReason: "back-to-back-eventID:E2"))
    }
}
