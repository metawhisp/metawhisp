import Foundation

/// Strongly-typed insight extracted from the LLM response. Pure value type
/// so the surface layer can decide independently whether to display.
struct ExtractedInsight: Equatable {
    /// 1-2 sentence advice body, ≤ ~100 chars per Omi's prompt convention.
    /// Example: "You stashed changes 2 hours ago — remember to git stash pop".
    let body: String
    /// Ultra-short notification preview (≤ 5 words). Optional.
    let headline: String?
    /// Why this advice was generated. Optional, used for debugging / dedup
    /// quality gate (the model's own justification helps catch generic noise).
    let reasoning: String?
    /// One of: productivity, communication, learning, other.
    let category: String
    /// App where the context was observed. Used by source-link UI.
    let sourceApp: String
    /// Model self-rated 0.0-1.0. Caller filters by `defaultMinConfidence`.
    let confidence: Double
}

/// Outcome of parsing an LLM response in the proactive-insight pipeline.
///
/// The LLM is given two tools: `provide_advice` (real insight) and `no_advice`
/// (model decided nothing worth surfacing). Anything else — malformed JSON,
/// missing required fields, out-of-range confidence — collapses to `.parseError`
/// so caller suppresses the surface (don't ship garbage to the user).
enum InsightParseResult: Equatable {
    case provideInsight(ExtractedInsight)
    case noInsight(reason: String)
    case parseError
}

/// Pure-function JSON → `InsightParseResult`. Strict gates per Omi's
/// production behavior: missing required fields, out-of-range confidence,
/// empty body — all rejected so caller surfaces nothing rather than water.
enum InsightOutputParser {
    static func parse(jsonString: String) -> InsightParseResult {
        guard let data = jsonString.data(using: .utf8) else { return .parseError }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .parseError
        }
        guard let tool = raw["tool"] as? String else { return .parseError }

        switch tool {
        case "provide_advice":
            // Required: advice (body), category, source_app, confidence.
            guard let body = (raw["advice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty,
                  let category = raw["category"] as? String,
                  let sourceApp = raw["source_app"] as? String,
                  let confidenceAny = raw["confidence"]
            else { return .parseError }

            let confidence: Double
            switch confidenceAny {
            case let d as Double: confidence = d
            case let i as Int: confidence = Double(i)
            case let n as NSNumber: confidence = n.doubleValue
            default: return .parseError
            }
            guard (0.0...1.0).contains(confidence) else { return .parseError }

            let headline = (raw["headline"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmptyOrNil
            let reasoning = (raw["reasoning"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmptyOrNil

            return .provideInsight(ExtractedInsight(
                body: body,
                headline: headline,
                reasoning: reasoning,
                category: category,
                sourceApp: sourceApp,
                confidence: confidence
            ))

        case "no_advice":
            let reason = (raw["context_summary"] as? String)
                ?? (raw["current_activity"] as? String)
                ?? "no context"
            return .noInsight(reason: reason)

        default:
            // Unknown tool — treat as model declining. Same effect as
            // `no_advice` for the surface layer (don't show anything).
            return .noInsight(reason: "unknown tool: \(tool)")
        }
    }
}

private extension String {
    /// Returns `nil` if the string is empty after trimming, else `self`.
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
