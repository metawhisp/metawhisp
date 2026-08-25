import Foundation

/// The single decision about whether to say anything at all.
///
/// Four loops used to decide this independently — a task reactor, a proactive
/// service, an hourly extractor, an advice service — each with its own idea of
/// what counts as a fact, its own threshold and its own way of interrupting.
/// Nothing anywhere could answer "why did MetaWhisp speak just then", because
/// nothing anywhere made that decision once.
///
/// Silence is the first outcome here, not the leftover when nothing else fires.
/// Most screens are someone reading, and a comment about an ordinary screen is
/// worse than none: it teaches the user to stop looking.
enum ScreenAgentDirector {

    /// What a producer thinks it found. A proposal, not a decision — the model
    /// may propose, the code decides.
    struct Candidate {
        var headline: String
        var body: String
        /// Evidence IDs the model chose from the allowlist it was given.
        var citedEvidenceIDs: [String]
        /// Optional verbatim text it claims to be quoting.
        var quote: String?
        /// The model's own confidence. Used to rank, never to authorize:
        /// a model being sure about something is not evidence that it is true.
        var confidence: Double
        /// Whether the claim names something specific — a person, a file, a
        /// time, a field. A comment that names nothing cannot be acted on.
        var namesReferent: Bool
        /// Every verifiable thing the claim names — times, numbers, files.
        /// Each must exist in the cited evidence, not just the first one: a
        /// headline naming a real time and an invented count used to pass.
        var anchors: [String] = []
    }

    enum Decision: Equatable {
        case item(headline: String, body: String, evidenceIDs: [String])
        case silence(Reason)
    }

    /// Why nothing was said. Every one of these is a normal, healthy outcome
    /// except the last two.
    enum Reason: String, Equatable, CaseIterable {
        /// Nothing was proposed at all — the overwhelmingly common case.
        case nothingToSay
        /// Proposed, but it only restates what is already on the screen.
        case echoesTheScreen
        /// Proposed, but names nothing the user could act on.
        case tooVague
        /// The model was not confident enough to be worth an interruption.
        case lowConfidence
        /// Said before, recently. Rewording does not make it new.
        case duplicate
        /// The claim cited something it was never given.
        case ungrounded
        /// More than one proposal; the director refuses to guess which.
        case ambiguous
        /// The comment carries something that must not be repeated — a
        /// credential-shaped string read off the screen.
        case unsafeContent
        /// The same idea in different words, inside the suppression window.
        case semanticDuplicate
        /// The user said this class of comment was wrong or unwanted.
        case userRejected
    }

    /// Below this a proposal is not worth interrupting anyone for. Confidence
    /// ranks; it does not authorize — grounding does.
    static let minimumConfidence = 0.7

    /// Decide. Pure, so the policy can be argued with in tests rather than
    /// inferred from behavior.
    ///
    /// - Parameters:
    ///   - candidates: everything the producers proposed for this one visit.
    ///   - evidence: exactly what may be cited.
    ///   - screenText: what is already visible, to catch a comment that only
    ///     says it back.
    ///   - recentHeadlines: what was said recently, to catch a reword.
    static func decide(
        candidates: [Candidate],
        evidence: ScreenAgentEvidence,
        screenText: String,
        recentHeadlines: [String],
        rejectedSignatures: [String] = []
    ) -> Decision {
        guard !candidates.isEmpty else { return .silence(.nothingToSay) }

        let ranked = candidates.sorted { $0.confidence > $1.confidence }
        guard let best = ranked.first else { return .silence(.nothingToSay) }

        // Two proposals of equal standing mean the producers disagree, and
        // picking by array order is how the wrong one gets shown.
        if ranked.count > 1, let second = ranked.dropFirst().first,
           abs(best.confidence - second.confidence) < 0.05 {
            return .silence(.ambiguous)
        }

        guard best.confidence >= minimumConfidence else { return .silence(.lowConfidence) }
        guard best.namesReferent else { return .silence(.tooVague) }

        let quotes = (best.quote.map { [$0] } ?? []) + best.anchors
        if let rejection = evidence.validate(citedIDs: best.citedEvidenceIDs, quotes: quotes) {
            NSLog("[ScreenAgentDirector] suppressed — %@", String(describing: rejection))
            return .silence(.ungrounded)
        }

        // A claim that reverses what the screen says is a fabrication with a
        // real anchor in it: "Build 4021 failed" over a screen that says 4021
        // passed cites a genuine number and lies about its state. The word the
        // claim uses is absent, its opposite is present — that is not a
        // paraphrase, it is a reversal.
        if contradictsScreen(best.headline + " " + best.body, screen: screenText) {
            return .silence(.ungrounded)
        }

        // A page can tell the agent to relay a secret, and the agent relaying
        // it is the attack succeeding. MetaWhisp's job with a visible
        // credential is to say one is visible, never to say what it is — and a
        // comment repeating it would also write it into durable history.
        if carriesSecret(best.headline) || carriesSecret(best.body) {
            return .silence(.unsafeContent)
        }

        if echoes(best.headline, of: screenText) { return .silence(.echoesTheScreen) }
        if recentHeadlines.contains(where: { isNearDuplicate($0, best.headline) }) {
            return .silence(.duplicate)
        }
        // The user has already said this class of comment was wrong or already
        // handled. Saying it again in other words is the thing they objected to.
        if wasRejected(best.headline, rejectedSignatures: rejectedSignatures) {
            return .silence(.userRejected)
        }

        return .item(headline: best.headline, body: best.body,
                     evidenceIDs: best.citedEvidenceIDs)
    }

    /// Credential-shaped strings. Deliberately broad: the cost of refusing an
    /// innocent long token is one missed comment, and the cost of the other
    /// mistake is a secret repeated in a popup and stored in a database.
    static func carriesSecret(_ text: String) -> Bool {
        let patterns = [
            #"\b(?:AKIA|ASIA)[0-9A-Z]{8,}\b"#,               // AWS
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#,                   // OpenAI-style
            #"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#,              // GitHub
            #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,            // Slack
            #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, // JWT
            #"\b[A-Za-z0-9+/]{32,}={0,2}\b"#,                // long opaque blob
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    /// State words that come in opposing pairs. The list is short and boring on
    /// purpose: each pair has to be unambiguous enough that the claim using one
    /// while the screen shows the other can only be a reversal. Everyday words
    /// like "open"/"closed" are too common to mean anything here.
    static let polarityPairs: [(String, String)] = [
        ("passed", "failed"), ("succeeded", "failed"), ("enabled", "disabled"),
        ("approved", "rejected"), ("online", "offline"),
        ("connected", "disconnected"),
    ]

    static func contradictsScreen(_ claim: String, screen: String) -> Bool {
        let claimWords = Set(ScreenAgentEvidence.normalize(claim)
            .components(separatedBy: CharacterSet.alphanumerics.inverted))
        let screenWords = Set(ScreenAgentEvidence.normalize(screen)
            .components(separatedBy: CharacterSet.alphanumerics.inverted))
        for (a, b) in polarityPairs {
            // Both directions; and only when the claim's word is absent from
            // the screen while its opposite is present. A screen showing both
            // (a CI page listing passes and failures) decides nothing.
            if claimWords.contains(a), !screenWords.contains(a), screenWords.contains(b) { return true }
            if claimWords.contains(b), !screenWords.contains(b), screenWords.contains(a) { return true }
        }
        return false
    }

    /// A comment that is already on screen verbatim tells the user nothing they
    /// are not looking at.
    static func echoes(_ headline: String, of screenText: String) -> Bool {
        let claim = ScreenAgentEvidence.normalize(headline)
        guard claim.count >= 12 else { return false }
        return ScreenAgentEvidence.normalize(screenText).contains(claim)
    }

    /// Same idea, different words. Compared on content words so "Anna needs the
    /// deck by 4" and "The deck is due to Anna at 4" do not both get shown.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let wordsA = contentWords(a)
        let wordsB = contentWords(b)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        let shared = wordsA.intersection(wordsB).count
        let smaller = min(wordsA.count, wordsB.count)
        return Double(shared) / Double(smaller) >= 0.6
    }

    /// A stable fingerprint of what a comment is about, so the same idea in
    /// different words can be recognised later without keeping the words.
    static func semanticSignature(of headline: String) -> String {
        contentWords(headline).sorted().joined(separator: " ")
    }

    /// Whether a proposal repeats something the user has already rejected.
    ///
    /// `wrong` and `repeated` are about the claim, so the same claim stays
    /// blocked. `tooIntrusive` is about timing and says nothing about the
    /// content, so it must not silence the same idea forever — it feeds pacing
    /// instead.
    static func wasRejected(_ headline: String,
                            rejectedSignatures: [String]) -> Bool {
        let signature = Set(contentWords(headline))
        guard !signature.isEmpty else { return false }
        return rejectedSignatures.contains { previous in
            let old = Set(previous.components(separatedBy: " ").filter { !$0.isEmpty })
            guard !old.isEmpty else { return false }
            let shared = signature.intersection(old).count
            return Double(shared) / Double(min(signature.count, old.count)) >= 0.6
        }
    }

    private static func contentWords(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "a", "an", "is", "are", "was", "to", "for", "of", "on", "in",
            "at", "by", "and", "or", "it", "this", "that", "you", "your",
            "и", "в", "на", "с", "по", "к", "у", "не", "что", "это",
        ]
        return Set(
            ScreenAgentEvidence.normalize(text)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stop.contains($0) }
        )
    }
}
