import Foundation

/// The proof behind a claim, and the check that it is real.
///
/// The old gate set two booleans: some search happened, some record was read.
/// Neither was tied to what the comment ended up saying, so a model could look
/// up one thing, read another, and assert a third — and the gate would call
/// that grounded. `TaskFulfillment` already had the stronger check; the
/// proactive path never got it.
///
/// Here the runtime hands the model a numbered list of what it is allowed to
/// cite. Anything cited outside that list is not a weaker claim, it is a
/// fabricated one, and the whole item goes.
struct ScreenAgentEvidence {

    /// One thing the model may point at. IDs are issued by the runtime, never
    /// by the model, so it cannot mint a plausible-looking reference.
    struct Ref: Equatable {
        let id: String
        /// The screen row this came from.
        let contextID: UUID
        /// The text as captured. Used to check quotes, never sent to metrics.
        let text: String
    }

    enum Rejection: Equatable {
        /// The model cited an ID that was never offered.
        case unknownReference(String)
        /// The quote does not appear in the evidence it points at.
        case quoteNotInSource
        /// A claim with nothing behind it at all.
        case noEvidence
    }

    private let refs: [String: Ref]

    init(_ refs: [Ref]) {
        self.refs = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Numbered list handed to the model. It may cite these IDs and nothing
    /// else.
    var allowlist: [String] { refs.keys.sorted() }

    /// Check a claim's citations.
    ///
    /// - Parameter quote: optional verbatim text the model says it is quoting.
    ///   Checked against the cited source with the same normalization
    ///   `TaskFulfillment` uses, so whitespace and case cannot smuggle an
    ///   invention past it.
    func validate(citedIDs: [String], quote: String?) -> Rejection? {
        guard !citedIDs.isEmpty else { return .noEvidence }

        var cited: [Ref] = []
        for id in citedIDs {
            guard let ref = refs[id] else { return .unknownReference(id) }
            cited.append(ref)
        }

        guard let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return check([quote], against: cited)
    }

    /// Every quote must be present, not just the first one found. A headline
    /// naming a real time and an invented count used to pass because only the
    /// strongest anchor was checked.
    func validate(citedIDs: [String], quotes: [String]) -> Rejection? {
        guard !citedIDs.isEmpty else { return .noEvidence }
        var cited: [Ref] = []
        for id in citedIDs {
            guard let ref = refs[id] else { return .unknownReference(id) }
            cited.append(ref)
        }
        let real = quotes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !real.isEmpty else { return nil }
        return check(real, against: cited)
    }

    private func check(_ quotes: [String], against cited: [Ref]) -> Rejection? {
        let haystacks = cited.map { Self.normalize($0.text) }
        for quote in quotes {
            let needle = Self.normalize(quote)
            // A one-character "quote" substring-matches almost any screen, so
            // it evidences nothing while looking like it does. Short but real
            // quotes — a count, a time — still clear this.
            guard needle.count >= Self.minimumQuoteCharacters else { return .quoteNotInSource }
            guard haystacks.contains(where: { Self.occurs(needle, in: $0) }) else {
                return .quoteNotInSource
            }
        }
        return nil
    }

    /// Whole-token for single tokens: "13" inside "2013" and "ann" inside
    /// "anna" prove nothing, and plain containment accepted both. Multi-word
    /// quotes keep containment — their own words bound them.
    static func occurs(_ needle: String, in haystack: String) -> Bool {
        guard !needle.contains(" ") else { return haystack.contains(needle) }
        let pattern = "(?<![\\p{L}\\p{N}])"
            + NSRegularExpression.escapedPattern(for: needle)
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return haystack.contains(needle)
        }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    /// Below this a quote cannot be told apart from a coincidence. Two, not
    /// three: auto-extracted anchors include two-digit counts — "13 unresolved
    /// comments" — and a threshold that drops them cannot catch an invented
    /// count. A single character substring-matches everything and stays out.
    static let minimumQuoteCharacters = 2

    /// Lowercased, whitespace-collapsed. OCR spacing is not stable enough to
    /// compare literally, and being strict about it would reject real quotes.
    static func normalize(_ text: String) -> String {
        // OCR and model output disagree about punctuation constantly: smart
        // quotes, em dashes, nonbreaking spaces. Fold them before comparing or
        // a genuine quote fails on a character nobody can see.
        text.lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
