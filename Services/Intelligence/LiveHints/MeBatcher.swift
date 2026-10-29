import Foundation

/// The user's own side, batched.
///
/// The user's words are not asked for while they are being spoken: the engine
/// would have to decode a growing clip again and again, and every request is
/// billed at the server's ten-second minimum. Instead the finished utterances
/// are joined — each followed by half a second of silence — and the batch goes
/// out when it holds 20 s of speech, when the owner asks for it, or when the
/// oldest utterance is 45 s old. One batch holds at most 25 s of audio.
///
/// The batch keeps its layout: every utterance's own range and where it sits
/// inside the clip, so the sentences that come back can be given the time
/// they were said at.
actor MeBatcher {

    // MARK: - The rules

    /// The silence between two utterances of a batch: half a second.
    static let separatorSamples = 8_000
    /// The speech a batch holds before it goes out: 20 s.
    static let speechFlushSamples = 320_000
    /// The most a batch may hold: 25 s.
    static let maximumBatchSamples = 400_000
    /// The age of the oldest utterance that sends the batch out: 45 s.
    static let maximumAgeSamples = 720_000
    /// How often the batcher looks at the age of the waiting batch.
    static let agePoll: TimeInterval = 0.5
    /// The characters that end a sentence, in either script.
    static let terminators: Set<Character> = [".", "?", "!", "…", "？", "。", "！"]

    // MARK: - What it reports

    /// A finished utterance of the user's own side: a sample range, no text.
    struct Utterance: Equatable, Sendable {
        let startSample: Int
        let endSample: Int

        /// How many samples it holds.
        var count: Int { endSample - startSample }
    }

    /// One sentence of a batch, with the time it was said at.
    struct Sentence: Equatable, Sendable {
        let text: String
        /// The start on the mic's timeline.
        let startSample: Int
        /// The end on the mic's timeline.
        let endSample: Int
    }

    /// Where an utterance sits inside a batch.
    struct Placement: Equatable, Sendable {
        /// The utterance's own range on the mic's timeline.
        let utterance: Utterance
        /// Where the utterance starts inside the batch's audio.
        let offset: Int
    }

    /// A batch that was sent.
    struct Batch: Equatable, Sendable {
        /// Every utterance of the batch, in order, with its place in the clip.
        let placements: [Placement]
        /// The sentences that came back, with the time of their utterance.
        let sentences: [Sentence]
        /// How many samples the batch's audio holds.
        let sampleCount: Int
        /// The level of the batch's audio — the gate reads it to tell a quiet
        /// channel from a loud one.
        let rms: Float
    }

    // MARK: - The state

    private let audioSource: LiveAudioSource
    private let transcriber: LiveEngineTranscriber
    /// The dictation pause windows, read when an utterance arrives.
    private let pauseWindows: @Sendable () async -> [LiveSampleRange]
    /// Where the mic's stream is now, on its own sample timeline.
    private let streamClock: @Sendable () async -> Int

    /// The cancellation of the session this batcher belongs to.
    ///
    /// The batcher asks the engine only while the session runs: a batch that
    /// was on its way when the meeting ended never leaves the app (§6.15).
    private let stopToken: LiveHintsStopToken

    /// The utterances waiting for their batch.
    private var pending: [Utterance] = []
    /// Called for every batch that was sent.
    private var handler: (@Sendable (Batch) -> Void)?
    /// The task that watches the age of the waiting batch.
    private var ageTask: Task<Void, Never>?
    /// The last append that was given to the batcher: the appends wait for
    /// each other, so the utterances keep the order they arrived in (§3.2).
    private var appendTail: AppendTail?
    /// True when the meeting is over: the batcher keeps nothing (§6.15).
    private var isStopped = false

    // MARK: - Setting it up

    init(audioSource: LiveAudioSource,
         transcriber: LiveEngineTranscriber,
         pauseWindows: @escaping @Sendable () async -> [LiveSampleRange],
         streamClock: @escaping @Sendable () async -> Int,
         stopToken: LiveHintsStopToken = LiveHintsStopToken()) {
        self.audioSource = audioSource
        self.transcriber = transcriber
        self.pauseWindows = pauseWindows
        self.streamClock = streamClock
        self.stopToken = stopToken
    }

    /// Called for every batch that was sent. Set it before the first
    /// utterance arrives.
    func setHandler(_ handler: @escaping @Sendable (Batch) -> Void) {
        self.handler = handler
        startAgeWatch()
    }

    /// The meeting is over: the utterances that wait for their batch go away,
    /// and the batch in flight brings nothing back (§6.15).
    ///
    /// The batcher stops its own work only. The token belongs to the
    /// session: the other side of the meeting shares it, and the session is
    /// the one that stops it.
    func stop() {
        isStopped = true
        ageTask?.cancel()
        ageTask = nil
        pending = []
    }

    /// The utterances waiting for their batch.
    var pendingCount: Int { pending.count }

    // MARK: - The utterances

    /// Takes a finished utterance of the user's own side.
    ///
    /// The appends are one after another: an append that waits for the
    /// transcription of its batch must not let a later utterance land before
    /// it. The clip would hold the words in the wrong order, and the age of
    /// the batch would be read off the wrong utterance (§3.2).
    func append(_ utterance: Utterance) async {
        let previous = appendTail
        let current = Task.detached { [weak self] in
            _ = await previous?.task.value
            await self?.appendNow(utterance)
        }
        // The append belongs to the session: it ends with it (§6.15).
        stopToken.retain(current)
        let tail = AppendTail(task: current)
        appendTail = tail
        await current.value
        // The queue is empty when nothing came after this append.
        if appendTail === tail { appendTail = nil }
    }

    /// The append itself: the checks, the batch and the sending.
    private func appendNow(_ utterance: Utterance) async {
        guard !isStopped else { return }
        // The dictation pause: the user's own words during a pause are not
        // part of the meeting.
        if await overlapsPause(utterance) {
            NSLog("[LiveHints] .me utterance dropped — it is inside a dictation pause")
            return
        }
        // The oldest utterance waited long enough: it cannot stay in the
        // batch any longer.
        if !pending.isEmpty {
            let now = await streamClock()
            if let oldest = pending.first, now - oldest.startSample >= Self.maximumAgeSamples {
                await send()
            }
        }

        // One batch holds at most 25 s of audio: an utterance that does not
        // fit sends the batch out first. An utterance that does not fit on
        // its own is split before the batch is built (§3.2).
        for piece in Self.split(utterance) {
            if !pending.isEmpty,
               audioLength(pending) + piece.count + Self.separatorSamples > Self.maximumBatchSamples {
                await send()
            }

            pending.append(piece)

            // 20 s of speech: the batch goes out.
            if speechLength(pending) >= Self.speechFlushSamples {
                await send()
            }
        }
    }

    /// The pieces an utterance is split into: every piece fits into a batch
    /// of its own, with the silence that follows it.
    ///
    /// The tracker lets an utterance grow to nearly 30 s, and a batch holds
    /// at most 25 s of audio. The words of a long utterance are not lost —
    /// they go out in two batches.
    static func split(_ utterance: Utterance) -> [Utterance] {
        let limit = maximumBatchSamples - separatorSamples
        guard utterance.count > limit else { return [utterance] }
        var pieces: [Utterance] = []
        var start = utterance.startSample
        while start < utterance.endSample {
            let end = min(start + limit, utterance.endSample)
            pieces.append(Utterance(startSample: start, endSample: end))
            start = end
        }
        return pieces
    }

    /// Sends the batch that is waiting — the owner's shortcut.
    func flush() async {
        await send()
    }

    // MARK: - Sending

    /// Watches the age of the waiting batch.
    ///
    /// The age is a rule of the batcher, so the batcher keeps it: a batch
    /// that waited 45 s goes out on its own, whether another utterance
    /// arrives or not (§3.2). The check during `append()` alone would keep
    /// the words of the user waiting for the next thing that happens.
    private func startAgeWatch() {
        guard ageTask == nil else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.agePoll * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.sendIfAged()
            }
        }
        ageTask = task
        // The watcher belongs to the session: it ends with it (§6.15).
        stopToken.retain(task)
    }

    /// Sends the batch when the oldest utterance waited long enough.
    private func sendIfAged() async {
        guard !isStopped, !pending.isEmpty else { return }
        let now = await streamClock()
        guard let oldest = pending.first,
              now - oldest.startSample >= Self.maximumAgeSamples else { return }
        await send()
    }

    /// Sends the batch that is waiting and transcribes it.
    private func send() async {
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        // The meeting may be over: the batch never leaves the app (§6.15).
        guard !stopToken.isCancelled else { return }
        await transcribe(batch)
    }

    /// Transcribes the batch and reports the sentences with their times.
    private func transcribe(_ batch: [Utterance]) async {
        let layout = await makeLayout(batch)
        // The check stands right before the call: the meeting may have ended
        // while the audio was fetched (§6.15).
        guard !stopToken.isCancelled else { return }
        let outcome = await transcriber.call(samples: layout.samples, stream: .me)
        switch outcome {
        case .text(let result):
            // The meeting may have ended while the batch was on its way.
            guard !isStopped else { return }
            let sentences = Self.sentences(result, layout: layout)
            handler?(Batch(placements: layout.placements,
                           sentences: sentences,
                           sampleCount: layout.samples.count,
                           rms: SpeechActivity.rootMeanSquare(layout.samples)))
        case .timeout:
            NSLog("[LiveHints] .me batch timed out — its text is dropped")
        case .cancelled:
            NSLog("[LiveHints] .me batch was cancelled — its text is dropped")
        case .failed(let error):
            NSLog("[LiveHints] .me batch failed: %@", "\(error)")
        }
    }

    // MARK: - The layout

    /// Where every utterance of the batch sits inside its audio.
    struct Layout {
        let placements: [Placement]
        let samples: [Float]

        /// The utterance a moment of the batch's audio came from. A moment
        /// outside every utterance — the silence between two of them — belongs
        /// to the utterance before it.
        func placement(at seconds: TimeInterval) -> Placement? {
            let offset = Int(seconds * Double(SpeechActivity.sampleRate))
            for placement in placements {
                if offset >= placement.offset && offset < placement.offset + placement.utterance.count {
                    return placement
                }
            }
            return placements.last { $0.offset <= offset } ?? placements.first
        }
    }

    /// The audio of the batch: the utterances, each followed by half a second
    /// of silence.
    private func makeLayout(_ batch: [Utterance]) async -> Layout {
        var samples: [Float] = []
        var placements: [Placement] = []
        for utterance in batch {
            placements.append(Placement(utterance: utterance, offset: samples.count))
            samples.append(contentsOf: await audioSource.samples(from: utterance.startSample,
                                                                  count: utterance.count))
            samples.append(contentsOf: [Float](repeating: 0, count: Self.separatorSamples))
        }
        return Layout(placements: placements, samples: samples)
    }

    /// The sentences of a batch, each with the time of the utterance it came
    /// from.
    ///
    /// The engine's segment times are times inside the batch's audio, so they
    /// are mapped back through the layout: a sentence takes the start of the
    /// utterance it was spoken in. An engine that returns no segment times
    /// gives every sentence the start of the batch's first utterance — the
    /// echo of a late sentence may then be missed. That is accepted.
    static func sentences(_ result: TranscriptionResult, layout: Layout) -> [Sentence] {
        guard !result.segments.isEmpty else {
            let first = layout.placements.first?.utterance
            let start = first?.startSample ?? 0
            let end = first?.endSample ?? start
            return splitSentences(result.text).map {
                Sentence(text: $0, startSample: start, endSample: end)
            }
        }

        var sentences: [Sentence] = []
        for segment in result.segments {
            guard let placement = layout.placement(at: segment.start) else { continue }
            for text in splitSentences(segment.text) {
                sentences.append(Sentence(text: text,
                                          startSample: placement.utterance.startSample,
                                          endSample: placement.utterance.endSample))
            }
        }
        return sentences
    }

    /// Splits a text into sentences.
    ///
    /// The terminator stays with its sentence, a run of terminators ("?!",
    /// "...") belongs to one sentence, and a terminator that is not followed
    /// by a space is left alone — the version 3.14 is not two sentences.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            index = text.index(after: index)
            guard terminators.contains(character) else { continue }

            while index < text.endIndex, terminators.contains(text[index]) {
                current.append(text[index])
                index = text.index(after: index)
            }
            if index < text.endIndex, !text[index].isWhitespace { continue }

            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    // MARK: - The arithmetic

    /// The tail of the queue of appends: the last append that was given to
    /// the batcher. The next append waits for it.
    private final class AppendTail: @unchecked Sendable {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    /// How many samples the speech of the utterances holds.
    private func speechLength(_ batch: [Utterance]) -> Int {
        batch.reduce(0) { $0 + $1.count }
    }

    /// How many samples the audio of the utterances holds, with the silence
    /// between them.
    private func audioLength(_ batch: [Utterance]) -> Int {
        batch.reduce(0) { $0 + $1.count + Self.separatorSamples }
    }

    /// True when the utterance falls inside a dictation pause.
    private func overlapsPause(_ utterance: Utterance) async -> Bool {
        for window in await pauseWindows() {
            if utterance.startSample < window.to && window.from < utterance.endSample {
                return true
            }
        }
        return false
    }
}
