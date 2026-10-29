import XCTest
@testable import MetaWhisp

/// The utterances of one stream, and the requests that carry their text.
///
/// The rules under test are the ones that decide when a question is finished:
/// silence closes it, the text may close it earlier, and the words of the
/// question must survive even when the candidate budget ran out before them.
/// The transcriber is faked, so every case here is a timing the test owns.
@MainActor
final class UtteranceTrackerTests: XCTestCase {

    // MARK: - The helpers

    /// Feeds the samples the way the recorder hands them over.
    private func feed(_ tracker: UtteranceTracker, _ samples: [Float], chunk: Int = 800) async {
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            await tracker.append(Array(samples[index ..< end]))
            index = end
        }
    }

    /// Waits until the tracker has closed `count` utterances.
    private func waitForUtterances(_ count: Int,
                                   in tracker: UtteranceTracker,
                                   timeout: Double = 8) async -> [UtteranceTracker.ClosedUtterance] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let closed = await tracker.closedUtterances
            if closed.count >= count { return closed }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return await tracker.closedUtterances
    }

    /// Waits until the tracker has taken in `count` request results.
    private func waitForSettledRequests(_ count: Int,
                                         in tracker: UtteranceTracker,
                                         timeout: Double = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await tracker.settledRequests >= count { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// A tracker over a scripted call.
    private func makeTracker(_ segments: [LiveCallFixture.Segment],
                             speaker: UtteranceTracker.Speaker = .them,
                             responder: FakeLiveTranscriber.Responder? = nil)
        -> (tracker: UtteranceTracker, transcriber: FakeLiveTranscriber, audio: [Float]) {
        let audio = LiveCallFixture.audio(segments)
        let transcriber = FakeLiveTranscriber(responder: responder)
        let tracker = UtteranceTracker(speaker: speaker,
                                      transcriber: transcriber,
                                      audioSource: FakeLiveAudioSource(samples: audio))
        return (tracker, transcriber, audio)
    }

    // MARK: - Content-free latency logging

    func testTimingLogUsesTheAcousticCloseAndCountsCharactersForADelayedCandidate() async {
        let marker = "UTTERANCE_PRIVATE_CANDIDATE_👩‍💻_e\u{301}"
        let timing = UtteranceTimingCapture()
        let gate = RequestGate()
        let audio = LiveCallFixture.audio([.silence(1), .speech(1), .silence(2)])
        let transcriber = FakeLiveTranscriber { _, _ in
            await gate.wait()
            return marker
        }
        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: transcriber,
                                       audioSource: FakeLiveAudioSource(samples: audio),
                                       timingNow: { timing.now },
                                       timingLog: { timing.record($0) })

        await feed(tracker, audio)
        XCTAssertTrue(timing.lines.isEmpty, "an undelivered utterance must not log")
        timing.advance(by: .milliseconds(1_234))
        gate.open()
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.first?.text, marker)
        XCTAssertEqual(transcriber.calls.count, 1)
        XCTAssertEqual(timing.lines, [
            "[LiveHints] utterance speaker=them closed_to_text_ms=1234 chars=\(marker.count)"
        ])
    }

    func testTimingLogMeasuresADelayedFinalRequestAfterTheCandidateBudget() async {
        let marker = "UTTERANCE_PRIVATE_FINAL"
        let timing = UtteranceTimingCapture()
        let gate = RequestGate()
        let audio = LiveCallFixture.audio([
            .silence(1), .speech(1), .silence(1), .speech(1),
            .silence(1), .speech(1), .silence(2)
        ])
        let transcriber = FakeLiveTranscriber { _, index in
            if index < 2 { return "UTTERANCE_PRIVATE_INCOMPLETE" }
            await gate.wait()
            return marker
        }
        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: transcriber,
                                       audioSource: FakeLiveAudioSource(samples: audio),
                                       timingNow: { timing.now },
                                       timingLog: { timing.record($0) })

        await feed(tracker, audio)
        timing.advance(by: .milliseconds(2_345))
        gate.open()
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.first?.text, marker)
        let requests = await tracker.requests
        XCTAssertEqual(requests.last?.kind, .final)
        XCTAssertEqual(timing.lines, [
            "[LiveHints] utterance speaker=them closed_to_text_ms=2345 chars=\(marker.count)"
        ])
    }

    func testTimingLogContainsNoTranscriptText() async {
        let marker = "UTTERANCE_TRANSCRIPT_SECRET_8D52F1"
        let timing = UtteranceTimingCapture()
        let audio = LiveCallFixture.audio([.silence(1), .speech(1), .silence(2)])
        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: FakeLiveTranscriber { _, _ in marker },
                                       audioSource: FakeLiveAudioSource(samples: audio),
                                       timingNow: { timing.now },
                                       timingLog: { timing.record($0) })

        await feed(tracker, audio)
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.first?.text, marker)
        XCTAssertEqual(timing.lines.count, 1)
        XCTAssertFalse(timing.lines.joined().contains(marker), "transcript text leaked into the timing log")
        XCTAssertTrue(timing.lines.allSatisfy {
            $0.range(of: #"^\[LiveHints\] utterance speaker=(me|them) closed_to_text_ms=[0-9]+ chars=[0-9]+$"#,
                     options: .regularExpression) != nil
        })
    }

    func testTimingLogUsesZeroCharactersForTheUsersOwnSideWithoutText() async {
        let timing = UtteranceTimingCapture()
        let audio = LiveCallFixture.audio([.silence(1), .speech(1), .silence(2)])
        let transcriber = FakeLiveTranscriber()
        let tracker = UtteranceTracker(speaker: .me,
                                       transcriber: transcriber,
                                       audioSource: FakeLiveAudioSource(samples: audio),
                                       timingNow: { timing.now },
                                       timingLog: { timing.record($0) })

        await feed(tracker, audio)
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertNil(closed.first?.text)
        XCTAssertTrue(transcriber.calls.isEmpty)
        XCTAssertEqual(timing.lines, ["[LiveHints] utterance speaker=me closed_to_text_ms=0 chars=0"])
    }

    // MARK: - Coverage: the last words must survive the candidate budget

    /// Three pauses spend both candidates before the final words are spoken.
    /// The utterance still closes with a request over the whole range, and the
    /// answer holds the words that were said last.
    func testThreePausesUseUpTheCandidatesAndTheFinalRequestStillCoversTheWholeUtterance() async throws {
        let (tracker, transcriber, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(1),          // pause 1 — the first candidate
            .speech(1),
            .silence(1),          // pause 2 — the second candidate
            .speech(1),
            .silence(1),          // pause 3 — the budget is spent
            .speech(1),           // the final words
            .silence(2),
        ], responder: { _, index in
            switch index {
            case 0: return "the first half of the question"
            case 1: return "the second half of the question"
            default: return "and the final words of the question"
            }
        })

        await feed(tracker, audio)
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.count, 1, "the utterance never closed")
        let utterance = try XCTUnwrap(closed.first)
        XCTAssertTrue(utterance.text?.contains("final words") == true,
                      "the answer lost the words that were said last")

        let requests = await tracker.requests
        XCTAssertEqual(requests.count, 3, "two candidates and one final request, no more")
        XCTAssertEqual(requests.filter { $0.kind == .candidate }.count, 2)
        let final = requests.last
        XCTAssertEqual(final?.kind, .final)
        XCTAssertEqual(final?.range.from, utterance.startSample, "the final request starts with the utterance")
        XCTAssertEqual(final?.range.to, utterance.endSample, "the final request ends with the utterance")
        XCTAssertTrue(transcriber.calls.allSatisfy { $0.countUsage == false },
                      "a live call must not add monthly minutes")
    }

    /// At most three requests per utterance: two candidates and the final one.
    func testAnUtteranceNeverCostsMoreThanThreeRequests() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(1),
            .speech(1),
            .silence(1),
            .speech(1),
            .silence(3),
        ])

        await feed(tracker, audio)
        _ = await waitForUtterances(1, in: tracker)

        let requests = await tracker.requests
        XCTAssertLessThanOrEqual(requests.count, 3, "an utterance cost more than three requests")
    }

    // MARK: - Late results

    /// A candidate that comes back after the speaker went on must never become
    /// the text of the longer utterance it was only a part of.
    func testACandidateThatArrivesAfterMoreSpeechIsNeverTheFinalText() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(1.2),        // the candidate goes out at 0.6 s
            .speech(1),           // the speaker goes on
            .silence(2),
        ], responder: { _, index in
            if index == 0 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return "the stale candidate"
            }
            return "the whole answer"
        })

        // Feed up to the point where the speaker goes on, so the late result
        // really lands on a longer utterance.
        let upTo = LiveCallFixture.audio([.silence(1), .speech(1), .silence(1.2)]).count
        await feed(tracker, Array(audio.prefix(upTo)))
        await waitForSettledRequests(1, in: tracker)

        await feed(tracker, Array(audio.dropFirst(upTo)))
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.first?.text, "the whole answer",
                       "the stale candidate became the text of the longer utterance")
    }

    /// A candidate still in flight when the utterance closes is waited for,
    /// not sent a second time.
    func testACandidateInFlightAtTheCloseIsAwaitedAndNotDuplicated() async {
        let (tracker, transcriber, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(2),
        ], responder: { _, _ in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return "the candidate answer"
        })

        await feed(tracker, audio)
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.first?.text, "the candidate answer",
                       "the text of the utterance came from somewhere else")
        XCTAssertEqual(transcriber.calls.count, 1, "the covering candidate was sent a second time")
    }

    // MARK: - Closing early on the text

    /// A question mark and 0.7 s of quiet end the utterance.
    func testTextEndingWithAQuestionMarkEndsTheUtteranceAfterSevenHundredMillisecondsOfQuiet() async {
        let (tracker, transcriber, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(2),
        ], responder: { _, _ in "So when do we ship?" })

        let beforePause = LiveCallFixture.audio([.silence(1), .speech(1)]).count
        await feed(tracker, Array(audio.prefix(beforePause)))

        // 0.65 s of quiet: the candidate has gone out, but the text may not
        // close the utterance before 0.7 s.
        let quiet = LiveCallFixture.audio([.silence(0.65)]).count
        await feed(tracker, Array(audio[beforePause ..< beforePause + quiet]))
        var closed = await tracker.closedUtterances
        XCTAssertTrue(closed.isEmpty, "the utterance closed before 0.7 s of quiet")

        // A tenth more and the text ends the utterance.
        let rest = LiveCallFixture.audio([.silence(0.1)]).count
        await feed(tracker, Array(audio[(beforePause + quiet) ..< (beforePause + quiet + rest)]))
        closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.text, "So when do we ship?")
        XCTAssertEqual(transcriber.calls.count, 1, "the candidate already covered the utterance")
    }

    /// Text without punctuation waits for the full 1.5 s of quiet.
    func testTextWithoutPunctuationNeedsASecondAndAHalfSecondsOfQuiet() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(2),
        ], responder: { _, _ in "so the plan is mostly ready" })

        let beforePause = LiveCallFixture.audio([.silence(1), .speech(1)]).count
        await feed(tracker, Array(audio.prefix(beforePause)))

        let quiet = LiveCallFixture.audio([.silence(0.75)]).count
        await feed(tracker, Array(audio[beforePause ..< beforePause + quiet]))
        var closed = await tracker.closedUtterances
        XCTAssertTrue(closed.isEmpty, "the utterance closed on text that does not end a sentence")

        let rest = LiveCallFixture.audio([.silence(0.8)]).count
        await feed(tracker, Array(audio[(beforePause + quiet) ..< (beforePause + quiet + rest)]))
        closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.count, 1, "the utterance never closed")
    }

    // MARK: - The utterance continues

    /// Speech that comes back after a second of quiet continues the same
    /// utterance, and the request that carries its text covers the whole clip.
    func testSpeechResumingAfterASecondContinuesTheUtteranceAndTheRequestCoversTheWholeClip() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(1),
            .speech(1),
            .silence(2),
        ])

        await feed(tracker, audio)
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.count, 1, "the pause split the utterance in two")
        let utterance = closed.first
        let resumedSpeechEnd = LiveCallFixture.audio([.silence(1), .speech(1), .silence(1), .speech(1)]).count
        XCTAssertEqual(utterance?.endSample, resumedSpeechEnd + UtteranceTracker.tailSamples,
                       "the utterance ended before the resumed speech")
        XCTAssertEqual(utterance?.startSample,
                       LiveCallFixture.audio([.silence(1)]).count - UtteranceTracker.tailSamples,
                       "the utterance did not start 0.25 s before the speech")

        let requests = await tracker.requests
        // The request made after the speech came back covers the whole clip,
        // so the utterance needs no second round of text.
        let last = requests.last
        XCTAssertTrue(last?.range.covers(LiveSampleRange(from: utterance?.startSample ?? 0,
                                                          to: utterance?.endSample ?? 0)) == true,
                      "the request does not cover the whole clip")
        XCTAssertEqual(last?.range.from, utterance?.startSample)
        XCTAssertEqual(last?.range.to, utterance?.endSample)
    }

    // MARK: - The cap

    /// A monologue that runs past 30 s is cut at the quietest frame of the
    /// last two seconds, and the rest opens a continuation.
    func testTheThirtySecondCapCutsAtTheQuietestFrameAndContinues() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(28.5, rms: 0.08),
            .speech(0.2, rms: 0.001),   // the quietest frame of the last two seconds
            .speech(1.5, rms: 0.08),
            .silence(2),                // the continuation closes as well
        ])

        await feed(tracker, audio)
        let closed = await waitForUtterances(2, in: tracker)

        XCTAssertGreaterThanOrEqual(closed.count, 2, "the cap never cut the utterance")
        let cut = LiveCallFixture.audio([.silence(1), .speech(28.5)]).count
        XCTAssertEqual(closed.first?.endSample, cut, "the cap did not cut at the quietest frame")
        XCTAssertEqual(closed.first?.isContinuation, false)
        XCTAssertEqual(closed.dropFirst().first?.isContinuation, true,
                       "the rest of the monologue did not open a continuation")
        XCTAssertEqual(closed.dropFirst().first?.startSample, cut)
    }

    // MARK: - The minimum and the `.me` stream

    /// Speech under 0.25 s is dropped; a short question is not.
    func testSpeechUnderAQuarterOfASecondIsDroppedAndAShortQuestionSurvives() async {
        let (blip, _, blipAudio) = makeTracker([
            .silence(1),
            .speech(0.2),
            .silence(2),
        ])
        await feed(blip, blipAudio)
        var closed = await waitForUtterances(1, in: blip, timeout: 0.5)
        XCTAssertTrue(closed.isEmpty, "a 0.2 s blip became an utterance")

        let (question, _, questionAudio) = makeTracker([
            .silence(1),
            .speech(0.4),
            .silence(2),
        ], responder: { _, _ in "When?" })
        await feed(question, questionAudio)
        closed = await waitForUtterances(1, in: question)
        XCTAssertEqual(closed.count, 1, "a 0.4 s question was dropped")
        XCTAssertEqual(closed.first?.text, "When?")
    }

    /// No candidate goes out while the utterance's speech is under 0.25 s:
    /// such an utterance is dropped at the close anyway, and every request is
    /// billed at the server's ten-second minimum.
    func testNoCandidateIsSentWhileTheUtteranceIsShorterThanAQuarterOfASecond() async {
        let (tracker, transcriber, audio) = makeTracker([
            .silence(1),
            .speech(0.2),
            .silence(2),
        ])

        await feed(tracker, audio)
        _ = await waitForUtterances(1, in: tracker, timeout: 0.5)

        let requests = await tracker.requests
        XCTAssertTrue(requests.isEmpty, "a request was sent for an utterance under 0.25 s")
        XCTAssertTrue(transcriber.calls.isEmpty, "the engine was called for an utterance under 0.25 s")
    }

    /// The user's own side has no candidates and no text: its words are
    /// batched later, not asked for here.
    func testTheUsersOwnSideClosesWithoutCandidatesAndWithoutText() async {
        let (tracker, transcriber, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(1),
            .speech(1),
            .silence(2),
        ], speaker: .me)

        await feed(tracker, audio)
        let closed = await waitForUtterances(1, in: tracker)

        XCTAssertEqual(closed.count, 1)
        XCTAssertNil(closed.first?.text, "the user's own side asked for text")
        XCTAssertTrue(transcriber.calls.isEmpty, "the user's own side sent a request")
    }

    // MARK: - Calibration safety

    /// Three capped clips in a row whose text is empty or noise raise the
    /// floor: what the detector heard as speech was not speech.
    func testThreeCappedClipsWithNoiseRaiseTheFloor() async {
        var segments: [LiveCallFixture.Segment] = [.silence(1)]
        for _ in 0..<250 {
            segments.append(.speech(0.6, rms: 0.01))
            segments.append(.silence(0.4))
        }
        let (tracker, _, audio) = makeTracker(segments)

        let floorBefore = await tracker.floor
        await feed(tracker, audio)
        _ = await waitForUtterances(3, in: tracker, timeout: 20)
        let floorAfter = await tracker.floor

        XCTAssertEqual(floorBefore, SpeechActivity.floorMinimum, accuracy: 0.000_001)
        XCTAssertEqual(floorAfter, 0.01, accuracy: 0.002,
                       "the floor did not rise to the level of the noise it heard as speech")
    }

    // MARK: - The text that is still coming

    /// The shortcut waits for the line that is still being transcribed: the
    /// text comes as soon as it is known (§3.4).
    func testThePendingTextComesWhenTheOpenUtteranceIsFinished() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(2),
        ], responder: { _, _ in "When can you send the proposal?" })

        // The speech: the utterance is open, its text is not known.
        let speech = LiveCallFixture.audio([.silence(1), .speech(1)])
        await feed(tracker, Array(audio.prefix(speech.count)))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let pending = Task { await tracker.pendingText(within: 5) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The pause: the candidate goes out and its text comes.
        await feed(tracker, Array(audio.dropFirst(speech.count)))
        let text = await pending.value

        XCTAssertEqual(text?.text, "When can you send the proposal?",
                       "the shortcut never learned what was said")
    }

    /// Nothing is open: there is no text to wait for.
    func testThePendingTextIsEmptyWhenNothingIsOpen() async {
        let (tracker, _, audio) = makeTracker([.silence(1)])
        await feed(tracker, audio)

        let text = await tracker.pendingText(within: 1)

        XCTAssertNil(text, "a text came out of an empty stream")
    }

    /// A line that says nothing in the time the shortcut waits: the shortcut
    /// goes on without it.
    func testThePendingTextGivesUpWhenTheUtteranceSaysNothing() async {
        let (tracker, _, audio) = makeTracker([.silence(1), .speech(1)])
        await feed(tracker, audio)

        let text = await tracker.pendingText(within: 0.3)

        XCTAssertNil(text, "a text came out of an utterance that never finished")
    }

    /// The utterance is closed, but its text is still coming: the shortcut
    /// waits for it — a question must not be answered without its last words
    /// (§3.4).
    func testThePendingTextCoversAnUtteranceThatIsWaitingForItsText() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(2),
        ], responder: { _, _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return "When can you send the proposal?"
        })

        await feed(tracker, audio)
        // The utterance is closed; its text is still on its way.
        let pending = Task { await tracker.pendingText(within: 5) }
        let text = await pending.value

        XCTAssertEqual(text?.text, "When can you send the proposal?",
                       "the shortcut never learned what was said")
    }

    // MARK: - The user's own speech

    /// The seconds of speech the tracker heard after a sample.
    func testTheSpeechSecondsCountTheSpeechAfterASample() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(2),
            .silence(1),
        ], speaker: .me)
        await feed(tracker, audio)

        // Halfway through the speech.
        let halfway = LiveCallFixture.audio([.silence(1), .speech(1)]).count
        let seconds = await tracker.speechSeconds(after: halfway, excluding: [])

        XCTAssertEqual(seconds, 1.0, accuracy: 0.06,
                       "the speech after the sample was not counted")
    }

    /// The words the user dictated are not the user speaking: the pause
    /// windows are taken out of the count (§3.4).
    func testTheDictationPauseIsNotCountedAsSpeech() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(2),
            .silence(1),
        ], speaker: .me)
        await feed(tracker, audio)

        let halfway = LiveCallFixture.audio([.silence(1), .speech(1)]).count
        let pause = LiveSampleRange(from: 0, to: 64_000)
        let seconds = await tracker.speechSeconds(after: halfway, excluding: [pause])

        XCTAssertEqual(seconds, 0, accuracy: 0.001,
                       "the dictated words were counted as the user speaking")
    }

    // MARK: - The end of the meeting

    /// The meeting ends while the text of the utterance is still coming: the
    /// utterance is never delivered (§6.15).
    func testTheStoppedTrackerDeliversNothing() async {
        let (tracker, _, audio) = makeTracker([
            .silence(1),
            .speech(1),
            .silence(2),
        ], responder: { _, _ in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "the question"
        })

        await feed(tracker, audio)
        await tracker.stop()
        try? await Task.sleep(nanoseconds: 900_000_000)

        let closed = await tracker.closedUtterances
        XCTAssertTrue(closed.isEmpty,
                      "the stopped tracker delivered the utterance of a meeting that is over")
    }

    // MARK: - The replaced buffer

    /// The capture is restarted while the resolver of a closed utterance is
    /// on its way: the utterance is not delivered, and the final request
    /// reads nothing from the new buffer (§3.2).
    ///
    /// The buffer of the new capture holds other audio, and the old range
    /// means nothing in it.
    func testAClosedUtteranceThatWaitsAcrossABufferReplacementDeliversNothing() async {
        let audio = LiveCallFixture.audio([
            .silence(1),
            .speech(1),
            .silence(2),
        ])
        let gate = RequestGate()
        let transcriber = GatedLiveTranscriber(gate: gate)
        let source = FakeLiveAudioSource(samples: audio)
        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: transcriber,
                                       audioSource: source)

        await feed(tracker, audio)
        // The candidate is on its way, and the resolver waits for it.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, transcriber.callCount < 1 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(transcriber.callCount, 1, "the candidate never went out")
        let readsBefore = source.reads.count

        // The capture was restarted: the buffer and its padding are
        // replaced, and the tracker starts over with it.
        await tracker.reset()
        gate.open()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let closed = await tracker.closedUtterances
        XCTAssertTrue(closed.isEmpty,
                      "the utterance of the old buffer was delivered after the capture was restarted")
        XCTAssertEqual(source.reads.count, readsBefore,
                       "the final request read the new buffer")
    }

    // MARK: - The resolver that waits for a candidate

    /// The meeting ends while the closed utterance waits for its candidate:
    /// no final request goes out (§6.15).
    ///
    /// The token belongs to the session, not to the tracker: the tracker stops
    /// its own work, and the session ends the one cancellation every part
    /// shares.
    func testAClosedUtteranceThatWaitsForItsCandidateSendsNoFinalRequestAfterTheStop() async {
        let audio = LiveCallFixture.audio([
            .silence(1),
            .speech(1),
            .silence(2),
        ])
        let gate = RequestGate()
        let transcriber = GatedLiveTranscriber(gate: gate)
        let token = LiveHintsStopToken()
        let tracker = UtteranceTracker(speaker: .them,
                                       transcriber: transcriber,
                                       audioSource: FakeLiveAudioSource(samples: audio),
                                       stopToken: token)

        await feed(tracker, audio)
        // The candidate is on its way, and the resolver waits for it.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, transcriber.callCount < 1 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(transcriber.callCount, 1, "the candidate never went out")

        // The tracker stops: its own work ends, but the session's
        // cancellation is not the tracker's to stop.
        await tracker.stop()
        XCTAssertFalse(token.isCancelled,
                       "the tracker stopped the cancellation the whole session shares")

        // The session ends: the one cancellation goes.
        token.stop()
        gate.open()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(transcriber.callCount, 1,
                       "a final request went out after the meeting ended")
    }
}

private final class UtteranceTimingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var recorded: [String] = []

    var now: ContinuousClock.Instant { lock.withLock { instant } }
    var lines: [String] { lock.withLock { recorded } }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }

    func record(_ line: String) {
        lock.withLock { recorded.append(line) }
    }
}
