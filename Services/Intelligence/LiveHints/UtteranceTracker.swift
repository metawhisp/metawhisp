import Foundation

/// The sample range one live request covers, `[from, to)`.
struct LiveSampleRange: Equatable, Sendable {
    let from: Int
    let to: Int

    /// How many samples the range holds.
    var count: Int { to - from }

    /// True when this range holds every sample of `other`.
    func covers(_ other: LiveSampleRange) -> Bool {
        from <= other.from && to >= other.to
    }
}

/// The audio a live request covers.
///
/// The tracker never keeps the audio: it asks for the range it needs, so the
/// recorder stays the only owner of the samples.
///
/// The read is awaited: the recorder's peek lives on the main actor, and a
/// request that runs off it must not touch the buffer without it.
protocol LiveAudioSource: Sendable {
    /// The `count` samples starting at `from`.
    func samples(from: Int, count: Int) async -> [Float]
}

/// One live transcription.
protocol LiveTranscriber: Sendable {
    /// - Parameters:
    ///   - samples: the audio of `range`.
    ///   - range: the absolute sample range the audio covers.
    ///   - countUsage: `false` on every live call. A live pass is part of the
    ///     meeting, which is billed once when the meeting ends — billing the
    ///     live passes as well would charge the same audio twice.
    func transcribe(samples: [Float], range: LiveSampleRange, countUsage: Bool) async throws -> String
}

/// The text of an utterance that is still being transcribed, and where it
/// ended.
///
/// The answer that was given from it marks the transcript it used: the end of
/// the line is that mark, and the lines that came after it are the ones the
/// next answer has to see (§3.4).
struct LivePendingText: Equatable, Sendable {
    /// The text itself.
    let text: String
    /// The sample after the last one of the utterance, on the timeline the
    /// text was read on.
    let endSample: Int
}

/// The utterances of one meeting stream, and the requests that carry their text.
///
/// An utterance covers the samples from 0.25 s before the speech to 0.25 s
/// after it. It closes when the stream goes quiet for 1.5 s, or when it grows
/// past 30 s — and the text may close it earlier: a candidate request whose
/// text ends a sentence, with nothing said after it and 0.7 s of quiet, ends
/// the utterance at once.
///
/// The text of a closed utterance always comes from a request that covers the
/// whole of it. A candidate that already covers it is reused, a candidate
/// still in flight is waited for, and otherwise a final request goes out —
/// the candidate budget never blocks the final request, so the last words of
/// a question are never lost.
///
/// The user's own side sends no requests at all: its words are batched later.
actor UtteranceTracker {

    // MARK: - What it reports

    /// Which side of the call a stream belongs to.
    enum Speaker: String, Equatable, Sendable {
        /// The user.
        case me
        /// The other side.
        case them
    }

    /// A finished utterance.
    struct ClosedUtterance: Equatable, Sendable {
        let speaker: Speaker
        /// The first sample of the utterance — 0.25 s before the speech.
        let startSample: Int
        /// The sample after the last one of the utterance.
        let endSample: Int
        /// The text of the utterance. `nil` for the user's own side, whose
        /// words are batched later.
        let text: String?
        /// True when the utterance continues the one before it.
        let isContinuation: Bool
    }

    /// What a request was for.
    enum RequestKind: Equatable, Sendable {
        /// The text of the utterance so far, sent at a pause.
        case candidate
        /// The text of the whole utterance.
        case final
    }

    /// One request the tracker sent.
    struct RequestRecord: Equatable, Sendable {
        /// The version of the utterance the request was made against. More
        /// speech raises the version, and a result from an older version is
        /// stale: it says nothing about the words that came after it.
        let revision: Int
        /// The samples the request covers.
        let range: LiveSampleRange
        let kind: RequestKind
    }

    // MARK: - The rules

    /// Silence that closes an utterance when the text does not.
    static let acousticCloseSilence: Double = 1.5
    /// A candidate request may go out at this much silence.
    static let candidatePause: Double = 0.6
    /// The text may close the utterance at this much silence.
    static let earlyCloseSilence: Double = 0.7
    /// The longest an utterance may grow.
    static let capDuration: Double = 30
    /// The cap cuts at the quietest frame of this much audio.
    static let capLookback: Double = 2
    /// At most this many candidates per utterance.
    static let maxCandidates = 2
    /// The tail kept after the last speech frame.
    static let tailSamples = 4_000
    /// Speech shorter than this is dropped.
    static let minimumSpeechSamples = 4_000
    /// An utterance this close to the one before it continues it.
    static let continuationWindowSamples = 32_000
    /// How long an in-flight request may be waited for.
    static let requestDeadline: Double = 8
    /// Capped clips in a row with empty or noise text that raise the floor.
    static let calibrationRuns = 3
    /// How much of the stream the speech history keeps.
    static let speechHistorySeconds: Double = 600
    /// Wall-clock freshness of the capsule's speaker projection.
    private static let recentSpeechLifetime: Duration = .milliseconds(600)
    /// The punctuation that ends a sentence, in either script.
    static let terminators: Set<Character> = [".", "?", "!", "…", "？", "。", "！"]

    // MARK: - The state

    private let speaker: Speaker
    private let transcriber: LiveTranscriber
    private let audioSource: LiveAudioSource
    private let timingNow: @Sendable () -> ContinuousClock.Instant
    private let timingLog: @Sendable (String) -> Void

    /// The cancellation of the session this tracker belongs to.
    ///
    /// The tracker asks the engine only while the session runs: a candidate
    /// or a final request that was on its way when the meeting ended never
    /// leaves the app (§6.15).
    private let stopToken: LiveHintsStopToken

    /// The acoustic half: which samples are speech.
    private var activity = SpeechActivity()
    /// The utterance in progress, if any.
    private var open: OpenUtterance?
    /// The utterance that is closed and whose text is still coming.
    ///
    /// The silence closed it, but the words are still being transcribed. The
    /// shortcut waits for them: a question must not be answered without its
    /// last words (§3.4).
    private var closing: ClosingUtterance?
    /// Where the utterance before this one ended.
    private var previousCloseSample: Int?
    /// The epoch of the stream the tracker counts.
    ///
    /// The stream may be replaced in the middle of a meeting: the buffer and
    /// its padding are new, and the samples the tracker counts from zero
    /// belong to another meeting. A reset starts a new epoch, and the work of
    /// an old epoch delivers nothing and reads no audio (§3.2).
    private var epoch = 0
    /// Counts the utterances, so a result knows which one it belongs to.
    private var utteranceCounter = 0
    /// Counts the requests, so a candidate knows which one it is.
    private var requestCounter = 0
    /// Counts the closes, so the calibration can tell a run from a break.
    private var closeCounter = 0
    /// Capped clips in a row whose text was empty or noise.
    private var calibrationStreak = 0
    /// The close that broke the run of capped clips.
    private var calibrationBreak = 0
    /// The frames the tracker saw, with the time they cover. Only the last
    /// ten minutes are kept: the answer service asks how long the user spoke
    /// after a line, and that question is never about the whole meeting.
    private var frameFlags: [FrameFlag] = []
    private var lastSpeechAt: ContinuousClock.Instant?
    /// The waiters for the text of the utterance that is open.
    private var pendingWaiters: [PendingWaiter] = []
    /// Called for every closed utterance.
    private var handler: (@Sendable (ClosedUtterance) -> Void)?
    /// True when the meeting is over: the tracker delivers nothing more (§6.15).
    private var isStopped = false

    /// Every request, in order.
    private(set) var requests: [RequestRecord] = []
    /// Every closed utterance, in order.
    private(set) var closedUtterances: [ClosedUtterance] = []
    /// How many request results the tracker has taken in.
    private(set) var settledRequests = 0

    // MARK: - Setting it up

    init(speaker: Speaker,
         transcriber: LiveTranscriber,
         audioSource: LiveAudioSource,
         stopToken: LiveHintsStopToken = LiveHintsStopToken(),
         timingNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         timingLog: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        self.speaker = speaker
        self.transcriber = transcriber
        self.audioSource = audioSource
        self.stopToken = stopToken
        self.timingNow = timingNow
        self.timingLog = timingLog
    }

    /// Called for every closed utterance, in order. Set it before the first
    /// samples arrive.
    func setHandler(_ handler: @escaping @Sendable (ClosedUtterance) -> Void) {
        self.handler = handler
    }

    /// The meeting is over: the requests in flight are dropped, and no
    /// utterance is delivered any more (§6.15).
    ///
    /// The tracker stops its own work only. The token belongs to the session:
    /// the other side of the meeting shares it, and the session is the one
    /// that stops it.
    func stop() {
        isStopped = true
        lastSpeechAt = nil
        // The open utterance's candidates go away.
        if let utterance = open {
            for candidate in utterance.candidates { candidate.task.cancel() }
        }
        open = nil
        closing = nil
        // The waiters for the text go away empty-handed.
        resumePendingWaiters(with: nil)
    }

    /// The level of the room, as the detector sees it.
    var floor: Float { activity.floor }

    /// The stream was replaced: the tracker starts over with the new one.
    ///
    /// The tracker counts the samples it receives from zero, so the new
    /// buffer has to be counted from zero as well: the utterance that was in
    /// progress goes away, and the levels of the old buffer go with it
    /// (§3.2).
    ///
    /// A new epoch starts: the work that was on its way belongs to the old
    /// buffer, and it delivers nothing and reads no audio (§3.2).
    func reset() {
        epoch += 1
        activity = SpeechActivity()
        open = nil
        closing = nil
        previousCloseSample = nil
        frameFlags = []
        lastSpeechAt = nil
        // The waiters for the text of the old utterance go away empty-handed.
        resumePendingWaiters(with: nil)
    }

    /// Whether the work still belongs to the epoch it was made in.
    ///
    /// The work of an old epoch is dropped: it belongs to a buffer that is
    /// gone (§3.2).
    private func isCurrentEpoch(_ epoch: Int) -> Bool {
        self.epoch == epoch
    }

    // MARK: - The text that is still coming

    /// The text of the utterance that is open, once it is known.
    ///
    /// The shortcut asks for it before it asks the model: a question that is
    /// still being transcribed must not be answered without its last words.
    /// The wait is short — a question that takes longer than that is answered
    /// without it, and the answer says what should be said next instead
    /// (§3.4).
    ///
    /// The utterance that is open, or the one that is closed and whose text
    /// is still coming: the silence may close a question before its words are
    /// known, and the shortcut still owes it those words.
    ///
    /// Nil when there is no such utterance, and nil when the text did not come
    /// in time.
    ///
    /// The end of the utterance comes with the text: an answer that was given
    /// from it marks the transcript it used, and the end of the line is that
    /// mark (§3.4).
    func pendingText(within seconds: Double) async -> LivePendingText? {
        // The utterance that is open is the newer one; the one that is
        // closing is the question before it.
        let waiting: (utterance: OpenUtterance, range: LiveSampleRange)
        if let utterance = open {
            waiting = (utterance, utterance.range)
        } else if let closing {
            waiting = (closing.utterance, closing.range)
        } else {
            return nil
        }

        // A candidate that already covers the utterance has its text.
        for candidate in waiting.utterance.candidates {
            if let text = candidate.text, candidate.request.range.covers(waiting.range) {
                return LivePendingText(text: text, endSample: waiting.range.to)
            }
        }

        let id = UUID()
        let slot = Slot()
        return await withCheckedContinuation { continuation in
            pendingWaiters.append(PendingWaiter(id: id,
                                                 utteranceID: waiting.utterance.id,
                                                 endSample: waiting.range.to,
                                                 slot: slot,
                                                 continuation: continuation))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.pendingTimedOut(id: id)
            }
        }
    }

    /// The text did not come in time: the waiter goes away empty-handed.
    private func pendingTimedOut(id: UUID) {
        guard let index = pendingWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = pendingWaiters.remove(at: index)
        if waiter.slot.take() { waiter.continuation.resume(returning: nil) }
    }

    /// The text of an utterance is known: everybody waiting for it goes.
    ///
    /// A waiter waits for one utterance: the text of another one is not its
    /// answer, so it keeps waiting. Without an utterance, every waiter goes.
    private func resumePendingWaiters(with text: String?, of utteranceID: Int? = nil) {
        var staying: [PendingWaiter] = []
        for waiter in pendingWaiters {
            if let utteranceID, waiter.utteranceID != utteranceID {
                staying.append(waiter)
                continue
            }
            if waiter.slot.take() {
                waiter.continuation.resume(returning: text.map {
                    LivePendingText(text: $0, endSample: waiter.endSample)
                })
            }
        }
        pendingWaiters = staying
    }

    /// A waiter for the text of an utterance.
    private struct PendingWaiter {
        let id: UUID
        /// The utterance the waiter waits for.
        let utteranceID: Int
        /// Where the utterance ended when the waiter began to wait.
        let endSample: Int
        /// The first writer wins: the waiter is resumed exactly once.
        let slot: Slot
        let continuation: CheckedContinuation<LivePendingText?, Never>
    }

    // MARK: - The samples

    /// Feeds the samples of the stream.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty, !isStopped, !stopToken.isCancelled else { return }
        for frame in activity.append(samples) {
            record(frame)
            process(frame)
        }
    }

    /// Keeps the frame in the history: which of the frames were speech, and
    /// when they were said.
    private func record(_ frame: SpeechActivity.Frame) {
        let speechAt = frame.isSpeech ? timingNow() : nil
        if let speechAt { lastSpeechAt = speechAt }
        frameFlags.append(FrameFlag(startSample: frame.startSample,
                                    endSample: frame.endSample,
                                    isSpeech: frame.isSpeech,
                                    speechAt: speechAt))
        let limit = Int(Self.speechHistorySeconds / SpeechActivity.frameDuration)
        if frameFlags.count > limit {
            frameFlags.removeFirst(frameFlags.count - limit)
        }
    }

    /// A stalled stream expires by the clock; dictation frames never identify a speaker.
    func recentSpeech(excluding windows: [LiveSampleRange]) -> Bool {
        guard !isStopped, !stopToken.isCancelled, let lastSpeechAt else { return false }
        let now = timingNow()
        guard lastSpeechAt.duration(to: now) <= Self.recentSpeechLifetime else { return false }
        for flag in frameFlags.reversed() {
            guard let speechAt = flag.speechAt else { continue }
            guard speechAt.duration(to: now) <= Self.recentSpeechLifetime else { return false }
            if windows.contains(where: { $0.from < flag.endSample && flag.startSample < $0.to }) { continue }
            return true
        }
        return false
    }

    /// The seconds of speech the tracker heard after a sample.
    ///
    /// The windows are taken out: the words the user dictated are not the
    /// user answering the other side, so they never mark a question as
    /// answered (§3.4).
    func speechSeconds(after sample: Int, excluding windows: [LiveSampleRange]) -> Double {
        var seconds = 0.0
        for flag in frameFlags {
            guard flag.isSpeech else { continue }
            guard flag.startSample >= sample else { continue }
            if windows.contains(where: { $0.from < flag.endSample && flag.startSample < $0.to }) { continue }
            seconds += SpeechActivity.frameDuration
        }
        return seconds
    }

    /// One frame of the stream, as the history keeps it.
    private struct FrameFlag {
        let startSample: Int
        let endSample: Int
        let isSpeech: Bool
        let speechAt: ContinuousClock.Instant?
    }

    // MARK: - One frame

    private func process(_ frame: SpeechActivity.Frame) {
        guard var utterance = open else {
            // A run of speech opens an utterance.
            if let onset = frame.onset {
                open = makeUtterance(onset: onset, frame: frame)
            }
            return
        }

        utterance.frames.append(frame)

        if frame.isSpeech {
            utterance.speechEndSample = frame.endSample
            utterance.lastSpeechFrameStart = frame.startSample
            utterance.quietFrames = 0
            utterance.candidateSentThisPause = false
            // The utterance grew, so anything said about the old range is stale.
            utterance.revision += 1
        } else {
            utterance.quietFrames += 1
            let quiet = Double(utterance.quietFrames) * SpeechActivity.frameDuration

            // A pause may send a candidate — at most two per utterance.
            if speaker == .them,
               !utterance.candidateSentThisPause,
               quiet >= Self.candidatePause,
               utterance.candidates.count < Self.maxCandidates {
                sendCandidate(&utterance)
            }

            // The text may end the utterance before the silence does.
            if speaker == .them,
               quiet >= Self.earlyCloseSilence,
               closingCandidate(in: utterance) != nil {
                close(utterance, at: utterance.range)
                return
            }

            // Silence ends the utterance.
            if quiet >= Self.acousticCloseSilence {
                close(utterance, at: utterance.range)
                return
            }
        }

        // The cap: the utterance has grown past its share of the call.
        let length = Double(frame.endSample - utterance.startSample) / Double(SpeechActivity.sampleRate)
        if length >= Self.capDuration {
            capClose(utterance)
            return
        }

        open = utterance
    }

    // MARK: - The utterance

    /// The utterance a new speech run opens.
    private func makeUtterance(onset: SpeechActivity.Onset, frame: SpeechActivity.Frame) -> OpenUtterance {
        utteranceCounter += 1
        // An utterance that starts right after the one before it continues it.
        let isContinuation = previousCloseSample
            .map { onset.startSample - $0 <= Self.continuationWindowSamples } ?? false
        return OpenUtterance(
            id: utteranceCounter,
            startSample: onset.startSample,
            speechStartSample: onset.speechStartSample,
            speechEndSample: frame.endSample,
            lastSpeechFrameStart: frame.startSample,
            quietFrames: 0,
            revision: 1,
            candidates: [],
            candidateSentThisPause: false,
            frames: [frame],
            isContinuation: isContinuation
        )
    }

    /// The utterance that continues the one the cap just cut.
    private func makeContinuation(from cut: Int, frames: [SpeechActivity.Frame]) -> OpenUtterance {
        utteranceCounter += 1
        var speechStart = cut
        var speechEnd = cut
        var lastSpeechStart = cut
        var quietFrames = 0
        var foundSpeech = false
        for frame in frames {
            if frame.isSpeech {
                if !foundSpeech {
                    speechStart = frame.startSample
                    foundSpeech = true
                }
                speechEnd = frame.endSample
                lastSpeechStart = frame.startSample
                quietFrames = 0
            } else {
                quietFrames += 1
            }
        }
        return OpenUtterance(
            id: utteranceCounter,
            startSample: cut,
            speechStartSample: speechStart,
            speechEndSample: speechEnd,
            lastSpeechFrameStart: lastSpeechStart,
            quietFrames: quietFrames,
            revision: 1,
            candidates: [],
            candidateSentThisPause: false,
            frames: frames,
            isContinuation: true
        )
    }

    // MARK: - The requests

    /// Sends a candidate: the text of the utterance so far.
    private func sendCandidate(_ utterance: inout OpenUtterance) {
        // Speech under 0.25 s is dropped when the utterance closes, so there
        // is nothing to ask for — and every request is billed at the server's
        // ten-second minimum. The candidate goes out later if the speech
        // grows: the pause flag is not set, so the next pause may send one.
        guard utterance.speechEndSample - utterance.speechStartSample >= Self.minimumSpeechSamples else {
            return
        }
        let range = utterance.range
        requestCounter += 1
        let id = requestCounter
        let request = RequestRecord(revision: utterance.revision, range: range, kind: .candidate)
        requests.append(request)

        let speechEnd = utterance.speechEndSample
        let transcriber = self.transcriber
        let audioSource = self.audioSource
        let stopToken = self.stopToken
        // The epoch the candidate belongs to: a replaced buffer ends it.
        let epoch = self.epoch
        let task = Task.detached { [weak self] () -> String? in
            // The buffer was replaced while the candidate was on its way: it
            // reads no audio and delivers nothing (§3.2).
            guard await self?.isCurrentEpoch(epoch) == true else { return nil }
            // The audio is fetched inside the task: the peek is on the main
            // actor, and a candidate must not hold the tracker's thread.
            let samples = await audioSource.samples(from: range.from, count: range.count)
            // The meeting may have ended while the audio was fetched: the
            // candidate never leaves the app (§6.15).
            guard !stopToken.isCancelled else { return nil }
            // The buffer may have been replaced while the audio was fetched:
            // the candidate reads nothing from the new buffer (§3.2).
            guard await self?.isCurrentEpoch(epoch) == true else { return nil }
            let text = try? await transcriber.transcribe(samples: samples, range: range, countUsage: false)
            await self?.candidateFinished(id: id, text: text, epoch: epoch)
            return text
        }
        // The candidate belongs to the session: it is cancelled with it.
        stopToken.retain(task)
        utterance.candidates.append(Candidate(id: id,
                                              request: request,
                                              speechEnd: speechEnd,
                                              task: task,
                                              text: nil))
        utterance.candidateSentThisPause = true
    }

    /// Sends the final request: the text of the whole utterance.
    ///
    /// The epoch is the one the utterance was closed in: a request of an old
    /// epoch reads nothing and asks nothing (§3.2).
    private func sendFinal(range: LiveSampleRange, revision: Int, epoch: Int) async -> String? {
        // The meeting may be over: the final request never leaves the app.
        guard !stopToken.isCancelled else { return nil }
        // The buffer was replaced: the request reads nothing from the new
        // buffer (§3.2).
        guard epoch == self.epoch else { return nil }
        requestCounter += 1
        let request = RequestRecord(revision: revision, range: range, kind: .final)
        requests.append(request)
        let samples = await audioSource.samples(from: range.from, count: range.count)
        // The check stands right before the call: the meeting may have ended
        // while the audio was fetched (§6.15).
        guard !stopToken.isCancelled else {
            settledRequests += 1
            return nil
        }
        // The buffer may have been replaced while the audio was fetched: the
        // request reads nothing from the new buffer (§3.2).
        guard epoch == self.epoch else {
            settledRequests += 1
            return nil
        }
        do {
            let text = try await transcriber.transcribe(samples: samples, range: range, countUsage: false)
            settledRequests += 1
            return text
        } catch {
            settledRequests += 1
            return nil
        }
    }

    /// The text of a closed utterance: from a request that covers all of it.
    private func resolveText(utterance: OpenUtterance,
                             range: LiveSampleRange,
                             epoch: Int) async -> String? {
        for candidate in utterance.candidates where candidate.request.range.covers(range) {
            // The candidate covers the whole utterance: wait for it rather than
            // sending the same audio twice.
            if let text = await awaitWithin(candidate.task, seconds: Self.requestDeadline) {
                return text
            }
            break
        }
        return await sendFinal(range: range, revision: utterance.revision, epoch: epoch)
    }

    /// Waits for a task, but not longer than `seconds`.
    ///
    /// A wait that is cancelled ends at once: the resolver of a closed
    /// utterance belongs to the session, and the session's end must not wait
    /// for a candidate that never comes (§6.15).
    private func awaitWithin(_ task: Task<String?, Never>, seconds: Double) async -> String? {
        let wait = WaitSlot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wait.setContinuation(continuation)
                Task {
                    let text = await task.value
                    wait.resume(text)
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    wait.resume(nil)
                }
            }
        } onCancel: {
            wait.resume(nil)
        }
    }

    // MARK: - The results

    /// A candidate's text came back.
    private func candidateFinished(id: Int, text: String?, epoch: Int) async {
        settledRequests += 1
        // The buffer was replaced while the candidate was on its way: its
        // text belongs to another epoch (§3.2).
        guard epoch == self.epoch else { return }
        guard var utterance = open,
              let index = utterance.candidates.firstIndex(where: { $0.id == id }) else { return }
        utterance.candidates[index].text = text

        // Nothing was said after this candidate, so its text is the whole of
        // what has been said: whoever waits for the open utterance's text may
        // have it now.
        if utterance.lastSpeechFrameStart <= utterance.candidates[index].speechEnd,
           let text {
            resumePendingWaiters(with: text, of: utterance.id)
        }

        // The text ends the utterance — but only if it is the whole of what
        // was said, and only after 0.7 s of quiet.
        if speaker == .them,
           let text,
           endsSentence(text),
           utterance.lastSpeechFrameStart <= utterance.candidates[index].speechEnd,
           Double(utterance.quietFrames) * SpeechActivity.frameDuration >= Self.earlyCloseSilence {
            close(utterance, at: utterance.range)
            return
        }
        open = utterance
    }

    /// The candidate whose text may close the utterance, if there is one.
    private func closingCandidate(in utterance: OpenUtterance) -> Candidate? {
        for candidate in utterance.candidates {
            guard let text = candidate.text, endsSentence(text) else { continue }
            // Nothing was said after the candidate's covered end, so its text
            // is the whole of the utterance.
            guard utterance.lastSpeechFrameStart <= candidate.speechEnd else { continue }
            return candidate
        }
        return nil
    }

    /// True when the text ends a sentence.
    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return Self.terminators.contains(last)
    }

    // MARK: - Closing

    /// Closes the utterance and sends what its text needs.
    private func close(_ utterance: OpenUtterance, at range: LiveSampleRange, hitCap: Bool = false) {
        open = nil
        closeCounter += 1
        let sequence = closeCounter

        // Speech under 0.25 s is dropped.
        guard utterance.speechEndSample - utterance.speechStartSample >= Self.minimumSpeechSamples else { return }
        let closedAt = timingNow()
        previousCloseSample = range.to

        if !hitCap {
            // A close that was not the cap breaks the run of capped clips.
            calibrationStreak = 0
            calibrationBreak = sequence
        }

        // The user's own side is batched later, so there is nothing to ask for.
        guard speaker == .them else {
            deliver(ClosedUtterance(speaker: speaker,
                                    startSample: range.from,
                                    endSample: range.to,
                                    text: nil,
                                    isContinuation: utterance.isContinuation),
                    closedAt: closedAt)
            return
        }

        // The utterance is closed, but its text is still coming. It is kept
        // until it is delivered: the shortcut waits for it (§3.4).
        //
        // The epoch the utterance was closed in: a replaced buffer ends the
        // resolver (§3.2).
        let epoch = self.epoch
        let resolver = Task { [weak self] in
            await self?.resolveAndDeliver(utterance,
                                          range: range,
                                          sequence: sequence,
                                          hitCap: hitCap,
                                          epoch: epoch,
                                          closedAt: closedAt)
        }
        // The resolver belongs to the session: it is cancelled with it, so a
        // final request is never sent after the meeting ended (§6.15).
        let handle = stopToken.retain { resolver.cancel() }
        closing = ClosingUtterance(utterance: utterance, range: range, resolverHandle: handle)
    }

    /// The cap: the utterance grew past its share of the call. It is cut at the
    /// quietest frame of the last two seconds, and the rest opens a
    /// continuation of the same monologue.
    private func capClose(_ utterance: OpenUtterance) {
        let lookback = Int(Self.capLookback / SpeechActivity.frameDuration)
        let window = Array(utterance.frames.suffix(lookback))
        // The quietest frame of the window. Frames within a hair of it are the
        // same quietness, and the earliest of them is the one to cut at: the
        // pause then belongs to the continuation and the utterance ends with
        // the speech before it.
        let quietest = window.map(\.rms).min() ?? 0
        let cut = window.first { $0.rms <= quietest * 1.01 }?.startSample ?? utterance.speechEndSample
        let range = LiveSampleRange(from: utterance.startSample, to: cut)
        let rest = utterance.frames.filter { $0.startSample >= cut }

        close(utterance, at: range, hitCap: true)

        // The rest of the audio opens a continuation.
        open = makeContinuation(from: cut, frames: rest)
    }

    /// Finds the text of the closed utterance and delivers it.
    private func resolveAndDeliver(_ utterance: OpenUtterance,
                                    range: LiveSampleRange,
                                    sequence: Int,
                                    hitCap: Bool,
                                    epoch: Int,
                                    closedAt: ContinuousClock.Instant) async {
        let text = await resolveText(utterance: utterance, range: range, epoch: epoch)
        // The calibration of the old buffer does not touch the new one.
        if hitCap, epoch == self.epoch {
            await applyCalibration(text: text, utterance: utterance, sequence: sequence)
        }
        // The utterance is over: its text is the text everyone waited for.
        resumePendingWaiters(with: text, of: utterance.id)
        if let closing, closing.utterance.id == utterance.id {
            // The resolver is done: it needs no cancelling any more.
            stopToken.release(closing.resolverHandle)
            self.closing = nil
        }
        // The buffer was replaced while the resolver was on its way: the
        // utterance of the old buffer is not delivered (§3.2).
        guard epoch == self.epoch else { return }
        deliver(ClosedUtterance(speaker: speaker,
                                startSample: range.from,
                                endSample: range.to,
                                text: text,
                                isContinuation: utterance.isContinuation),
                closedAt: closedAt)
    }

    private func deliver(_ utterance: ClosedUtterance, closedAt: ContinuousClock.Instant) {
        guard !isStopped else { return }
        let elapsed = closedAt.duration(to: timingNow()).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        timingLog("[LiveHints] utterance speaker=\(utterance.speaker.rawValue) closed_to_text_ms=\(milliseconds) chars=\(utterance.text?.count ?? 0)")
        closedUtterances.append(utterance)
        handler?(utterance)
    }

    // MARK: - Calibration safety

    /// Three capped clips in a row whose text is empty or noise mean the
    /// detector heard the room as speech. The floor goes up to the level of
    /// that clip, so the same noise is not heard as speech again.
    private func applyCalibration(text: String?, utterance: OpenUtterance, sequence: Int) async {
        // A close that was not the cap broke the run after this clip.
        guard sequence > calibrationBreak else { return }

        let median = SpeechActivity.percentile(0.5, of: utterance.frames.map(\.rms))
        let isNoise = await MainActor.run {
            if case .drop = MeetingChunkTextGate.decide(text: text ?? "", rms: median) { return true }
            return false
        }

        calibrationStreak = isNoise ? calibrationStreak + 1 : 0
        guard calibrationStreak >= Self.calibrationRuns else { return }
        calibrationStreak = 0
        activity.raiseFloor(to: median)
    }

    // MARK: - The utterance in progress

    /// An utterance in progress.
    private struct OpenUtterance {
        /// Tells the utterances apart, so a result knows which one it is for.
        let id: Int
        /// The first sample of the utterance.
        var startSample: Int
        /// The first speech frame of the utterance.
        var speechStartSample: Int
        /// The end of the last speech frame.
        var speechEndSample: Int
        /// The start of the last speech frame.
        var lastSpeechFrameStart: Int
        /// Quiet frames in a row, zero while the stream carries speech.
        var quietFrames: Int
        /// The version of the covered range.
        var revision: Int
        /// The candidates sent so far.
        var candidates: [Candidate]
        /// True when a candidate already went out for the current pause.
        var candidateSentThisPause: Bool
        /// The frames of this utterance — for the cap and the median level.
        var frames: [SpeechActivity.Frame]
        /// True when the utterance continues the one before it.
        var isContinuation: Bool

        /// The range the utterance covers right now.
        var range: LiveSampleRange {
            LiveSampleRange(from: startSample, to: speechEndSample + UtteranceTracker.tailSamples)
        }
    }

    /// An utterance that is closed and whose text is still being resolved.
    private struct ClosingUtterance {
        /// The utterance as it was closed.
        let utterance: OpenUtterance
        /// The range it was closed at.
        let range: LiveSampleRange
        /// The handle of the resolver task, so it can let it go when the
        /// text is delivered.
        let resolverHandle: UUID
    }

    /// A candidate request and the result that will come back for it.
    private struct Candidate {
        /// Tells the candidate apart from the others of the same utterance.
        let id: Int
        /// The request that was sent.
        let request: RequestRecord
        /// The end of the last speech frame when the request went out. The
        /// request's range ends with the tail, which a resumed speech can fall
        /// into; this is where the words really ended.
        let speechEnd: Int
        /// The request in flight.
        let task: Task<String?, Never>
        /// The text, once it came back.
        var text: String?
    }

    /// A one-shot slot: the first writer wins and the others are ignored, so a
    /// waiting request is resumed exactly once.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var isTaken = false

        func take() -> Bool {
            lock.withLock { () -> Bool in
                guard !isTaken else { return false }
                isTaken = true
                return true
            }
        }
    }

    /// A wait that a cancellation ends at once.
    ///
    /// The first writer wins: the wait is resumed exactly once, whoever gets
    /// there first — the task, the deadline or the cancellation.
    private final class WaitSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private var isResolved = false

        /// Remembers the continuation. A wait that was cancelled before it
        /// began ends at once.
        func setContinuation(_ continuation: CheckedContinuation<String?, Never>) {
            let isAlreadyResolved: Bool = lock.withLock {
                guard !isResolved else { return true }
                self.continuation = continuation
                return false
            }
            if isAlreadyResolved { continuation.resume(returning: nil) }
        }

        /// Ends the wait.
        func resume(_ text: String?) {
            let pending: CheckedContinuation<String?, Never>? = lock.withLock {
                guard !isResolved else { return nil }
                isResolved = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: text)
        }
    }
}
