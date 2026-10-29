import Foundation

/// The live transcript: the lines of the meeting as they are said.
///
/// The `.them` side arrives out of order — a candidate that waited for the
/// engine comes back after a later utterance — so the lines are ordered by
/// their start, not by their arrival.
///
/// Every line's text passes the same two filters as the rest of the meeting:
/// the gate drops the decoder's artifacts, and the glossary repairs the names
/// it mangled. The user's own side is checked against the other side's
/// lines: the microphone hears the speakers, and a copy of their words is not
/// the user speaking.
actor LiveMeetingTranscript {

    // MARK: - The rules

    /// The newest characters of the transcript the model sees.
    static let windowCharacters = 4_000
    /// The characters beyond the window that start a memo call.
    static let memoFoldCharacters = 2_000
    /// The divider before the lines that came after the last answer.
    static let newSinceLastAnswerDivider = "[NEW SINCE LAST ANSWER]"

    // MARK: - What it stores

    /// One line of the transcript.
    struct Line: Equatable, Sendable {
        /// Which side said it.
        enum Speaker: String, Equatable, Sendable {
            /// The user.
            case me
            /// The other side.
            case them
        }

        let speaker: Speaker
        var text: String
        /// The first sample of the line on its stream's timeline.
        let startSample: Int
        /// The sample after the last one of the line.
        var endSample: Int
        /// True once the line is folded into the memo.
        var isFolded = false
        /// The parts of the line, each with the time it was said at.
        ///
        /// A continuation is one line for the eyes and for the ask — and
        /// several parts for the echo check: the echo of the second part is
        /// timed by the second part, not by the start of the joined line
        /// (§3.4).
        var parts: [Part] = []
    }

    /// One piece of the user's own side: a sentence with the time it was
    /// said at.
    struct Part: Equatable, Sendable {
        let text: String
        let startSample: Int
        let endSample: Int
    }

    /// Folds the lines that fell out of the window into a rolling memo. The
    /// LLM implementation comes later; the tests use a fake.
    ///
    /// The token is the one of the session the fold belongs to, and it
    /// travels with the fold: the routes hold no session state of their own,
    /// and a fold of a meeting that is over never reaches the model (§6.15).
    typealias MemoProvider = @Sendable (String?, [Line], LiveHintsStopToken) async -> String?

    // MARK: - The state

    /// The lines, oldest first.
    private(set) var lines: [Line] = []
    /// The rolling memo of the lines that fell out of the window.
    private(set) var memo: String?
    /// The end of the newest line when the last answer was shown.
    private(set) var answeredEndSample: Int?

    private let memoProvider: MemoProvider?
    /// Repairs the names the decoder mangled. The app's glossary by default.
    private let corrections: @Sendable (String) -> String
    /// The cancellation of the session this transcript belongs to.
    ///
    /// The fold asks the model only while the session runs: a summary that
    /// was on its way when the meeting ended never leaves the app (§6.15).
    private let stopToken: LiveHintsStopToken

    /// The fold that is running.
    private var foldTask: Task<Void, Never>?
    /// True when another fold is due while one is running.
    private var isFoldNeeded = false
    /// True when the meeting is over: the transcript folds nothing more and
    /// keeps nothing that comes back (§6.15).
    private var isStopped = false

    // MARK: - Setting it up

    init(memoProvider: MemoProvider? = nil,
         corrections: @escaping @Sendable (String) -> String = { BrandGlossary.applyCorrections($0) },
         stopToken: LiveHintsStopToken = LiveHintsStopToken()) {
        self.memoProvider = memoProvider
        self.corrections = corrections
        self.stopToken = stopToken
    }

    // MARK: - The lines

    /// A line of the other side.
    ///
    /// A line that continues the one before it is joined to it: the joined
    /// text is the line (§3.4). The parts keep their own times, so the echo
    /// of the second part is timed by the second part.
    ///
    /// The line it made is given back — nil when the gate dropped the text.
    /// The caller acts on a real line and on nothing else: a transcription
    /// that was rejected must not bring the line before it back to life.
    @discardableResult
    func appendThem(text: String,
                    startSample: Int,
                    endSample: Int,
                    rms: Float,
                    isContinuation: Bool) async -> Line? {
        guard let kept = await keptText(text, rms: rms) else { return nil }

        if isContinuation, let previous = lastThemLineIndex() {
            lines[previous].text = lines[previous].text + " " + kept
            lines[previous].endSample = max(lines[previous].endSample, endSample)
            lines[previous].parts.append(Part(text: kept,
                                              startSample: startSample,
                                              endSample: endSample))
            foldIfNeeded()
            return lines[previous]
        }

        let line = Line(speaker: .them,
                        text: kept,
                        startSample: startSample,
                        endSample: endSample,
                        parts: [Part(text: kept,
                                     startSample: startSample,
                                     endSample: endSample)])
        lines.append(line)
        sortLines()
        foldIfNeeded()
        return line
    }

    /// The user's own side: the sentences of a batch, each with its time.
    ///
    /// The lines it added are given back: the session keeps them for the
    /// advice it sends every thirty seconds.
    @discardableResult
    func appendMe(parts: [Part], rms: Float) async -> [Line] {
        var kept: [Part] = []
        for part in parts {
            guard let text = await keptText(part.text, rms: rms) else { continue }
            kept.append(Part(text: text,
                             startSample: part.startSample,
                             endSample: part.endSample))
        }
        guard !kept.isEmpty else { return [] }

        var added: [Line] = []
        for part in withoutEcho(kept) {
            let line = Line(speaker: .me,
                            text: part.text,
                            startSample: part.startSample,
                            endSample: part.endSample,
                            parts: [part])
            lines.append(line)
            added.append(line)
        }
        sortLines()
        foldIfNeeded()
        return added
    }

    // MARK: - The render

    /// The transcript as the model sees it: "Me: …" / "Them: …", the newest
    /// last, the oldest whole lines dropped when it does not fit.
    func render(maxChars: Int) -> String {
        var kept = newestLinesThatFit(maxChars: maxChars)
        var text = assemble(kept, dividerAt: dividerIndex(in: kept))
        while text.count > maxChars, kept.count > 1 {
            kept.removeFirst()
            text = assemble(kept, dividerAt: dividerIndex(in: kept))
        }
        return text
    }

    /// Records where the answer was given, so the next render can show what
    /// came after it.
    ///
    /// The boundary is the end of the transcript the answer used — the one
    /// the request was built from. The lines that came in while the answer
    /// was on its way are after it: they belong to the next answer, and the
    /// divider goes before them.
    func markAnswered(boundary: Int? = nil) {
        answeredEndSample = boundary ?? lines.map(\.endSample).max()
        foldIfNeeded()
    }

    /// The transcript as the model sees it: the rendered lines, oldest first,
    /// and the place the divider goes — the first line that came after the
    /// last answer.
    ///
    /// The answer service builds its user message from these lines and puts
    /// the divider where this says, so the two never drift apart. The
    /// boundary is the end of the transcript as it is now: the answer marks
    /// it when it is published.
    func renderedLines() -> (lines: [String], answeredIndex: Int?, boundary: Int?) {
        let rendered = lines.map { Self.renderedLine($0) }
        let index = answeredEndSample.flatMap { answered in
            lines.firstIndex { $0.startSample >= answered }
        }
        return (rendered, index, lines.map(\.endSample).max())
    }

    /// The newest lines that fit in `maxChars`, oldest first.
    private func newestLinesThatFit(maxChars: Int) -> [Int] {
        var kept: [Int] = []
        var total = 0
        for index in lines.indices.reversed() {
            let length = Self.renderedLine(lines[index]).count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty && total + length > maxChars { break }
            kept.append(index)
            total += length
        }
        kept.reverse()
        return kept
    }

    /// Where the divider goes: before the first line that came after the last
    /// answer.
    private func dividerIndex(in kept: [Int]) -> Int? {
        guard let answeredEndSample else { return nil }
        return kept.firstIndex { lines[$0].startSample >= answeredEndSample }
    }

    /// The lines as they are shown.
    private func assemble(_ kept: [Int], dividerAt: Int?) -> String {
        var parts: [String] = []
        for (position, index) in kept.enumerated() {
            if let dividerAt, position == dividerAt {
                parts.append(Self.newSinceLastAnswerDivider)
            }
            parts.append(Self.renderedLine(lines[index]))
        }
        return parts.joined(separator: "\n")
    }

    /// One line as it is shown.
    ///
    /// The answer service shows the same two labels, so the format lives here
    /// and not in two places.
    static func renderedLine(_ line: Line) -> String {
        "\(line.speaker == .me ? "Me" : "Them"): \(line.text)"
    }

    // MARK: - The memo

    /// The meeting is over: the fold that is running is dropped, and no new
    /// one starts (§6.15).
    func stop() {
        isStopped = true
        foldTask?.cancel()
        foldTask = nil
    }

    /// Folds the lines that fell out of the window into the rolling memo.
    ///
    /// The call is in the background: the meeting does not wait for a summary
    /// to be written. And it never runs ahead of an answer — the answer path
    /// has the meeting's attention first.
    ///
    /// One fold at a time: the fold that runs takes the lines it needs, and
    /// the next one waits for it. Two folds at once would build on the same
    /// memo, and the one that came back last would throw the other's away.
    private func foldIfNeeded() {
        guard !isStopped else { return }
        guard let memoProvider else { return }
        guard answeredEndSample != nil else { return }
        guard foldTask == nil else {
            // A fold is running: another one is due when it is done.
            isFoldNeeded = true
            return
        }

        // The window: the newest characters the transcript keeps. The lines
        // that fall out of it are the ones the memo takes.
        var accumulated = 0
        var firstBeyond = 0
        for index in lines.indices.reversed() {
            accumulated += Self.renderedLine(lines[index]).count
            if accumulated >= Self.windowCharacters {
                firstBeyond = index
                break
            }
        }

        let foldable = lines[0..<firstBeyond].filter { !$0.isFolded }
        let characters = foldable.reduce(0) { $0 + Self.renderedLine($1).count }
        guard characters >= Self.memoFoldCharacters else { return }

        let toFold = Array(foldable)
        let previousMemo = memo
        let token = stopToken
        let task = Task.detached { [weak self] in
            // The meeting may have ended while the fold was on its way: the
            // summary never leaves the app (§6.15). The token of the fold
            // travels with it — the provider asks the model with it and with
            // no other one.
            guard !token.isCancelled else { return }
            let folded = await memoProvider(previousMemo, toFold, token)
            await self?.finishFold(folded, lines: toFold)
        }
        foldTask = task
        // The fold belongs to the session: it ends with it (§6.15).
        stopToken.retain(task)
    }

    /// The fold came back: the memo it brought is kept, and the lines it took
    /// are folded now — not before. A fold that failed leaves its lines
    /// eligible: they are folded with the next one.
    private func finishFold(_ folded: String?, lines foldedLines: [Line]) {
        guard !isStopped else {
            foldTask = nil
            return
        }
        if let folded, !folded.isEmpty {
            memo = folded
            markFolded(foldedLines)
            foldTask = nil
            // Another fold was due while this one ran.
            if isFoldNeeded {
                isFoldNeeded = false
                foldIfNeeded()
            }
            return
        }
        // The fold failed: the lines it took are still eligible, and the
        // next fold — with the next line or the next answer — takes them.
        foldTask = nil
        isFoldNeeded = false
    }

    /// Marks the lines that were folded: they are not folded again.
    ///
    /// The lines are found by what they are, not by where they were: the
    /// lines that came in while the fold ran changed the order of the
    /// transcript.
    private func markFolded(_ foldedLines: [Line]) {
        for folded in foldedLines {
            for index in lines.indices
            where lines[index].speaker == folded.speaker
                && lines[index].startSample == folded.startSample
                && lines[index].text == folded.text
                && !lines[index].isFolded {
                lines[index].isFolded = true
            }
        }
    }

    // MARK: - The filters

    /// The text that survives the gate, with the brand names repaired.
    private func keptText(_ text: String, rms: Float) async -> String? {
        let decision = await MainActor.run { MeetingChunkTextGate.decide(text: text, rms: rms) }
        guard case .keep(let kept) = decision else { return nil }
        return corrections(kept)
    }

    /// The parts that are not the other side's words coming back through the
    /// microphone.
    ///
    /// The other side's side of the comparison is made of the parts of its
    /// lines, each with its own time: a continuation is one line, but the
    /// echo of its second part is timed by that part (§3.4).
    private func withoutEcho(_ parts: [Part]) -> [Part] {
        let themLines = lines.filter { $0.speaker == .them }
        guard !themLines.isEmpty else { return parts }

        let themSegments = themLines.flatMap { line -> [StreamSegment] in
            let lineParts = line.parts.isEmpty
                ? [Part(text: line.text, startSample: line.startSample, endSample: line.endSample)]
                : line.parts
            return lineParts.map { part in
                StreamSegment(text: part.text,
                              startSec: Self.seconds(part.startSample),
                              endSec: Self.seconds(part.endSample),
                              speaker: .them)
            }
        }
        let meSegments = parts.map { part in
            StreamSegment(text: part.text,
                          startSec: Self.seconds(part.startSample),
                          endSec: Self.seconds(part.endSample),
                          speaker: .me)
        }
        var dropped: [MeetingTranscriptSanitizer.Drop] = []
        let kept = MeetingTranscriptSanitizer.dedupeCrossChannelEcho(meSegments + themSegments,
                                                                    dropped: &dropped)
        // The sanitizer keeps the `.me` segments in their own order, so the
        // ones it kept are the parts it did not drop.
        let keptTexts = kept.filter { $0.speaker == .me }.map(\.text)
        var index = 0
        return parts.filter { part in
            guard index < keptTexts.count, keptTexts[index] == part.text else { return false }
            index += 1
            return true
        }
    }

    // MARK: - The order

    /// The newest `.them` line — the one a continuation is joined to.
    private func lastThemLineIndex() -> Int? {
        for index in lines.indices.reversed() where lines[index].speaker == .them {
            return index
        }
        return nil
    }

    /// The lines in the order they were said. Lines that start at the same
    /// sample keep their arrival order.
    private func sortLines() {
        lines = lines.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startSample != rhs.element.startSample {
                    return lhs.element.startSample < rhs.element.startSample
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// A sample on its stream's timeline, in seconds.
    private static func seconds(_ sample: Int) -> Double {
        Double(sample) / Double(SpeechActivity.sampleRate)
    }
}
