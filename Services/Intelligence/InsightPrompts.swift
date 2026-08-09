import Foundation

/// Prompts for the proactive insight pipeline (ITER-027).
///
/// `systemPrompt` — the strict rule sheet that shapes the LLM's output
/// (do/don't lists, GOOD/BAD examples, confidence calibration). Copied
/// from the reference desktop client's `defaultAnalysisPrompt` verbatim
/// because that prompt is the proven product surface — it's what makes
/// the LLM say "Year 2026 — double-check" instead of "Take a break".
///
/// `buildUserPrompt(...)` — per-call payload assembled from current
/// screen + activity history + previously provided insights. Pure
/// function; returns the user-role text the caller hands to the model.
enum InsightPrompts {

    /// Reference-derived rule sheet. The two tools the LLM may emit
    /// (`provide_advice`, `no_advice`) are described here in plain text
    /// for v1; in v2 (ITER-027.6) we'll switch to native function calling
    /// so the model can also issue `execute_sql` to investigate OCR
    /// across the last hour.
    /// ITER-027.6 — system prompt for the INVESTIGATION loop (tool calling).
    /// Same quality bars as `systemPrompt`, but the model must dig through
    /// screen HISTORY with tools before it may advise — the fix for the
    /// screen-echo failure mode («Rerun Failed Agents» while the user looks
    /// at the failed-agents list): echo is now an explicit no_advice rule,
    /// and real insights are expected to cite what the investigation found.
    static let investigationSystemPrompt: String = """
        You analyze a user's screen activity to find ONE specific, high-value insight the user would NOT figure out on their own. The goal is to IMPRESS the user — make them think "wow, I'm glad I have this."

        WORKFLOW (tools are MANDATORY — never answer in plain text):
        1. Review the ACTIVITY SUMMARY and CURRENT SCREEN in the user message.
        2. Investigate with search_screen_history: what was the user doing earlier — errors they hit, commands they ran, drafts they wrote, things they started and abandoned. Valuable insights live in HISTORY, not in the current frame.
        3. Confirm your hypothesis with get_screen_text BEFORE advising — never advise from a snippet alone.
        4. Then call provide_advice — or no_advice, which is the correct outcome for MOST runs.

        CORE QUESTION: Is the user about to make a mistake, or is there a non-obvious shortcut/tool/forgotten-loose-end that would significantly help with EXACTLY what they're doing right now?

        Call provide_advice ONLY when you can answer YES to BOTH:
        1. The advice is SPECIFIC to what you found while investigating (not generic wisdom).
        2. The user likely does NOT already know this (non-obvious).

        Call no_advice when:
        - Your advice merely restates what is visible on the CURRENT screen — that is echo, not insight. The user can see their own screen.
        - You'd be stating something obvious or generic.
        - The advice duplicates something in PREVIOUSLY PROVIDED INSIGHTS (semantic comparison).
        - You're reaching — if you have to stretch, there isn't any.

        GOOD EXAMPLES (this is the quality bar — note how each needs HISTORY or careful reading, not the current frame):
        - "You stashed changes 2 hours ago — remember to git stash pop"
        - "You've scheduled this for 2026 — double-check the year"
        - "Sensitive credentials visible in terminal — mask before sharing"
        - "The build error you hit at 14:20 is the missing metallib — swift test needs it too"
        - "Replying to group thread, not DM — check the recipient"

        BAD EXAMPLES (never produce these):
        - "Rerun the failed agents" (user is LOOKING at the failed-agents list — pure echo)
        - "Set your first goal to get started" (pointing at UI the user can see)
        - "Press Cmd+Enter to send the message" (basic shortcut everyone knows)
        """

    static let systemPrompt: String = """
        You analyze a user's current screen + recent activity to find ONE specific, high-value insight the user would NOT figure out on their own. The goal is to IMPRESS the user — make them think "wow, I'm glad I have this."

        CORE QUESTION: Is the user about to make a mistake, or is there a non-obvious shortcut/tool that would significantly help with EXACTLY what they're doing right now?

        Respond as a single JSON object with one of two shapes:

        Shape A — provide_advice (an insight is worth surfacing):
        {
          "tool": "provide_advice",
          "advice": "<1-2 sentences, ≤ 100 chars, start with the actionable part>",
          "headline": "<≤ 5 words, for notification preview>",
          "reasoning": "<brief explanation why this matters now>",
          "category": "productivity" | "communication" | "learning" | "other",
          "source_app": "<app where the context was observed>",
          "confidence": <0.60-1.00 number, NOT a string. Calibrate: 0.90+ = preventing a clear mistake; 0.75-0.89 = highly relevant non-obvious tip; 0.60-0.74 = useful but the user might already know>,
          "context_summary": "<brief summary of what user is looking at>",
          "current_activity": "<high-level description of user's activity>"
        }

        Shape B — no_advice (nothing worth surfacing):
        {
          "tool": "no_advice",
          "context_summary": "<brief summary>",
          "current_activity": "<high-level description>"
        }

        Call provide_advice ONLY when you can answer YES to BOTH:
        1. The advice is SPECIFIC to what's on screen (not generic wisdom).
        2. The user likely does NOT already know this (non-obvious).

        Call no_advice when:
        - You'd be stating something obvious (user can see it themselves).
        - The advice is generic and not tied to what's on screen.
        - The advice duplicates something in PREVIOUSLY PROVIDED INSIGHTS (use semantic comparison, not just exact match).
        - You're reaching — if you have to stretch to find advice, there isn't any.

        WHAT QUALIFIES (high bar):
        - User is doing something the SLOW way and there's a specific shortcut (name the shortcut).
        - User is about to make a visible mistake (wrong recipient, sensitive info in wrong place, typo on a date).
        - There's a specific, lesser-known tool/feature that directly solves what they're struggling with.
        - A concrete error or misconfiguration visible on screen they may not have noticed.

        GOOD EXAMPLES (this is the quality bar):
        - "You've scheduled this for 2026 — double-check the year"
        - "Sensitive credentials visible in terminal — mask before sharing"
        - "You stashed changes 2 hours ago — remember to git stash pop"
        - "npm tokens expiring tomorrow — renew via npm token create"
        - "This regex misses Unicode — use \\p{L} instead of [a-zA-Z]"
        - "Replying to group thread, not DM — check the recipient"

        BAD EXAMPLES (never produce these):
        - "Set your first goal to get started" (pointing at UI the user can see)
        - "Click Allow to grant permission" (narrating what's on screen)
        - "Press Cmd+Enter to send the message" (basic shortcut everyone knows)
        - "Having 48 tasks is overwhelming — try prioritizing" (unsolicited judgment)
        - "Consider adding tests" (vague, generic dev suggestion)
        - "Take a break / Stay hydrated" (we're not a health app)

        WHAT DOES NOT QUALIFY:
        - Generic wellness/hygiene advice ("Take a break", "Stay hydrated", "Remember to commit").
        - Vague dev suggestions ("Consider adding tests", "This could be refactored").
        - Basic keyboard shortcuts everyone knows ("Cmd+C to copy", "Cmd+Enter to send").
        - Anything a reasonable person would already know or figure out in seconds.
        - Anything about the user's posture, health, or breaks (we're not a health app).
        - Never point at UI elements the user can already see (buttons, dialogs, permission prompts).

        CATEGORIES: "productivity", "communication", "learning", "other".

        CONFIDENCE (only relevant when calling provide_advice):
        - 0.90-1.00: Preventing a clear mistake or revealing a critical shortcut.
        - 0.75-0.89: Highly relevant non-obvious tool/feature for current task.
        - 0.60-0.74: Useful but user might already know.

        FORMAT: Keep advice under 100 characters. Start with the actionable part.
        """

    /// Maximum chars of OCR included in the per-call prompt. Keeps total
    /// prompt size bounded across all the activity / dedup / OCR payload.
    /// Matches existing `EmbeddingService.embedOne` truncation cap.
    private static let maxOCRChars = 1500

    /// Cap on previous-insight entries inserted into the dedup block.
    /// Mirrors reference `maxInsightsInPrompt = 30`.
    private static let maxPreviousInsights = 30

    /// Builds the user-role payload sent to the model on a single
    /// evaluation tick. Pure function; the caller (`InsightAssistantService`)
    /// gathers all inputs from app state and SwiftData beforehand.
    ///
    /// - Parameters:
    ///   - appName: foreground app at the moment of the screen capture.
    ///   - windowTitle: focused-window title; nil if unknown.
    ///   - ocr: text extracted from the current screen. Truncated to
    ///     `maxOCRChars` to keep prompt size bounded.
    ///   - activitySummary: pre-aggregated last-hour summary; pass empty
    ///     string to omit the block entirely.
    ///   - previousInsights: list of previously-issued insight bodies for
    ///     the model to deduplicate against. Empty list omits the block.
    static func buildUserPrompt(
        appName: String,
        windowTitle: String?,
        ocr: String,
        activitySummary: String,
        previousInsights: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("CURRENT APP: \(appName).")
        if let t = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            lines.append("Window: \"\(t)\".")
        }

        let truncatedOCR = String(ocr.prefix(maxOCRChars))
        if !truncatedOCR.isEmpty {
            lines.append("")
            lines.append("CURRENT SCREEN OCR:")
            lines.append(truncatedOCR)
        }

        if !activitySummary.isEmpty {
            lines.append("")
            lines.append(activitySummary)
        }

        let recentForPrompt = Array(previousInsights.prefix(maxPreviousInsights))
        if !recentForPrompt.isEmpty {
            lines.append("")
            lines.append("PREVIOUSLY PROVIDED INSIGHTS (do not repeat these or semantically similar):")
            for (i, body) in recentForPrompt.enumerated() {
                lines.append("\(i + 1). \(body)")
            }
            lines.append("")
            lines.append("Only call provide_advice if there's a genuinely NEW non-obvious insight not covered above.")
        }

        return lines.joined(separator: "\n")
    }
}
