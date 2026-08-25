import Foundation

/// The bridge between what the model returns and what the director judges.
///
/// Production and the replay deck both go through this one function. That is
/// the point of its existence: the first version of the deck authored its own
/// citations and quotes, which meant it was testing the director against
/// evidence nobody in production would ever construct — it could never catch
/// this bridge lying. A fixture is now a prompt-shaped insight and a screen,
/// nothing more, exactly what production has.
enum ScreenAgentCandidateAdapter {

    static let evidenceID = "e1"

    /// The runtime issues the evidence; the model never gets to.
    static func evidence(contextID: UUID, ocrText: String) -> ScreenAgentEvidence {
        ScreenAgentEvidence([.init(id: evidenceID, contextID: contextID, text: ocrText)])
    }

    static func candidate(from insight: ExtractedInsight) -> ScreenAgentDirector.Candidate {
        let headline = insight.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (headline?.isEmpty == false) ? headline! : insight.body
        // Anchors come from everything the user would read, headline and body
        // both — a body claiming an invented deadline is as wrong as a
        // headline doing it.
        let claim = title + " " + insight.body
        return .init(
            headline: title,
            body: insight.body,
            citedEvidenceIDs: [evidenceID],
            quote: InsightReferent.strongestAnchor(title),
            confidence: insight.confidence,
            namesReferent: InsightReferent.namesSomethingSpecific(title),
            anchors: InsightReferent.hardAnchors(in: claim)
        )
    }
}
