import Foundation

/// How the memory-extraction prompt is divided between "what we already know"
/// and "the text to read".
///
/// The known-facts block exists so the model does not propose a fact twice. On
/// the cloud paths it was written uncapped — every stored memory, up to a
/// thousand — and only the finished prompt was cut, from the head, at 20 000
/// characters. A user with a full second brain sent a prompt that was all
/// dedup list and no transcript, and the extraction found nothing to extract,
/// every time, in silence (audit, 2026-09-06, P1).
///
/// Pure, because a budget is a decision.
enum MemoryPromptBudget {

    /// The known-facts block's share. The transcript is what is being read;
    /// the list is only there to prevent duplicates, so it takes the smaller
    /// part — the same three-tenths the local path already used.
    static let existingShare = 0.3

    static func split(total: Int) -> (existing: Int, transcript: Int) {
        let existing = Int(Double(total) * existingShare)
        return (existing, total - existing)
    }

    /// Take known facts in order until the share is used, and say how many
    /// were left out — a dedup list that silently stops is worse than one that
    /// admits its end, because the model then proposes the missing ones again.
    static func fit(existing: [String], into budget: Int) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in existing {
            let cost = line.count + 1
            if used + cost > budget { break }
            kept.append(line); used += cost
        }
        let omitted = existing.count - kept.count
        guard omitted > 0 else { return kept }
        kept.append("(\(omitted) known fact\(omitted == 1 ? "" : "s") omitted for space)")
        return kept
    }
}
