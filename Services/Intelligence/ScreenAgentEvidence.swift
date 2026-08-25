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
        let needle = Self.normalize(quote)
        // A one- or two-character "quote" substring-matches almost any screen,
        // so it evidences nothing while looking like it does. Short but real
        // quotes — a time, a name — still clear this.
        guard needle.count >= Self.minimumQuoteCharacters else { return .quoteNotInSource }
        let found = cited.contains { Self.normalize($0.text).contains(needle) }
        return found ? nil : .quoteNotInSource
    }

    /// Below this a quote cannot be told apart from a coincidence. Deliberately
    /// low: "16:00" is exactly the kind of specific thing worth quoting.
    static let minimumQuoteCharacters = 3

    /// Lowercased, whitespace-collapsed. OCR spacing is not stable enough to
    /// compare literally, and being strict about it would reject real quotes.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
