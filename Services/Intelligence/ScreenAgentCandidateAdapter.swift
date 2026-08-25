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

    /// The runtime issues the evidence; the model never gets to. History rides
    /// along because the investigator reads it: a claim drawn from a record
    /// the model was genuinely shown is grounded, and citing only the current
    /// screen silenced every historical insight wholesale (Codex P0).
    static func evidence(
        contextID: UUID,
        ocrText: String,
        history: [InsightInvestigator.Snapshot] = [],
        retrieved: [InsightInvestigator.RetrievedRef] = [],
        visualFacts: [ScreenAgentVisionResponse.VisualFact] = []
    ) -> (evidence: ScreenAgentEvidence, ids: [String]) {
        var refs: [ScreenAgentEvidence.Ref] = [
            .init(id: evidenceID, contextID: contextID, text: ocrText)
        ]
        for (index, snapshot) in history.prefix(400).enumerated() {
            refs.append(.init(id: "h\(index)", contextID: contextID, text: snapshot.ocr))
        }
        // ITER-069 — what the investigator pulled from the user's own store.
        // A claim grounded in a stored requirement or task is grounded.
        for ref in retrieved {
            refs.append(.init(id: ref.id, contextID: contextID, text: ref.text))
        }
        // ITER-069 — what the vision model verified about this exact frame.
        // Server-issued IDs; the model never mints its own.
        for fact in visualFacts {
            refs.append(.init(id: fact.evidenceID, contextID: contextID, text: fact.statement))
        }
        return (ScreenAgentEvidence(refs), refs.map(\.id))
    }

    static func candidate(
        from insight: ExtractedInsight,
        citing ids: [String] = [evidenceID]
    ) -> ScreenAgentDirector.Candidate {
        let headline = insight.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (headline?.isEmpty == false) ? headline! : insight.body
        // Everything the user would read counts, headline and body both — a
        // body claiming an invented deadline is as wrong as a headline doing
        // it, and a body naming the referent is as specific as a headline
        // naming it (Codex P0: specificity judged on the headline alone
        // rejected insights whose detail lived in the body).
        let claim = title + " " + insight.body
        return .init(
            headline: title,
            body: insight.body,
            citedEvidenceIDs: ids,
            quote: InsightReferent.strongestAnchor(title),
            confidence: insight.confidence,
            namesReferent: InsightReferent.namesSomethingSpecific(claim),
            anchors: InsightReferent.hardAnchors(in: claim)
        )
    }
}
