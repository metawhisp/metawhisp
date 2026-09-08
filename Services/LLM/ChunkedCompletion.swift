import Foundation

/// Folding a long text through a model that can only take so much at once —
/// with the transport left out. The local model and the Pro proxy differ in
/// how they complete ONE prompt, not in how a long transcript is folded, and
/// while this lived inside `LocalLLMService` the Pro path had no answer at
/// all: it sent an 87-minute transcript whole and the proxy replied
/// `Prompt too long (47178 chars, max 32000)` — HTTP 400, no plan, and the
/// app showed only the status code (2026-09-04).
///
/// The algorithm is ITER-051 F1.2's, moved here unchanged so the two paths
/// cannot drift apart.
enum ChunkedCompletion {

    /// What the transport is being asked for. The caller uses it to size its
    /// own output cap: a map pass is a note to itself, a reduce is the answer.
    enum Pass: Equatable {
        /// The text fitted in one prompt — no chunking happened.
        case whole
        /// One chunk of a SYNTHESIS job: a note to self, folded later, so the
        /// caller may cap its output tightly.
        case map(part: Int, of: Int)
        /// One chunk of a TRANSFORM job: this output IS part of the answer and
        /// must not be capped tighter than a whole prompt would be — capping
        /// it truncated dictation cleanup and translation to a third of each
        /// chunk (independent review, 2026-09-04).
        case transform(part: Int, of: Int)
        case reduce
    }

    /// Fold rounds before giving up. A transport that never shrinks its input
    /// must not loop forever.
    static let maxRounds = 4

    /// - Parameters:
    ///   - chunkChars: the most the transport can take in one `user` prompt.
    ///   - concatPartials: `false` (default) — map-reduce for SYNTHESIS tasks
    ///     (action plan, summary): map each chunk, fold, final reduce pass.
    ///     `true` — map-and-JOIN for TRANSFORM tasks (cleanup, translation)
    ///     where the output IS the processed text: one map round, partials
    ///     joined in order, no reduce (re-processing already-processed text
    ///     degrades it).
    ///   - onChunkSkipped: told when a chunk failed and was left out, so the
    ///     caller can say so instead of handing over a quietly partial answer.
    ///   - complete: completes one prompt. Throwing is survivable for a map
    ///     pass — one bad chunk must not kill the job.
    /// The fold's answer, and what it cost. A caller cannot take the text
    /// without being handed the count of what was left out — the local path
    /// called `run` with no `onChunkSkipped` and returned a partial answer as
    /// if it were whole (audit, 2026-09-06, P1).
    struct Folded: Equatable {
        let text: String
        /// Chunks that failed and were left out of the answer.
        let skipped: Int
        /// The part count of the round a chunk was lost in — `nil` when
        /// nothing was lost, because there is then no round to name.
        let outOf: Int?
        var isPartial: Bool { skipped > 0 }
    }

    /// Fold, and say what was left out. Prefer this to `run`.
    static func fold(
        system: String,
        user: String,
        chunkChars: Int,
        concatPartials: Bool = false,
        complete: (_ system: String, _ user: String, _ pass: Pass) async throws -> String
    ) async throws -> Folded {
        var skipped = 0
        var outOf: Int?
        let text = try await run(system: system, user: user, chunkChars: chunkChars,
                                 concatPartials: concatPartials,
                                 onChunkSkipped: { _, of, _ in skipped += 1; outOf = max(outOf ?? 0, of) },
                                 complete: complete)
        return Folded(text: text, skipped: skipped, outOf: outOf)
    }

    static func run(
        system: String,
        user: String,
        chunkChars: Int,
        concatPartials: Bool = false,
        onChunkSkipped: ((_ part: Int, _ of: Int, _ error: Error) -> Void)? = nil,
        complete: (_ system: String, _ user: String, _ pass: Pass) async throws -> String
    ) async throws -> String {
        let text = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > chunkChars else {
            return try await complete(system, text, .whole)
        }

        func mapPass(_ pieces: [String], transform: Bool) async throws -> [String] {
            var partials: [String] = []
            var lastError: Error?
            for (i, piece) in pieces.enumerated() {
                let mapSystem = system
                    + " NOTE: this is part \(i + 1) of \(pieces.count) of a longer text — process just this part."
                let pass: Pass = transform ? .transform(part: i + 1, of: pieces.count)
                                           : .map(part: i + 1, of: pieces.count)
                do {
                    partials.append(try await complete(mapSystem, piece, pass))
                } catch {
                    // One bad chunk must not kill the whole job — but the
                    // caller is told, so a partial answer is never handed over
                    // as a complete one.
                    lastError = error
                    NSLog("[ChunkedCompletion] chunk %d/%d failed (%@) — skipped",
                          i + 1, pieces.count, error.localizedDescription)
                    onChunkSkipped?(i + 1, pieces.count, error)
                }
            }
            guard !partials.isEmpty else {
                // Carry the transport's own words: "All chunks failed" alone
                // hides an expired licence or a rate limit.
                let why = lastError.map { ": " + $0.localizedDescription } ?? ""
                throw NSError(domain: "ChunkedCompletion", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "All chunks failed to process" + why
                ])
            }
            return partials
        }

        var pieces = splitBySentences(text, limit: chunkChars)
        NSLog("[ChunkedCompletion] %d chars → %d chunks of ≤%d (concat=%@)",
              text.count, pieces.count, chunkChars, concatPartials ? "yes" : "no")

        if concatPartials {
            // Transform mode: output ≈ input per chunk, single round, join.
            return try await mapPass(pieces, transform: true).joined(separator: "\n\n")
        }

        // Synthesis mode: tight map outputs → geometric fold convergence.
        var round = 0
        while pieces.count > 1 {
            round += 1
            guard round <= maxRounds else {
                throw NSError(domain: "ChunkedCompletion", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Chunked reduction did not converge."
                ])
            }
            let combined = try await mapPass(pieces, transform: false).joined(separator: "\n\n")
            NSLog("[ChunkedCompletion] round %d: %d chunks → %d chars (%@)", round, pieces.count, combined.count, combined.count <= chunkChars ? "reduce" : "fold again")
            if combined.count <= chunkChars {
                return try await complete(system, combined, .reduce)
            }
            pieces = splitBySentences(combined, limit: chunkChars)
        }
        return pieces.first ?? ""
    }

    /// A wire limit counts UTF-16 units; `String.count` counts graphemes, and
    /// text outside the Basic Multilingual Plane (emoji) takes two units per
    /// grapheme. Scale the budget by the text's own expansion, so a chunk
    /// measured in graphemes still fits a limit measured in units.
    static func graphemeBudget(for text: String, unitLimit: Int) -> Int {
        let units = text.utf16.count, graphemes = text.count
        guard units > graphemes, graphemes > 0 else { return unitLimit }
        return max(1, unitLimit * graphemes / units)
    }

    /// Greedy sentence-boundary splitter: packs sentences into chunks of at
    /// most `limit` chars, hard-splitting only a single sentence that alone
    /// exceeds the limit. Never loses characters (tested).
    nonisolated static func splitBySentences(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var chunks: [String] = []
        var buf = ""
        for s in sentences {
            if s.count > limit {
                // Degenerate single sentence — flush + hard-split.
                if !buf.isEmpty { chunks.append(buf); buf = "" }
                var rest = Substring(s)
                while rest.count > limit {
                    chunks.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
                buf = String(rest)
            } else if buf.count + s.count > limit {
                chunks.append(buf)
                buf = s
            } else {
                buf += s
            }
        }
        if !buf.isEmpty { chunks.append(buf) }
        return chunks
    }
}
