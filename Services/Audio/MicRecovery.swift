import Foundation

/// The rules for bringing a meeting's microphone back, kept pure.
///
/// 2026-09-02: a device change 24 seconds into an 87-minute call tore the
/// input engine down, nothing rebuilt it, and the saved transcript carried the
/// other side only — `mic=0 samples` — with no warning at any point, because
/// the "mic unavailable" banner is decided once, at start. A meeting must never
/// lose a channel silently.
///
/// Three review rounds each found the same class of defect in the previous
/// design: what the raw buffer held during an outage did not match the
/// bookkeeping that later inserted silence for it. This version removes the
/// class instead of patching it: **the mic buffer keeps the meeting's timeline
/// by construction.** While the stream delivers, the tap fills it; while the
/// stream is down, the once-a-second tick fills it with silence up to the
/// clock. Nothing is inserted at stop, no index is remembered, and whatever a
/// dead attempt appended already occupies exactly the time it took.
extension Duration {
    /// Seconds as a Double. Recency, the timeline and scheduling run on
    /// `SuspendingClock`: a wall clock that moves backwards (NTP) made every
    /// age negative and a stopped stream "delivering" until real time caught
    /// up (review round six); a clock that runs through sleep made a night
    /// asleep into hours of "missing microphone" to fill (round seven). The
    /// system channel records nothing during sleep either, so a clock that
    /// pauses with the machine is the one both channels agree on.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

enum MicRecovery {

    /// The samples the buffer should hold `elapsed` seconds into the meeting.
    static func expectedSamples(elapsed: TimeInterval, sampleRate: Double) -> Int {
        Int((max(0, elapsed) * sampleRate).rounded())
    }

    /// Jitter a healthy stream is allowed against the clock before the fill
    /// touches it: the tick and the audio clock are not aligned, and buffers
    /// arrive in bursts. Wider than one burst, narrower than the deficit a
    /// dripping device builds in a single tick.
    static let jitterAllowanceSeconds: Double = 0.25
    /// Hysteresis on top of the allowance. Per-buffer placement would
    /// otherwise turn every late-arriving buffer (a few milliseconds of
    /// callback jitter is routine) into a few-millisecond fill in front of it
    /// — clicks inside speech, and a timeline creeping ahead of the truth by
    /// the sum of the late arrivals. Nothing is filled until the deficit has
    /// grown a tenth of a second past the allowance; then it is filled back
    /// to the allowance's edge.
    static let minFillSeconds: Double = 0.1

    /// `allowanceSeconds` is the jitter forgiven at the end of the fill. It
    /// is the host clock's, not the device's: a buffer placed by the device's
    /// sample clock has no jitter to forgive, and forgiving it anyway lost a
    /// quarter of a second at every in-bind gap, cumulatively (independent
    /// review, v14). The trigger stays: one starved cycle is not a gap.
    static func fillCount(current: Int, expected: Int, sampleRate: Double,
                          allowanceSeconds: Double) -> Int {
        let allowance = Int(max(0, allowanceSeconds) * sampleRate)
        let trigger = Int(jitterAllowanceSeconds * sampleRate) + Int(minFillSeconds * sampleRate)
        let deficit = expected - current
        return deficit >= trigger ? deficit - allowance : 0
    }

    /// Where a buffer belongs on the timeline by the DEVICE's sample clock,
    /// measured from the bind's ORIGIN — the index and sample time of the
    /// bind's first buffer — never from the previous buffer. Per-buffer
    /// rounding compounded: at 24 kHz a 1024-frame buffer is 682.667 timeline
    /// samples, rounded up to 683 on every step the clock outran the
    /// converter by a third of a sample per buffer, and every twelve minutes
    /// the manufactured deficit was filled as a 350 ms hole inside a word
    /// (independent review, v15). From the origin the error is bounded at
    /// half a sample for the life of the bind, and a skip too small to fill
    /// is carried exactly.
    static func expectedIndex(originIndex: Int, originSampleTime: Int64, sampleTime: Int64,
                              inputRate: Double, sampleRate: Double) -> Int {
        let elapsed = Double(sampleTime - originSampleTime) * sampleRate / inputRate
        return originIndex + Int(elapsed.rounded())
    }

    /// How far a device clock may legitimately run ahead of the host per
    /// second of a bind: 200 ppm is twice the ~100 ppm a USB or Bluetooth
    /// device's crystal drifts by (the file's own figure).
    static let driftBudgetPerSecond: Double = 200e-6

    /// Where each buffer of a bind belongs, by the DEVICE's sample clock,
    /// measured from the bind's ORIGIN (`expectedIndex`) — and bounded by the
    /// HOST clock over the SAME interval. A sample time that jumps ahead
    /// inside a bind — an aggregate device resyncing, a driver hiccup — would
    /// otherwise be filled in full, and a jump of hours is gigabytes of zeros
    /// allocated on the main thread (independent review, v16). The margin
    /// grows with the bind's age by the drift budget, so a device clock that
    /// has genuinely run ahead over hours is never punished as a shortfall
    /// when a real gap arrives (v17). A jump is bounded ONCE: the bind
    /// re-originates at the bounded index, so the bound goes inactive and the
    /// margin restarts — a bound that stayed active would have manufactured a
    /// 0.35 s hole every 29 minutes as its margin grew (v18). Measuring both
    /// clocks from the origin also keeps the origin's own offset to the host
    /// out of the comparison. Pure; the service holds one per bind.
    struct DevicePlacement: Equatable {
        private(set) var originIndex: Int
        private(set) var originSampleTime: Int64
        private(set) var originCapturedAt: SuspendingClock.Instant
        private(set) var jumpsBounded = 0

        init(originIndex: Int, originSampleTime: Int64, originCapturedAt: SuspendingClock.Instant) {
            self.originIndex = originIndex
            self.originSampleTime = originSampleTime
            self.originCapturedAt = originCapturedAt
        }

        /// The index this buffer begins at. `nil` for a buffer whose sample
        /// time is behind the origin — a straggler — which the host clock
        /// places instead.
        /// `current` is where the buffer would land with nothing filled —
        /// the timeline's length.
        mutating func expected(sampleTime: Int64, capturedAt: SuspendingClock.Instant, current: Int,
                               inputRate: Double, sampleRate: Double) -> Int? {
            guard sampleTime >= originSampleTime else { return nil }
            let byDevice = MicRecovery.expectedIndex(originIndex: originIndex, originSampleTime: originSampleTime,
                                                     sampleTime: sampleTime, inputRate: inputRate, sampleRate: sampleRate)
            let hostElapsed = max(0, (capturedAt - originCapturedAt).seconds)
            let byHost = originIndex + MicRecovery.expectedSamples(elapsed: hostElapsed, sampleRate: sampleRate)
            let margin = MicRecovery.jitterAllowanceSeconds + hostElapsed * MicRecovery.driftBudgetPerSecond
            let bound = byHost + Int((margin * sampleRate).rounded())
            guard byDevice > bound else { return byDevice }
            // A jump. Bounded — and the bind re-originates where this buffer
            // actually LANDS: at `bound` when the deficit is filled, at
            // `current` when it is under the trigger and left alone. An
            // origin recorded at `bound` over a buffer that landed before it
            // carried a phantom deficit of the whole margin, filled as a hole
            // by the first small skip (independent review, v19).
            let filled = MicRecovery.fillCount(current: current, expected: bound,
                                               sampleRate: sampleRate, allowanceSeconds: 0) > 0
            let landing = filled ? bound : current
            originIndex = landing
            originSampleTime = sampleTime
            originCapturedAt = capturedAt
            jumpsBounded += 1
            return landing
        }
    }

    /// The longest run of exact zeros a tap delivered AFTER it had delivered
    /// audio. Not an outage and not restarted — a headset's hardware mute is
    /// the same zeros — but reported at the end when it is long enough, so a
    /// transcript with only the other side for fifty minutes does not read
    /// as complete (independent review, v16). Pure; the service holds one per
    /// recording.
    struct ZeroRunTracker: Equatable {
        private(set) var current = 0
        private(set) var longestClosed = 0
        private(set) var sawAudio = false
        /// The longest run so far — the open one included: a mic still at
        /// zeros when the meeting ends has lost that stretch too.
        var longest: Int { max(current, longestClosed) }

        mutating func note(samples: Int, silent: Bool) {
            if silent {
                if sawAudio { current += samples }
            } else {
                sawAudio = true
                longestClosed = max(longestClosed, current)
                current = 0
            }
        }
    }
}

/// What the input stream is doing, as the engine reports it — and "doing"
/// means NOW. A bind that produced for a while and then stopped is stalled,
/// not delivering: the cumulative count it built up earlier proves nothing
/// about the present (review round five).
enum MicStreamState: Equatable {
    /// No engine, or the engine is not recording.
    case down
    /// Bound, nothing produced by this bind yet.
    case binding
    /// This bind produced samples within the stall window.
    case delivering
    /// This bind produced before, and nothing for the whole stall window.
    case stalled
    /// This bind produces buffers that have been bit-exact zero for the
    /// detector's whole window and has never carried audio — a device that
    /// bound and is dead. A stream that HAD audio and went quiet is not this:
    /// headsets with silence suppression emit zeros between phrases, and
    /// restarting a healthy headset because its wearer is listening would
    /// end with them silently moved to the built-in mic.
    case dead
}

/// What the once-a-second tick sees, and what it decides. Pure, so every
/// scenario a review round found can be a test that runs the state machine
/// rather than a helper around it.
struct MicTickInput: Equatable {
    var hasPermission: Bool
    var state: MicStreamState
    /// Samples produced since the previous tick — the RATE, which is what
    /// "delivering" has to mean. A device that drips one buffer every few
    /// seconds keeps every recency test happy and delivers almost nothing.
    var producedSinceLastTick: Int
    /// Consecutive ticks so far in which the rate was healthy.
    var healthyTicks: Int
    /// Consecutive ticks so far in which the rate was too low while bound.
    var lowRateTicks: Int
    /// The window `producedSinceLastTick` covers, in seconds.
    var secondsSinceLastTick: Double = 1
    /// Since the meeting started.
    var elapsed: Double
    var outageOpen: Bool
    var attemptDue: Bool
}

struct MicTickDecision: Equatable {
    /// Open an outage for this reason.
    var open: String?
    /// Fill the buffer with silence up to the clock.
    var fill = false
    /// Make a recovery attempt.
    var attempt = false
    /// The rebound stream is confirmed; close the outage.
    var close = false
}

enum MicRecoveryPolicy {

    /// No production for this long from a bind that produced before is a
    /// stall: a live tap delivers tens of buffers a second.
    static let stalledAfterSeconds: Double = 5
    /// A healthy tick produces at least this much of the time it covers.
    /// Well under one — the tick and the audio clock are not aligned — and
    /// well over what a dripping device manages.
    static let healthyRateFraction: Double = 0.5
    /// Consecutive healthy ticks that confirm a rebound stream — a RATE held
    /// for two ticks, not a count that could have been built long ago. Longer
    /// than the dead-stream detector's window, so a device that binds and
    /// delivers zeros is called dead before it can be called back.
    static let confirmTicks = 2
    /// Consecutive low-rate ticks that count a bound stream as degraded — an
    /// outage in everything but the stall timer.
    static let degradedAfterTicks = 3

    /// A tick arriving this long after the previous one was held by the main
    /// thread, not by the clock. `lastProducedAt` advances only on the main
    /// actor, so such a tick can see a healthy stream as stalled — and a
    /// restart on that judgement retires the bind and discards every queued
    /// buffer of real audio (independent review, v19). A late tick judges
    /// nothing; the latches wait for the next on-time tick.
    static let lateTickSeconds: Double = 3
    /// The ceiling: the third consecutive late tick judges anyway — a main
    /// thread that never recovers must not mute recovery for the meeting.
    static let lateTicksTolerated = 2

    static func skipsJudgement(sinceLastTick: Double?, consecutiveLate: Int) -> Bool {
        guard let since = sinceLastTick, since > lateTickSeconds else { return false }
        return consecutiveLate < lateTicksTolerated
    }

    /// `seconds` is the window this count actually covers — the time since
    /// the last tick that JUDGED, not since the last tick that fired. A
    /// skipped late tick used to leave the next one measuring several
    /// seconds' worth of samples against a one-second bar, which read a drip
    /// as healthy (independent review, v20). Never less than one second: a
    /// tick that fires early must not lower the bar.
    static func isHealthyRate(producedSinceLastTick: Int, seconds: Double, sampleRate: Double) -> Bool {
        Double(producedSinceLastTick) >= healthyRateFraction * sampleRate * max(1, seconds)
    }

    static func decide(_ i: MicTickInput, sampleRate: Double) -> MicTickDecision {
        var d = MicTickDecision()

        if i.outageOpen {
            // The buffer follows the clock on every tick the stream did NOT
            // keep up — a drip, a blocked bind, a stopped stream. A tick that
            // produced a healthy rate is keeping up: its residual deficit is
            // warm-up and jitter, and filling it would put silence between
            // live buffers. Whether something arrived "recently" is not the
            // question (a buffer every 0.9 s is recent and is not keeping up).
            // A stream still counted as delivering is placed by its own
            // buffers, each filling the gap before itself; the host-clock fill
            // begins with the stall (the recorder used to hold this rule).
            d.fill = i.state != .delivering
                && !isHealthyRate(producedSinceLastTick: i.producedSinceLastTick,
                                  seconds: i.secondsSinceLastTick, sampleRate: sampleRate)
            guard i.hasPermission else { return d }
            // Confirmed = this bind has held a healthy RATE for the whole
            // confirmation window. A bind that produced 1.5 s long ago and
            // hung has no rate now; one buffer and a hang never had one; a
            // device dripping a buffer every few seconds never reaches it.
            if i.state == .delivering, i.healthyTicks >= confirmTicks {
                d.close = true
                return d
            }
            // A bind holding a healthy rate is confirming, not failing:
            // restarting it because the retry came due tore down a working
            // link — a Bluetooth first buffer slower than the retry delay
            // made three such restarts and moved the meeting to the built-in
            // microphone (independent review, v16). Released by the close
            // above, or by the next unhealthy tick, which resets the count.
            d.attempt = i.attemptDue && !(i.state == .delivering && i.healthyTicks >= 1)
            return d
        }

        guard i.hasPermission else { d.open = "microphone permission revoked"; return d }
        switch i.state {
        case .down:       d.open = "input engine down"
        case .dead:       d.open = "digital silence"
        case .stalled:    d.open = "stream stalled"
        case .binding:
            // Outside an outage this can only be the meeting's own start:
            // rebinds happen inside one.
            if i.elapsed >= stalledAfterSeconds { d.open = "no samples since start" }
        case .delivering:
            // Producing, but too little for too long: a device that drips is
            // an outage the stall timer would never see.
            if i.lowRateTicks >= degradedAfterTicks { d.open = "stream degraded" }
        }
        return d
    }
}

/// How often to try again, and when to stop trusting the default device.
/// There is no "give up": the schedule caps the delay and keeps going for as
/// long as the meeting does.
struct MicRecoverySchedule {

    /// Never shorter than the confirmation window plus the time a slow
    /// device needs to deliver its first buffer (a Bluetooth headset can take
    /// two to three seconds to bring its link up): a healthy rebind must
    /// have had the chance to be confirmed before the next attempt is due, or
    /// the tick restarts an engine that had just recovered — three times, and
    /// then moves the meeting to the built-in mic (independent review).
    static let minDelaySeconds: TimeInterval = 5
    static let maxDelaySeconds: TimeInterval = 6
    /// Once the built-in microphone itself has failed a few times there is
    /// no other device to fall back to: keep trying — a cable can be replugged,
    /// input volume can be raised — but at a pace that is not a rebind every
    /// five seconds for the rest of the meeting.
    static let maxDelayOnBuiltInSeconds: TimeInterval = 30
    static let builtInAttemptsBeforeSlowing = 3
    /// The default input after a change can itself be the broken thing (the
    /// 24 kHz aggregate that followed the 2026-09-02 change bound fine and
    /// delivered nothing). After this many misses the built-in microphone is
    /// asked for by name — it is always there.
    static let attemptsBeforeBuiltIn = 3

    /// `builtInAttempts` counts attempts that ACTUALLY bound the built-in
    /// microphone, as reported by the engine after the bind — an attempt that
    /// asked for it and did not get it is not evidence against it.
    func delay(afterAttempts attempts: Int, builtInAttempts: Int = 0) -> TimeInterval {
        let cap = builtInAttempts >= Self.builtInAttemptsBeforeSlowing
            ? Self.maxDelayOnBuiltInSeconds : Self.maxDelaySeconds
        return min(cap, max(Self.minDelaySeconds, 0.5 * pow(2, Double(max(0, attempts)))))
    }

    func preferBuiltIn(afterAttempts attempts: Int) -> Bool {
        attempts >= Self.attemptsBeforeBuiltIn
    }
}

/// One outage, from the moment the mic went down until the rebound stream is
/// confirmed. The attempt count lives here and only here, so a bind that
/// "succeeded" and then delivered nothing is counted as the miss it was.
struct MicOutageEpisode {

    /// When it went down, on the monotonic clock.
    let since: SuspendingClock.Instant
    private(set) var attempts = 0
    /// Attempts that actually bound the built-in microphone.
    private(set) var builtInAttempts = 0
    private(set) var nextAttemptAt: TimeInterval
    private let schedule: MicRecoverySchedule

    init(since: SuspendingClock.Instant, now: TimeInterval,
         schedule: MicRecoverySchedule = MicRecoverySchedule()) {
        self.since = since
        self.schedule = schedule
        self.nextAttemptAt = now   // the first attempt is due at once
    }

    func shouldAttempt(at now: TimeInterval) -> Bool { now >= nextAttemptAt }

    /// Which device the next attempt asks for.
    var preferBuiltIn: Bool { schedule.preferBuiltIn(afterAttempts: attempts) }

    /// An attempt was made. Whether it threw or bound-and-delivered-nothing is
    /// the same to the schedule: if the stream is not confirmed by the next
    /// due time, the next attempt is made.
    mutating func noteAttempt(at now: TimeInterval, boundBuiltIn: Bool = false) {
        attempts += 1
        if boundBuiltIn { builtInAttempts += 1 }
        nextAttemptAt = now + schedule.delay(afterAttempts: attempts, builtInAttempts: builtInAttempts)
    }
}
