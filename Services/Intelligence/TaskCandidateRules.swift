import Foundation

/// FEAT-0005 §4 — what an automatic task suggestion must pass after the model answers.
///
/// The model reads the conversation and proposes items with a kind, the words they came from and its confidence;
/// these rules decide by structure only (no word lists in any language, I6) whether an item may become a draft.
/// Pure and off the main actor: on a long call the evidence scan is real CPU work, so the extractor runs `apply`
/// in a background task. Only `sendable` (the transcription filter's list) needs the main actor.
/// spec://intelligence/FEAT-0005#rules
enum TaskCandidateRules {

    enum Source: Equatable, Sendable { case dictation, call }

    /// FEAT-0006 §9b P7 (owner, 2026-11-26) — only the user's own items. What someone else promised the user
    /// ("waiting on <person>") is not a task: an answer of that kind is an unknown kind and is dropped.
    enum Kind: String, Equatable, Sendable {
        case mine
        case askedByUser = "asked_by_user"
    }

    /// One item of the model's answer, as parsed. Every field the model may leave out is optional.
    struct Candidate: Equatable, Sendable {
        var description: String
        var kind: String?
        var evidence: String?
        var dueAt: Date?
        var assignee: String?
        var captureConfidence: Double?
        var ownershipConfidence: Double?
        var concreteDeliverable: Bool?
        var realWorld: Bool?
    }

    /// A part of the conversation exactly as it was sent, and when it was said.
    struct Fragment: Equatable, Sendable {
        let text: String
        let at: Date
    }

    /// A row already in the store, reduced to what decides a repeat (K9).
    struct Existing: Equatable, Sendable {
        let description: String
        let assignee: String?
        /// A repeat mentioned at or before this time is absorbed; `.distantFuture` = open, absorbs every repeat.
        let resolvedAt: Date
    }

    enum DropReason: String, CaseIterable, Error, Sendable {
        case unknownKind, belowFloor, dictationNotRealWorld, evidenceNotSpoken, notTheUsersRequest,
             placeholder, vagueTitle, `repeat`
    }

    struct Kept: Equatable, Sendable {
        /// Normalized: no assignee (the user's own items name nobody), a due date more than a day past cleared.
        let candidate: Candidate
        let kind: Kind
        /// The fragment the evidence was found in.
        let fragmentIndex: Int
        let mentionedAt: Date
    }

    struct Dropped: Equatable, Sendable {
        let candidate: Candidate
        let reason: DropReason
    }

    struct Outcome: Equatable, Sendable {
        var kept: [Kept] = []
        var dropped: [Dropped] = []
    }

    /// K1 — both confidences at least this, as the reference's capture floor.
    static let confidenceFloor = 0.8
    /// R2 — evidence shorter than this many letters or digits proves nothing.
    static let minEvidenceUnits = 6
    /// K13 — a due date further in the past than this is cleared.
    static let pastDueGrace: TimeInterval = 86_400
    /// R6 — the description length the extractor always allowed.
    static let maxWords = 15

    // MARK: - The pass

    static func apply(_ candidates: [Candidate], source: Source, fragments: [Fragment],
                      existing: [Existing], now: Date) -> Outcome {
        var outcome = Outcome()
        let normalizedFragments = fragments.map { matchKey($0.text) }
        for raw in candidates {
            switch check(raw, source: source, fragments: fragments, normalizedFragments: normalizedFragments,
                         now: now) {
            case .failure(let reason):
                outcome.dropped.append(Dropped(candidate: raw, reason: reason))
            case .success(let kept):
                let earlier = outcome.kept.map { Existing(description: $0.candidate.description,
                                                          assignee: $0.candidate.assignee,
                                                          resolvedAt: .distantFuture) }
                if isRepeat(kept, of: existing + earlier) {
                    outcome.dropped.append(Dropped(candidate: raw, reason: .repeat))
                } else {
                    outcome.kept.append(kept)
                }
            }
        }
        return outcome
    }

    private static func check(_ raw: Candidate, source: Source, fragments: [Fragment],
                              normalizedFragments: [String], now: Date) -> Result<Kept, DropReason> {
        var c = raw
        c.description = raw.description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let kind = raw.kind.flatMap({ Kind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }) else {
            return .failure(.unknownKind)
        }
        // K1 — a vague or unsure item is not worth the user's attention.
        guard raw.concreteDeliverable == true,
              (raw.captureConfidence ?? 0) >= confidenceFloor,
              (raw.ownershipConfidence ?? 0) >= confidenceFloor else {
            return .failure(.belowFloor)
        }
        // R4 — a dictation is mostly instructions to AI tools: the user's own item stays only when it is real-world.
        if source == .dictation, kind == .mine, raw.realWorld != true {
            return .failure(.dictationNotRealWorld)
        }
        // R2 / K17 — the item comes from words that were spoken, in the language they were spoken in.
        let evidence = evidencePieces(raw.evidence ?? "")
        guard evidence.reduce(0, { $0 + $1.unicodeScalars.count }) >= minEvidenceUnits,
              let index = normalizedFragments.firstIndex(where: { containsInOrder(evidence, $0) }) else {
            return .failure(.evidenceNotSpoken)
        }
        // K7 — in a call, a "remind me" heard from the other side is theirs, not the user's.
        if source == .call, kind == .askedByUser, !isOnTheUsersLine(evidence, in: fragments[index].text) {
            return .failure(.notTheUsersRequest)
        }
        // R2 / K3 — a placeholder is not an object.
        if hasPlaceholder(c.description) {
            return .failure(.placeholder)
        }
        // The user's own items name nobody.
        c.assignee = nil
        // R6 — the title filters screen tasks already pass.
        let wordCount = c.description.split { $0 == " " || $0 == "\t" || $0 == "\n" }.count
        if wordCount > maxWords
            || TaskExtractionFilters.isGenericNoise(c.description)
            || TaskExtractionFilters.validateTaskTitle(c.description) != nil {
            return .failure(.vagueTitle)
        }
        // K13 — "today at noon" processed after noon keeps its date; only a date more than a day past goes.
        if let due = c.dueAt, due < now.addingTimeInterval(-pastDueGrace) { c.dueAt = nil }

        return .success(Kept(candidate: c, kind: kind, fragmentIndex: index, mentionedAt: fragments[index].at))
    }

    // MARK: - R1 / K8 / K9 repeats

    private static func isRepeat(_ kept: Kept, of rows: [Existing]) -> Bool {
        rows.contains {
            isNearDuplicate(kept.candidate.description, kept.candidate.assignee, $0.description, $0.assignee)
                && kept.mentionedAt <= $0.resolvedAt
        }
    }

    /// K8 — the same work: the same words in any order, ignoring case and punctuation, for the same person.
    /// Without a word list an added word cannot be told from a negation, so any added, missing or replaced word —
    /// another recipient, another number, a "not" — makes it a different task.
    static func isNearDuplicate(_ a: String, _ assigneeA: String?, _ b: String, _ assigneeB: String?) -> Bool {
        let wa = Set(words(a)), wb = Set(words(b))
        guard !wa.isEmpty, wa == wb else { return false }
        return Set(words(assigneeA ?? "")) == Set(words(assigneeB ?? ""))
    }

    /// K9 — how long an existing row absorbs repeats: open work for good; done, dropped or expired work only
    /// copies mentioned before it ended, so the same thing said again later may come back.
    @MainActor
    static func existing(from task: TaskItem, now: Date) -> Existing? {
        let resolvedAt: Date
        if task.isDismissed || task.effectiveStatus == "dismissed" {
            resolvedAt = task.updatedAt
        } else if task.completed {
            resolvedAt = task.completedAt ?? task.updatedAt
        } else if task.effectiveStatus == "staged",
                  TaskHygiene.isStaleUnreviewedCandidate(status: "staged", createdAt: task.createdAt, now: now) {
            resolvedAt = TaskHygiene.reviewWindowEnd(createdAt: task.createdAt)
        } else {
            resolvedAt = .distantFuture
        }
        return Existing(description: task.taskDescription, assignee: task.assignee, resolvedAt: resolvedAt)
    }

    // MARK: - R3 phantom fragments

    /// A fragment as it may be sent: the phantom phrases a speech model invents on silence ("Subtitles by …",
    /// "To be continued") are taken out with the transcription filter's own list; `nil` when nothing real is left.
    /// Not `isAlwaysHallucination`: its mixed-script check is for one short chunk, and a long call part that
    /// mixes three scripts is real speech (the replay lost a whole 16,814-character call to it).
    @MainActor
    static func sendable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = TranscriptionCoordinator.stripHallucinationTokens(trimmed)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Structure

    /// K17 — letters and digits only, case and diacritics folded: "Book the café!" and "book the cafe" match.
    static func matchKey(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }))
    }

    /// Runs of letters or digits, folded as in `matchKey`.
    static func words(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [String] = [], current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                out.append(String(current)); current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// The labels a call's lines start with (`Me:` / `Them:`), written by `DualStreamMerger`.
    private static var speakerLabels: [String] { [DualStreamMerger.meLabel, DualStreamMerger.themLabel] }


    private static func isOnTheUsersLine(_ evidence: [String], in fragment: String) -> Bool {
        fragment.split(separator: "\n").contains { line in
            line.hasPrefix(DualStreamMerger.meLabel + ":")
                && containsInOrder(evidence, matchKey(String(line.dropFirst(DualStreamMerger.meLabel.count + 1))))
        }
    }

    /// The evidence as match keys: a speaker label the model copied with the words is not part of them, and a long
    /// quote may be shortened with an ellipsis ("…" or "..."), so each piece between them is matched on its own.
    static func evidencePieces(_ evidence: String) -> [String] {
        var text = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in speakerLabels where text.hasPrefix(label + ":") {
            text = String(text.dropFirst(label.count + 1))
        }
        return text.components(separatedBy: "…")
            .flatMap { $0.components(separatedBy: "...") }
            .map(matchKey)
            .filter { !$0.isEmpty }
    }

    /// Every piece appears in `text`, in this order — exactly, or with one letter different (a speech model's typo
    /// the task model "fixed" in its quote) when the piece has at least `typoSpan` letters in a script with spaces.
    /// One letter at most: dropping a two-letter "no" is another sentence, not a typo; a script without spaces can
    /// lose a one-character negation, so there the quote is exact. Several pieces (an ellipsis) must each be a real
    /// stretch of speech (`minEvidenceUnits` letters) and follow one another within `maxPieceGap` letters, so a
    /// quote cannot be stitched from words spread over a long call.
    static func containsInOrder(_ pieces: [String], _ text: String) -> Bool {
        guard !pieces.isEmpty else { return false }
        if pieces.count > 1, pieces.contains(where: { $0.unicodeScalars.count < minEvidenceUnits }) { return false }
        let scalars = Array(text.unicodeScalars)
        var start = 0
        while start < scalars.count {
            guard let first = match(pieces[0], in: scalars, from: start) else { return false }
            var end = first.end, ok = true
            for piece in pieces.dropFirst() {
                guard let next = match(piece, in: scalars, from: end), next.end - piece.unicodeScalars.count - end <= maxPieceGap else {
                    ok = false; break
                }
                end = next.end
            }
            if ok { return true }
            start = first.end   // try the first piece's next occurrence
        }
        return false
    }

    private static func match(_ piece: String, in t: [Unicode.Scalar], from: Int) -> (end: Int, Void)? {
        let p = Array(piece.unicodeScalars)
        let tolerant = p.count >= typoSpan && !TaskExtractionFilters.isWrittenWithoutSpaces(piece)
        return firstMatchEnd(of: p, in: t, from: from, allowingOneEdit: tolerant).map { ($0, ()) }
    }

    /// K17 — a piece this long may differ in one letter.
    static let typoSpan = 20
    /// K17 — the most letters between two ellipsis pieces.
    static let maxPieceGap = 300
    /// K17 — the first and the last this many letters of a piece must match exactly: an edit at a quote's edge can
    /// turn "no …" into "yo …".
    static let typoAnchor = 3

    /// Where the earliest occurrence of `p` in `t[from...]` ends (exclusive): exact, or — when allowed — with one
    /// letter substituted, added or missing strictly inside the piece, its first and last `typoAnchor` letters exact.
    private static func firstMatchEnd(of p: [Unicode.Scalar], in t: [Unicode.Scalar], from: Int,
                                      allowingOneEdit: Bool) -> Int? {
        guard !p.isEmpty, from < t.count else { return nil }
        let head = min(typoAnchor, p.count)
        var s = from
        while s + head <= t.count {
            if t[s..<(s + head)].elementsEqual(p[0..<head]) {
                var i = 0, j = s
                while i < p.count, j < t.count, p[i] == t[j] { i += 1; j += 1 }
                if i == p.count { return j }
                if allowingOneEdit, i >= typoAnchor, i < p.count - typoAnchor {
                    // substituted, added in the text, missing from the text
                    for (pi, tj) in [(i + 1, j + 1), (i, j + 1), (i + 1, j)] {
                        let rest = p.count - pi
                        if tj + rest <= t.count, t[tj..<(tj + rest)].elementsEqual(p[pi...]) { return tj + rest }
                    }
                }
            }
            s += 1
        }
        return nil
    }

    /// `[name]`, `<name>`, `{name}` — a template slot, not a word anyone said.
    static func hasPlaceholder(_ s: String) -> Bool {
        s.range(of: #"\[[^\]]*\]|<[^>]*>|\{[^}]*\}"#, options: .regularExpression) != nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
