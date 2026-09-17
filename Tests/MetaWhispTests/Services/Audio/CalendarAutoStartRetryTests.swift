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
            isRecording: false, eventInProgress: true))
    }

    func testTheRetryWaitsForTheCooldown() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: CalendarAutoStartRetry.cooldownTicks - 1,
            isRecording: false, eventInProgress: true),
            "retrying every tick would reopen the meeting a thousand times")
    }

    func testNothingIsRetriedWhileAMeetingIsRecording() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: 10_000, isRecording: true, eventInProgress: true))
    }

    func testNothingIsRetriedOnceTheEventIsOver() {
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: 1, ticksSinceLast: 10_000, isRecording: false, eventInProgress: false))
    }

    /// The ceiling. Three attempts at a meeting that never produces a sound is
    /// enough; after that the event is left alone.
    func testTheRetriesStopAtTheCeiling() {
        XCTAssertTrue(CalendarAutoStartRetry.shouldRetry(
            attempts: CalendarAutoStartRetry.maxAttempts - 1, ticksSinceLast: 10_000,
            isRecording: false, eventInProgress: true))
        XCTAssertFalse(CalendarAutoStartRetry.shouldRetry(
            attempts: CalendarAutoStartRetry.maxAttempts, ticksSinceLast: 10_000,
            isRecording: false, eventInProgress: true),
            "an event that will not record is not worth an endless queue of attempts")
    }
}
