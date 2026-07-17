import Foundation

/// ITER-057.5 — fulfillment detection: «я написал Сергею — задача закрывается сама».
///
/// Neither we nor the reference had this (reference only REJECTS re-extraction of
/// completed tasks); founder explicitly asked for it. Design: the realtime reactor's
/// single LLM call gets an extra "OPEN TASKS" section listing open tasks that are
/// lexically related to the current OCR; the response gains
/// `"fulfilled": [{"id", "evidence"}]`. Confirmed ids (must come from the sent
/// list, evidence ≥20 chars) are auto-completed through MutationService.
///
/// This enum holds the PURE parts (pre-filter, prompt section, confirmation
/// gating) so they're testable without SwiftData or an LLM.
enum TaskFulfillment {

    /// A task offered to the LLM for the fulfillment check.
    struct OpenTaskRef: Equatable {
        let id: UUID
        let description: String
    }

    /// One entry of the LLM's `"fulfilled"` array. All fields optional so one
    /// malformed entry can't fail the array element decode (paired with the
    /// lossy array decode in the reactor's ReactionJSON — review finding P2).
    struct FulfilledJSON: Decodable {
        let id: String?
        let evidence: String?

        init(id: String?, evidence: String?) {
            self.id = id
            self.evidence = evidence
        }
    }

    /// Minimum shared normalized tokens between a task description and the OCR
    /// for the task to be worth sending. 2 catches "Написать Сергею Петровичу"
    /// against a chat with Сергей Петрович while keeping unrelated tasks out of
    /// the prompt (cost + hallucinated matches).
    static let minSharedTokens = 2
    /// Cap on tasks per LLM call — keeps the prompt small on the 30/hour budget.
    static let maxTasksPerCall = 10

    /// Pre-filter: only tasks lexically related to this OCR are worth the tokens.
    /// Order of `tasks` is preserved (callers pass newest-first).
    static func relatedTasks(ocr: String, tasks: [OpenTaskRef], limit: Int = maxTasksPerCall) -> [OpenTaskRef] {
        let ocrTokens = TaskExtractionFilters.normalizedWords(ocr)
        guard !ocrTokens.isEmpty else { return [] }
        var result: [OpenTaskRef] = []
        for task in tasks {
            let taskTokens = TaskExtractionFilters.normalizedWords(task.description)
            if taskTokens.intersection(ocrTokens).count >= minSharedTokens {
                result.append(task)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// The "OPEN TASKS" block appended to the reactor's user prompt.
    static func promptSection(for tasks: [OpenTaskRef]) -> String {
        guard !tasks.isEmpty else { return "" }
        let lines = tasks.map { "- \($0.id.uuidString): \($0.description)" }
        return """

        OPEN TASKS (fulfillment check — see system prompt):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Gate the LLM's claims: an id must be one we actually sent (no invented
    /// UUIDs), carry evidence of at least `minEvidenceChars`, AND the evidence
    /// must actually occur in the OCR (whitespace/case-normalized substring).
    /// The OCR containment check is what makes the "verbatim quote" contract
    /// enforceable — without it a prompt-echo (small local models love echoing
    /// the task description back as "evidence") silently closes a real task
    /// (review finding P1).
    static func confirmedIds(
        _ fulfilled: [FulfilledJSON]?,
        sent: [OpenTaskRef],
        ocr: String,
        minEvidenceChars: Int = TaskExtractionFilters.minEvidenceChars
    ) -> [UUID] {
        guard let fulfilled, !fulfilled.isEmpty else { return [] }
        let sentIds = Set(sent.map(\.id))
        let normalizedOCR = normalized(ocr)
        guard !normalizedOCR.isEmpty else { return [] }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for entry in fulfilled {
            guard let rawId = entry.id, let id = UUID(uuidString: rawId),
                  sentIds.contains(id), !seen.contains(id) else { continue }
            let evidence = entry.evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard evidence.count >= minEvidenceChars else { continue }
            guard normalizedOCR.contains(normalized(evidence)) else { continue }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    /// Lowercase + collapse all whitespace runs to single spaces, so OCR line
    /// breaks / double spaces don't defeat the containment check.
    static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
