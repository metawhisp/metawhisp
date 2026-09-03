import XCTest
@testable import MetaWhisp

/// A meeting must never lose a channel silently.
///
/// 2026-09-02, founder's Mac: an 87-minute call. Twenty-four seconds in, the
/// audio device changed; the engine was torn down as designed and nobody
/// built it back. `mic=0 samples, system=83164794` — a saved transcript of
/// the other side only, with no warning at any point.
final class MicRecoveryTests: XCTestCase {

    // MARK: - Confirmation: samples produced, not time elapsed

    /// The confirmation window outlasts the content detector, so a device that
    /// binds and delivers zeros is called dead before it can be called back.
    /// The window is `confirmTicks` one-second ticks of a healthy rate.
    func testConfirmationOutlastsTheDeadStreamDetector() {
        XCTAssertGreaterThan(Double(MicRecoveryPolicy.confirmTicks), DeadMicDetector.deadAfterSeconds)
    }

    // MARK: - The timeline: the buffer follows the clock

    func testExpectedSamplesFollowTheClock() {
        XCTAssertEqual(MicRecovery.expectedSamples(elapsed: 2.5, sampleRate: 16_000), 40_000)
        XCTAssertEqual(MicRecovery.expectedSamples(elapsed: -1, sampleRate: 16_000), 0)
        XCTAssertEqual(MicRecovery.expectedSamples(elapsed: 1.0 - 0.9, sampleRate: 10), 1, "rounded, not truncated")
    }

    /// Silence is placed where the time went missing: before the buffer that
    /// came after the gap. The fill is only ever the difference to the clock,
    /// less the jitter a healthy stream is allowed — at 10 Hz that is 2.5 → 2
    /// samples — so live audio is never filled into and a gap is never counted
    /// twice.
    func testTheFillIsOnlyTheDifferenceToTheClockPastTheAllowance() {
        XCTAssertEqual(MicRecovery.fillCount(current: 100, expected: 160, sampleRate: 10, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 58)
        XCTAssertEqual(MicRecovery.fillCount(current: 160, expected: 160, sampleRate: 10, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0, "at the clock: nothing")
        XCTAssertEqual(MicRecovery.fillCount(current: 159, expected: 160, sampleRate: 10, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0, "inside the allowance: nothing")
        XCTAssertEqual(MicRecovery.fillCount(current: 200, expected: 160, sampleRate: 10, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0, "ahead of the clock: left alone")
    }

    /// Per-buffer placement must not turn routine callback jitter into
    /// clicks: a buffer a few milliseconds late is not a gap. Nothing is
    /// filled until the deficit is a tenth of a second past the allowance;
    /// then the fill brings the buffer back to the allowance's edge.
    func testAFewMillisecondsLateIsNotAGap() {
        let rate = 16_000.0
        let allowance = Int(MicRecovery.jitterAllowanceSeconds * rate)
        let trigger = allowance + Int(MicRecovery.minFillSeconds * rate)
        XCTAssertEqual(MicRecovery.fillCount(current: 160_000 - allowance - 80, expected: 160_000, sampleRate: rate, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0,
                       "5 ms late: left alone")
        XCTAssertEqual(MicRecovery.fillCount(current: 160_000 - trigger + 1, expected: 160_000, sampleRate: rate, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0,
                       "one sample short of the trigger: left alone")
        XCTAssertEqual(MicRecovery.fillCount(current: 160_000 - trigger, expected: 160_000, sampleRate: rate, allowanceSeconds: MicRecovery.jitterAllowanceSeconds),
                       trigger - allowance, "at the trigger: filled back to the allowance's edge")
    }

    /// Review round eight: "fill only if nothing arrived recently" let a
    /// buffer every 0.9 s keep a hole open forever. Round nine: filling at the
    /// end once a second put the gap after the live buffers that had arrived
    /// since. Per-buffer placement with the allowance answers both: a healthy
    /// stream's deficit sits inside the allowance and is never touched; a
    /// dripping device's grows past it and is filled before each drip.
    func testAHealthyStreamsJitterIsNeverFilledAndADripIs() {
        let allowance = Int(MicRecovery.jitterAllowanceSeconds * 16_000)
        XCTAssertEqual(MicRecovery.fillCount(current: 160_000 - allowance + 1, expected: 160_000, sampleRate: 16_000, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0,
                       "one sample inside the allowance: a healthy stream, left alone")
        XCTAssertEqual(MicRecovery.fillCount(current: 160_000 - allowance - 1, expected: 160_000, sampleRate: 16_000, allowanceSeconds: MicRecovery.jitterAllowanceSeconds), 0,
                       "one sample past it: inside the hysteresis, left alone")
        // A dripping device (1024 samples per second) after ten seconds.
        XCTAssertEqual(MicRecovery.fillCount(current: 10_240, expected: 160_000, sampleRate: 16_000, allowanceSeconds: MicRecovery.jitterAllowanceSeconds),
                       160_000 - allowance - 10_240)
    }

    // MARK: - Schedule: retry until it works

    /// "If it fails, show a banner" was the wrong sentence. On a MacBook the
    /// microphone always exists; the attempt repeats while the meeting runs.
    func testTheScheduleBacksOffAndNeverGivesUp() {
        let s = MicRecoverySchedule()
        XCTAssertEqual(s.delay(afterAttempts: 0), MicRecoverySchedule.minDelaySeconds)
        XCTAssertEqual(s.delay(afterAttempts: 3), MicRecoverySchedule.minDelaySeconds, "4 s would be under the floor")
        XCTAssertEqual(s.delay(afterAttempts: 4), MicRecoverySchedule.maxDelaySeconds)
        XCTAssertEqual(s.delay(afterAttempts: 5), MicRecoverySchedule.maxDelaySeconds)
        // The built-in mic itself has now failed a few times: keep trying,
        // slower — there is no other device to fall back to. Only attempts
        // that ACTUALLY bound the built-in count (review round eight): asking
        // for it and not getting it is not evidence against it.
        let slow = MicRecoverySchedule.builtInAttemptsBeforeSlowing
        XCTAssertEqual(s.delay(afterAttempts: 10, builtInAttempts: slow - 1), MicRecoverySchedule.maxDelaySeconds)
        XCTAssertEqual(s.delay(afterAttempts: 10, builtInAttempts: slow), MicRecoverySchedule.maxDelayOnBuiltInSeconds)
        XCTAssertEqual(s.delay(afterAttempts: 400, builtInAttempts: 400), MicRecoverySchedule.maxDelayOnBuiltInSeconds,
                       "never nil: there is no giving up")
    }

    /// The episode counts a built-in bind only when the engine says it bound one.
    func testTheEpisodeCountsRealBuiltInBindsOnly() {
        var e = MicOutageEpisode(since: SuspendingClock.now, now: 0)
        e.noteAttempt(at: 0, boundBuiltIn: false)
        e.noteAttempt(at: 10, boundBuiltIn: false)
        XCTAssertEqual(e.builtInAttempts, 0)
        e.noteAttempt(at: 20, boundBuiltIn: true)
        XCTAssertEqual(e.builtInAttempts, 1)
    }

    /// A retry never comes due before a PROMPT rebind can be confirmed: its
    /// first buffer, then `confirmTicks` full ticks of a healthy rate. A slow
    /// rebind — a Bluetooth first buffer seconds later — is protected by the
    /// policy, not the delay: `testAHealthyUnconfirmedRebindIsNotRestarted`.
    func testNoRetryComesDueBeforeAPromptRebindCanBeConfirmed() {
        let s = MicRecoverySchedule()
        for attempts in 0...10 {
            XCTAssertGreaterThanOrEqual(s.delay(afterAttempts: attempts),
                                        Double(MicRecoveryPolicy.confirmTicks + 1))
        }
    }

    func testAfterAFewMissesTheBuiltInMicrophoneIsPreferred() {
        let s = MicRecoverySchedule()
        XCTAssertFalse(s.preferBuiltIn(afterAttempts: MicRecoverySchedule.attemptsBeforeBuiltIn - 1))
        XCTAssertTrue(s.preferBuiltIn(afterAttempts: MicRecoverySchedule.attemptsBeforeBuiltIn))
    }

    // MARK: - Episode: the count survives a bind that delivered nothing

    /// The first review's P0: `engine.start()` returning was treated as
    /// success, so a device that bound fine and delivered nothing reset the
    /// count on every try and the built-in fallback was never reached. The
    /// episode counts attempts until the stream is confirmed, however each
    /// attempt ended.
    func testABindThatDeliversNothingStillCountsAsAMiss() {
        var e = MicOutageEpisode(since: SuspendingClock.now, now: 30)
        XCTAssertTrue(e.shouldAttempt(at: 30), "the first attempt is due at once")
        e.noteAttempt(at: 30)                   // bound, delivered nothing
        XCTAssertEqual(e.attempts, 1)
        XCTAssertFalse(e.shouldAttempt(at: 31))
        var t = e.nextAttemptAt
        XCTAssertTrue(e.shouldAttempt(at: t)); e.noteAttempt(at: t)
        t = e.nextAttemptAt
        XCTAssertTrue(e.shouldAttempt(at: t)); e.noteAttempt(at: t)
        XCTAssertEqual(e.attempts, 3)
        XCTAssertTrue(e.preferBuiltIn, "three misses on the default → the built-in mic is asked for")
    }
    // MARK: - The state machine, as the tick runs it

    private func tick(_ state: MicStreamState,
                      rate: Int = 0, healthy: Int = 0, low: Int = 0, window: Double = 1,
                      elapsed: Double = 60, outage: Bool = false, due: Bool = false,
                      permission: Bool = true) -> MicTickDecision {
        MicRecoveryPolicy.decide(.init(hasPermission: permission, state: state,
                                       producedSinceLastTick: rate,
                                       healthyTicks: healthy, lowRateTicks: low,
                                       secondsSinceLastTick: window,
                                       elapsed: elapsed, outageOpen: outage, attemptDue: due),
                                 sampleRate: 16_000)
    }

    /// v16 P2: a bind holding a healthy rate is confirming, not failing. The
    /// retry coming due must not tear it down — a Bluetooth first buffer
    /// slower than the retry delay made three such restarts and moved the
    /// meeting to the built-in microphone.
    func testAHealthyUnconfirmedRebindIsNotRestarted() {
        let d = tick(.delivering, rate: 16_000, healthy: 1, outage: true, due: true)
        XCTAssertFalse(d.attempt)
        XCTAssertFalse(d.close, "one healthy tick is not yet the confirmation")
    }

    /// The partner: the gate is released by an unhealthy tick, which resets
    /// the healthy count — a rebind that drips is restarted when the retry
    /// comes due, as is one still binding, as is an engine that is down.
    func testADrippingRebindIsRestartedWhenDue() {
        XCTAssertTrue(tick(.delivering, rate: 2_000, healthy: 0, outage: true, due: true).attempt)
        XCTAssertTrue(tick(.binding, outage: true, due: true).attempt)
        XCTAssertTrue(tick(.down, outage: true, due: true).attempt)
    }

    /// 2026-09-02, the original: the engine reports itself down.
    func testAnEngineThatIsDownOpensAnOutage() {
        XCTAssertEqual(tick(.down).open, "input engine down")
    }

    /// Round five, P0: the mic worked for a while, then the tap hung. Its old
    /// count is not evidence of anything now.
    func testABindThatProducedAndThenHungIsStalledNotDelivering() {
        XCTAssertEqual(tick(.stalled).open, "stream stalled")
    }

    /// Round five, P0, inside an outage: the same old count must not confirm
    /// a recovery that has not happened.
    func testAnOldCountDoesNotCloseTheOutage() {
        let d = tick(.stalled, outage: true, due: true)
        XCTAssertFalse(d.close)
        XCTAssertTrue(d.attempt)
        XCTAssertTrue(d.fill, "nothing is being produced, the buffer follows the clock")
    }

    /// Round three, P0: one buffer and a hang.
    func testOneBufferAndAHangDoesNotClose() {
        let d = tick(.delivering, outage: true, due: false)
        XCTAssertFalse(d.close)
        XCTAssertFalse(d.fill, "a stream still counted as delivering is placed by its own buffers; the host-clock fill begins with the stall")
        XCTAssertTrue(tick(.stalled, outage: true, due: false).fill, "…and the stall is filled up to the clock")
    }

    /// A healthy rate held for the whole confirmation window: confirmed.
    func testASteadyRebindCloses() {
        let d = tick(.delivering, rate: 16_000,
                     healthy: MicRecoveryPolicy.confirmTicks, outage: true, due: true)
        XCTAssertTrue(d.close)
        XCTAssertFalse(d.attempt, "a confirmed stream is not restarted")
    }

    /// The tick right after a healthy rebind, before confirmation: the stream
    /// kept up, so its residual deficit is warm-up, not a hole. Filling here
    /// would put silence between live buffers.
    func testAHealthyTickInsideAnOutageIsNotFilled() {
        let d = tick(.delivering, rate: 15_000,
                     healthy: 1, outage: true, due: false)
        XCTAssertFalse(d.fill)
        XCTAssertFalse(d.close, "one healthy tick is not yet confirmation")
    }

    /// Enough produced once, but not now: the count is stale evidence.
    func testEnoughProducedButNotProducingNowDoesNotClose() {
        let d = tick(.delivering, healthy: 0, outage: true, due: false)
        XCTAssertFalse(d.close)
        XCTAssertFalse(d.fill, "still counted as delivering: placed by its own buffers until the stall")
    }

    /// A device that drips one buffer every few seconds keeps every recency
    /// test happy — it produced "within the last second" at the right moment,
    /// its total grows past 1.5 s in a minute and a half — and delivers
    /// almost nothing. It is never confirmed, and outside an outage it is
    /// opened as degraded.
    func testADrippingDeviceIsNeverConfirmedAndIsOpenedAsDegraded() {
        let dripping = tick(.delivering, rate: 1024,
                            healthy: 0, outage: true, due: true)
        XCTAssertFalse(dripping.close)
        XCTAssertTrue(dripping.attempt)
        XCTAssertNil(tick(.delivering, rate: 1024, low: 2).open)
        XCTAssertEqual(tick(.delivering, rate: 1024,
                            low: MicRecoveryPolicy.degradedAfterTicks).open, "stream degraded")
    }

    func testTheHealthyRateIsWellUnderRealTimeAndWellOverADrip() {
        XCTAssertTrue(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 16_000, seconds: 1, sampleRate: 16_000))
        XCTAssertTrue(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 9_000, seconds: 1, sampleRate: 16_000),
                      "tick and audio clock are not aligned; a short second is still healthy")
        XCTAssertFalse(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 1_024, seconds: 1, sampleRate: 16_000))
    }

    /// v20 P2: after a skipped late tick the next tick's count covers several
    /// seconds. Measured against a one-second bar, a drip read as healthy —
    /// which reset the degraded streak and could supply a confirmation tick.
    /// The bar scales with the window; a tick that fires early keeps the
    /// full-second bar.
    func testTheRateIsMeasuredOverTheWindowItCovers() {
        XCTAssertFalse(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 10_000, seconds: 5, sampleRate: 16_000),
                       "10 000 samples over five seconds is a drip, not a healthy rate")
        XCTAssertTrue(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 10_000, seconds: 1, sampleRate: 16_000))
        XCTAssertTrue(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 45_000, seconds: 5, sampleRate: 16_000),
                      "a healthy stream over the same window still passes")
        XCTAssertFalse(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 4_000, seconds: 0.5, sampleRate: 16_000),
                       "an early tick does not lower the bar")
        XCTAssertFalse(MicRecoveryPolicy.isHealthyRate(producedSinceLastTick: 9_000, seconds: 4, sampleRate: 16_000),
                       "a first tick four seconds after the arm still measures its own window")
    }

    /// Round one, P0: a bind that delivers nothing is a miss; the attempt
    /// comes due and is made.
    func testABindThatDeliversNothingLeadsToTheNextAttempt() {
        XCTAssertTrue(tick(.binding, outage: true, due: true).attempt)
        XCTAssertFalse(tick(.binding, outage: true, due: false).attempt, "not before it is due")
    }

    /// A device that binds and emits zeros: dead, still an outage, attempts go on.
    func testADeadRebindKeepsTheOutageOpen() {
        let d = tick(.dead, outage: true, due: true)
        XCTAssertFalse(d.close)
        XCTAssertTrue(d.attempt)
    }

    /// Round four: a revoked permission opens the outage so the banner says
    /// so, and nothing is attempted.
    func testARevokedPermissionOpensButNeverAttempts() {
        XCTAssertEqual(tick(.delivering, permission: false).open, "microphone permission revoked")
        let d = tick(.down, outage: true, due: true, permission: false)
        XCTAssertFalse(d.attempt)
        XCTAssertTrue(d.fill)
    }

    /// The meeting's own start with a mic that never produced.
    func testAStartThatNeverProducesOpensAfterTheStallWindow() {
        XCTAssertNil(tick(.binding, elapsed: 2).open)
        XCTAssertEqual(tick(.binding, elapsed: 5).open, "no samples since start")
    }

    func testAHealthyStreamDecidesNothing() {
        XCTAssertEqual(tick(.delivering, rate: 16_000, healthy: 30),
                       MicTickDecision())
    }
    // MARK: - Placement by the device's sample clock

    /// A one-second IO drop inside a bind at 48 kHz: the next buffer's sample
    /// time is 49 024 frames past the origin (48 000 missing + one 1 024
    /// buffer). On the 16 kHz timeline that is 16 341 samples after the
    /// origin; with one buffer (341) already placed, the deficit is 16 000 —
    /// and the whole of it is filled: the device clock has no jitter to
    /// forgive.
    func testAnInBindGapIsFilledInFullByTheDeviceClock() {
        let expected = MicRecovery.expectedIndex(originIndex: 1000, originSampleTime: 0, sampleTime: 49_024,
                                                 inputRate: 48_000, sampleRate: 16_000)
        XCTAssertEqual(expected, 1000 + 16_341)
        XCTAssertEqual(MicRecovery.fillCount(current: 1000 + 341, expected: expected,
                                             sampleRate: 16_000, allowanceSeconds: 0), 16_000)
    }

    /// A skip too small to trigger is not filled — and not forgiven either:
    /// measured from the origin, it is carried until it either grows past
    /// the trigger or is genuinely made up by the stream.
    func testASmallSkipIsCarriedNotForgiven() {
        XCTAssertEqual(MicRecovery.fillCount(current: 10_000, expected: 10_000 + 4_000,
                                             sampleRate: 16_000, allowanceSeconds: 0), 0,
                       "0.25 s is under the 0.35 s trigger")
        XCTAssertEqual(MicRecovery.fillCount(current: 10_000, expected: 10_000 + 5_600,
                                             sampleRate: 16_000, allowanceSeconds: 0), 5_600,
                       "past the trigger, the full deficit")
    }

    /// The v15 finding: at 24 kHz a 1 024-frame buffer is 682.667 timeline
    /// samples. Rounding per buffer let the device clock outrun the converter
    /// by a third of a sample per step and punched a 350 ms hole into speech
    /// every twelve minutes. Measured from the origin, a healthy stream —
    /// with the converter carrying its fractional phase exactly as
    /// AVAudioConverter does — never fills, for ninety minutes, at every
    /// awkward rate.
    func testAHealthyStreamNeverFillsUnderTheDeviceClockAtAwkwardRates() {
        for (inputRate, frames) in [(24_000.0, 1024), (44_100.0, 1024), (48_000.0, 512), (96_000.0, 1024), (48_000.0, 1024)] {
            let originIndex = 1234
            let t0 = SuspendingClock.now
            var p = MicRecovery.DevicePlacement(originIndex: originIndex, originSampleTime: 100_000, originCapturedAt: t0)
            var placed = originIndex
            var sampleTime: Int64 = 100_000          // the origin's sample time
            var phase = 0.0
            var fills = 0
            // The origin buffer itself is appended after the origin is set.
            let originWant = Double(frames) * 16_000 / inputRate
            placed += Int(originWant.rounded(.down)); phase = originWant - originWant.rounded(.down)
            let buffers = Int(90 * 60 * inputRate / Double(frames))
            for k in 1...buffers {
                sampleTime += Int64(frames)
                // The converter emits floor(want + carried phase) per buffer.
                let want = Double(frames) * 16_000 / inputRate + phase
                let emitted = Int(want.rounded(.down)); phase = want - Double(emitted)
                let expected = p.expected(sampleTime: sampleTime, capturedAt: t0 + .seconds(Double(k * frames) / inputRate),
                                          current: placed, inputRate: inputRate, sampleRate: 16_000)!
                fills += MicRecovery.fillCount(current: placed, expected: expected,
                                               sampleRate: 16_000, allowanceSeconds: 0)
                placed += emitted
            }
            XCTAssertEqual(fills, 0, "\(inputRate) Hz / \(frames) frames: a healthy stream must never be filled")
            XCTAssertEqual(p.jumpsBounded, 0, "\(inputRate) Hz: the host bound never engages on a healthy stream")
            let end = originIndex + Int((Double((buffers + 1) * frames) * 16_000 / inputRate).rounded())
            XCTAssertLessThanOrEqual(abs(placed - end), 2,
                                     "\(inputRate) Hz: the timeline stays within two samples of the device clock over 90 minutes")
        }
    }

    // MARK: - The host clock bounds the device clock

    /// v16 P2: a sample time that jumps hours ahead inside a bind is bounded
    /// by the host clock — one second later by the host means about 1.25 s
    /// of silence, not hours of zeros allocated on the main thread. v18: the
    /// bind re-originates there, so the bound is applied once and the next
    /// buffer is placed by the device clock again; a straggler from before
    /// the origin is left to the host clock.
    func testADeviceClockJumpIsBoundedOnceAndTheBindReOriginates() {
        let t0 = SuspendingClock.now
        var p = MicRecovery.DevicePlacement(originIndex: 10_000, originSampleTime: 0, originCapturedAt: t0)
        let jumped = p.expected(sampleTime: 8 * 3600 * 48_000, capturedAt: t0 + .seconds(1), current: 10_000 + 341,
                                inputRate: 48_000, sampleRate: 16_000)
        XCTAssertEqual(jumped, 10_000 + 16_000 + 4_000 + 3, "the allowance plus one second of drift budget")
        XCTAssertEqual(p.jumpsBounded, 1)
        let next = p.expected(sampleTime: 8 * 3600 * 48_000 + 1024, capturedAt: t0 + .seconds(1) + .milliseconds(21),
                              current: jumped! + 341, inputRate: 48_000, sampleRate: 16_000)
        XCTAssertEqual(next, jumped! + 341, "placed by the device clock from the new origin")
        XCTAssertEqual(p.jumpsBounded, 1, "bounded once, not on every buffer")
        XCTAssertNil(p.expected(sampleTime: 5, capturedAt: t0 + .seconds(2), current: 0, inputRate: 48_000, sampleRate: 16_000),
                     "a straggler from before the origin is the host clock's")
    }

    /// v19 P2: a jump bounded while the margin is still under the fill
    /// trigger fills nothing — so the bind must re-originate where the buffer
    /// LANDS, not at the bound, or every later buffer carries a phantom
    /// deficit that the first small skip fills as a hole inside speech.
    func testAJumpUnderTheFillTriggerReOriginatesWhereTheBufferLands() {
        let t0 = SuspendingClock.now
        var p = MicRecovery.DevicePlacement(originIndex: 0, originSampleTime: 0, originCapturedAt: t0)
        let current = 60 * 16_000                             // on the clock after a minute
        let landing = p.expected(sampleTime: 8 * 3600 * 48_000, capturedAt: t0 + .seconds(60), current: current,
                                 inputRate: 48_000, sampleRate: 16_000)
        XCTAssertEqual(landing, current, "the margin at one minute (0.262 s) is under the trigger: nothing filled, origin here")
        XCTAssertEqual(p.jumpsBounded, 1)
        let next = p.expected(sampleTime: 8 * 3600 * 48_000 + 1024, capturedAt: t0 + .seconds(60) + .milliseconds(21),
                              current: current + 341, inputRate: 48_000, sampleRate: 16_000)
        XCTAssertEqual(next, current + 341, "no phantom deficit is carried")
    }

    // MARK: - A late tick judges nothing

    /// v19 P2: a tick the main thread held for seconds sees a healthy stream
    /// as stalled (`lastProducedAt` advances on the main actor), and a restart
    /// on that would discard the queued real audio. It judges nothing.
    func testALateTickDoesNotJudge() {
        XCTAssertTrue(MicRecoveryPolicy.skipsJudgement(sinceLastTick: 6, consecutiveLate: 0))
        XCTAssertTrue(MicRecoveryPolicy.skipsJudgement(sinceLastTick: 6, consecutiveLate: 1))
        XCTAssertFalse(MicRecoveryPolicy.skipsJudgement(sinceLastTick: 1.1, consecutiveLate: 0), "on time")
        XCTAssertFalse(MicRecoveryPolicy.skipsJudgement(sinceLastTick: nil, consecutiveLate: 0), "the first tick")
    }

    /// The ceiling: the third consecutive late tick judges anyway.
    func testTheThirdLateTickJudgesAnyway() {
        XCTAssertFalse(MicRecoveryPolicy.skipsJudgement(sinceLastTick: 6, consecutiveLate: MicRecoveryPolicy.lateTicksTolerated))
    }

    /// v17 P2: a device clock 100 ppm fast has run 1.08 s ahead of the host
    /// after three hours. A fixed margin would have called a real one-second
    /// gap a 0.17 s shortfall and left it unfilled; the margin grows with the
    /// bind's age by the drift budget, so the gap is filled in full.
    func testDriftIsNotPunishedWhenARealGapArrives() {
        let t0 = SuspendingClock.now, rate = 48_000.0, hours3 = 3 * 3600.0
        var p = MicRecovery.DevicePlacement(originIndex: 0, originSampleTime: 0, originCapturedAt: t0)
        let deviceAt3h = Int64(hours3 * rate * 1.0001)
        let before = p.expected(sampleTime: deviceAt3h, capturedAt: t0 + .seconds(hours3), current: 0, inputRate: rate, sampleRate: 16_000)
        XCTAssertEqual(p.jumpsBounded, 0, "1.08 s of drift is within the budget")
        let after = p.expected(sampleTime: deviceAt3h + Int64(rate), capturedAt: t0 + .seconds(hours3 + 1),
                               current: before!, inputRate: rate, sampleRate: 16_000)
        XCTAssertEqual(after! - before!, 16_000, "the whole second is filled")
        XCTAssertEqual(p.jumpsBounded, 0)
    }

    /// v18 P2: with the bound in the path, a healthy 90-minute stream is
    /// still never filled — and a jump of hours in the middle is filled
    /// exactly once, bounded, with the stream quiet for the 45 minutes after.
    func testAJumpMidRunIsFilledOnceAndTheStreamIsQuietAfter() {
        let inputRate = 48_000.0, frames = 1024
        let t0 = SuspendingClock.now
        var p = MicRecovery.DevicePlacement(originIndex: 0, originSampleTime: 0, originCapturedAt: t0)
        var placed = 341, sampleTime: Int64 = 0, phase = 341.0 / 3 - 113, fills = 0, fillEvents = 0
        let buffers = Int(90 * 60 * inputRate / Double(frames))
        for k in 1...buffers {
            sampleTime += Int64(frames)
            if k == buffers / 2 { sampleTime += 8 * 3600 * Int64(inputRate) }
            let want = Double(frames) * 16_000 / inputRate + phase
            let emitted = Int(want.rounded(.down)); phase = want - Double(emitted)
            let capturedAt = t0 + .seconds(Double(k * frames) / inputRate)
            let expected = p.expected(sampleTime: sampleTime, capturedAt: capturedAt, current: placed,
                                      inputRate: inputRate, sampleRate: 16_000)!
            let fill = MicRecovery.fillCount(current: placed, expected: expected, sampleRate: 16_000, allowanceSeconds: 0)
            if fill > 0 { fillEvents += 1; fills += fill; placed += fill }
            placed += emitted
        }
        XCTAssertEqual(p.jumpsBounded, 1)
        XCTAssertEqual(fillEvents, 1, "the jump is the only fill")
        XCTAssertLessThanOrEqual(fills, Int(16_000 * (0.25 + 45 * 60 * MicRecovery.driftBudgetPerSecond)) + 1,
                                 "…and it is bounded by the margin at 45 minutes of bind age")
    }

    // MARK: - Exact zeros after audio: reported, not restarted

    /// v16 P2: an external input that goes to exact zeros after audio is not
    /// restarted (a headset's hardware mute is the same zeros) — the longest
    /// run is kept for the report, the run still open at stop included.
    /// Zeros before any audio are the never-produced case, not a run.
    func testTheSilentRunCountsOnlyAfterAudioAndKeepsTheLongest() {
        var z = MicRecovery.ZeroRunTracker()
        z.note(samples: 16_000 * 30, silent: true)
        XCTAssertEqual(z.longest, 0, "zeros before any audio are not a run")
        z.note(samples: 16_000, silent: false)
        z.note(samples: 16_000 * 600, silent: true)
        z.note(samples: 16_000, silent: false)
        z.note(samples: 16_000 * 120, silent: true)
        XCTAssertEqual(z.longest, 16_000 * 600, "the closed ten-minute run outranks the open two-minute one")
        z.note(samples: 16_000 * 600, silent: true)
        XCTAssertEqual(z.longest, 16_000 * 720, "the open run counts once it is the longest")
    }
}
