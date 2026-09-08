import XCTest
@testable import MetaWhisp

/// The fold itself, with the transport faked. Until now the map-reduce lived
/// inside `LocalLLMService` and could only run against a loaded model, so the
/// Pro path grew its own (missing) answer for a long transcript: it sent the
/// whole thing and the proxy replied 400 (`Prompt too long (47178 chars, max
/// 32000)`, 2026-09-04). One fold, two transports, and these tests hold it.
final class ChunkedCompletionTests: XCTestCase {

    /// Every prompt handed to the transport, in order, as (system, user).
    private actor Recorder {
        private(set) var calls: [(system: String, user: String)] = []
        func note(_ system: String, _ user: String) { calls.append((system, user)) }
        var all: [(system: String, user: String)] { calls }
    }

    private func text(sentences: Int, each: Int = 100) -> String {
        (0..<sentences).map { i in String(repeating: "\(i % 10)", count: each - 2) + ". " }.joined()
    }

    // MARK: - The invariant this bug was about

    /// No prompt the transport ever sees exceeds the limit — that is the whole
    /// point of chunking, and the thing the Pro path lacked.
    func testNoPromptEverExceedsTheLimit() async throws {
        let rec = Recorder()
        let long = text(sentences: 400)              // ~40 000 chars
        _ = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 10_000) { sys, usr, _ in
            await rec.note(sys, usr)
            return String(usr.prefix(200))           // a shrinking summariser
        }
        let calls = await rec.all
        XCTAssertFalse(calls.isEmpty)
        for call in calls {
            XCTAssertLessThanOrEqual(call.user.count, 10_000, "a chunk was sent over the limit")
        }
    }

    /// Under the limit nothing is chunked: one call, the text untouched, and
    /// the transport is told it is a whole text — not "part 1 of 1".
    func testShortInputIsOneCallAndIsNotAnnouncedAsAPart() async throws {
        let rec = Recorder()
        var passes: [ChunkedCompletion.Pass] = []
        let out = try await ChunkedCompletion.run(system: "S", user: "  Hello. World.  ", chunkChars: 1000) { sys, usr, pass in
            await rec.note(sys, usr); passes.append(pass)
            return "done"
        }
        let calls = await rec.all
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].user, "Hello. World.", "trimmed, not chunked")
        XCTAssertEqual(calls[0].system, "S", "no part note on a whole text")
        XCTAssertEqual(passes, [.whole])
        XCTAssertEqual(out, "done")
    }

    // MARK: - Synthesis (the action plan): map, fold, reduce

    func testSynthesisMapsEveryChunkThenReducesTheJoinedPartials() async throws {
        let rec = Recorder()
        let long = text(sentences: 60)               // ~6 000 chars → 3 chunks at 2 000
        let out = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 2_000) { _, usr, pass in
            await rec.note("", usr)
            switch pass {
            case .map, .transform: return "partial(\(usr.prefix(1)))"
            case .reduce, .whole: return "REDUCED[\(usr)]"
            }
        }
        let calls = await rec.all
        XCTAssertGreaterThanOrEqual(calls.count, 4, "three maps and a reduce at least")
        XCTAssertTrue(out.hasPrefix("REDUCED["), "the answer is the reduce, not a partial")
        XCTAssertTrue(out.contains("partial("), "the reduce sees the partials")
    }

    /// The map pass says which part it is — ported verbatim from the local
    /// path, so both transports phrase it identically.
    func testTheMapPassTellsTheModelWhichPartItIs() async throws {
        let rec = Recorder()
        let long = text(sentences: 60)
        _ = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 2_000) { sys, usr, _ in
            await rec.note(sys, usr)
            return "p"
        }
        let calls = await rec.all
        XCTAssertTrue(calls[0].system.contains("part 1 of 3"), "got: \(calls[0].system)")
        XCTAssertTrue(calls[0].system.hasPrefix("S"), "the caller's system prompt stays first")
    }

    // MARK: - Transform (cleanup, translation): one round, joined in order

    func testConcatModeJoinsPartialsInOrderWithoutAReduce() async throws {
        let long = text(sentences: 60)
        var passes: [ChunkedCompletion.Pass] = []
        let out = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 2_000,
                                                  concatPartials: true) { _, usr, pass in
            passes.append(pass)
            return "[\(usr.prefix(1))]"
        }
        XCTAssertFalse(passes.contains(.reduce), "a transform must not re-process its own output")
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, passes.count)
        XCTAssertTrue(out.hasPrefix("[0]"), "partials keep their order")
        // The regression this caught: a transform pass announced as a plain
        // map let the local path cap its output at 512 tokens, cutting every
        // cleaned-up chunk to a third (independent review, 2026-09-04).
        XCTAssertEqual(passes, (1...passes.count).map { .transform(part: $0, of: passes.count) })
    }

    /// The synthesis fold keeps announcing map passes — the caller caps those
    /// tightly on purpose, and must go on doing so.
    func testSynthesisAnnouncesMapPassesNotTransforms() async throws {
        var kinds: [ChunkedCompletion.Pass] = []
        _ = try await ChunkedCompletion.run(system: "S", user: text(sentences: 60), chunkChars: 2_000) { _, usr, pass in
            kinds.append(pass)
            return String(usr.prefix(10))
        }
        XCTAssertTrue(kinds.contains { if case .map = $0 { return true }; return false })
        XCTAssertFalse(kinds.contains { if case .transform = $0 { return true }; return false })
    }

    // MARK: - A wire limit counts UTF-16 units

    func testTheGraphemeBudgetShrinksForTextThatExpandsInUTF16() {
        XCTAssertEqual(ChunkedCompletion.graphemeBudget(for: "plain ascii", unitLimit: 30_000), 30_000)
        let emoji = String(repeating: "🙂", count: 100)          // 100 graphemes, 200 units
        XCTAssertEqual(ChunkedCompletion.graphemeBudget(for: emoji, unitLimit: 30_000), 15_000)
        XCTAssertEqual(ChunkedCompletion.graphemeBudget(for: "", unitLimit: 30_000), 30_000)
    }

    // MARK: - Failure

    /// One bad chunk must not kill the job.
    func testASingleFailedChunkIsSkipped() async throws {
        let long = text(sentences: 60)
        var seen = 0
        let out = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 2_000,
                                                  concatPartials: true) { _, _, _ in
            seen += 1
            if seen == 2 { throw NSError(domain: "T", code: 1) }
            return "ok"
        }
        XCTAssertEqual(out, "ok\n\nok", "two of three survived")
    }

    /// Every chunk failing must still say WHY — "All chunks failed" alone
    /// hides an expired licence or a rate limit (independent review).
    func testAllChunksFailingThrowsAndCarriesTheReason() async {
        let long = text(sentences: 60)
        do {
            _ = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 2_000) { _, _, _ in
                throw NSError(domain: "T", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Action-plan proxy HTTP 401 — Invalid or expired license"
                ])
            }
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("All chunks failed"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("expired license"), error.localizedDescription)
        }
    }

    /// A skipped chunk is reported, so the caller can admit the answer covers
    /// part of the text instead of passing it off as complete.
    func testASkippedChunkIsReportedToTheCaller() async throws {
        var skips: [(part: Int, of: Int)] = []
        var seen = 0
        _ = try await ChunkedCompletion.run(system: "S", user: text(sentences: 60), chunkChars: 2_000,
                                            concatPartials: true,
                                            onChunkSkipped: { part, of, _ in skips.append((part, of)) }) { _, _, _ in
            seen += 1
            if seen == 2 { throw NSError(domain: "T", code: 1) }
            return "ok"
        }
        XCTAssertEqual(skips.count, 1)
        XCTAssertEqual(skips.first?.part, 2)
        XCTAssertEqual(skips.first?.of, 3)
    }

    /// A transport that never shrinks its input must not fold forever.
    func testNonConvergenceThrowsInsteadOfLooping() async {
        let long = text(sentences: 200)
        var calls = 0
        do {
            _ = try await ChunkedCompletion.run(system: "S", user: long, chunkChars: 2_000) { _, usr, _ in
                calls += 1
                return usr                              // shrinks nothing
            }
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not converge"), error.localizedDescription)
            XCTAssertLessThan(calls, 100, "bounded by the round limit")
        }
    }
    // MARK: - A skipped chunk cannot be ignored

    /// The local path called `run` without `onChunkSkipped` and returned the
    /// partial result as if it were complete — the Pro path refuses to do
    /// that, and the difference was invisible (audit, 2026-09-06, P1). The
    /// fold now hands back what it skipped along with the text, so a caller
    /// has to look at it.
    func testTheFoldReportsWhatItSkippedAlongsideTheText() async throws {
        var seen = 0
        let folded = try await ChunkedCompletion.fold(
            system: "S", user: text(sentences: 60), chunkChars: 2_000, concatPartials: true
        ) { _, _, _ in
            seen += 1
            if seen == 2 { throw NSError(domain: "T", code: 1) }
            return "ok"
        }
        XCTAssertEqual(folded.text, "ok\n\nok")
        XCTAssertEqual(folded.skipped, 1)
        XCTAssertEqual(folded.outOf, 3, "and it says which round it was lost from")
        XCTAssertTrue(folded.isPartial, "one of three chunks is missing — this is not a complete answer")
    }

    func testAFoldThatSkippedNothingIsNotPartial() async throws {
        let folded = try await ChunkedCompletion.fold(
            system: "S", user: "short one", chunkChars: 2_000
        ) { _, _, _ in "done" }
        XCTAssertEqual(folded.text, "done")
        XCTAssertEqual(folded.skipped, 0)
        XCTAssertNil(folded.outOf, "nothing was lost, so there is no round to name")
        XCTAssertFalse(folded.isPartial)
    }
}
