import Foundation

/// Domain vocabulary for biasing ASR towards correct brand / term spelling.
///
/// Two surfaces:
///
/// 1. **`promptHint()`** — comma-separated list of canonical names. Passed
///    to Whisper as `initial_prompt` (biases the decoder, ~10-15% recall
///    boost on rare proper nouns per OpenAI docs) and forwarded to the CF
///    Worker so it can populate Deepgram's `keyterm` parameter (Nova-3's
///    glossary-style boost). Capped under the 224-token Whisper prompt limit.
///
/// 2. **`applyCorrections(_:)`** — conservative post-replacement for
///    UNAMBIGUOUS Cyrillic-mangle-of-Latin-brand cases observed in
///    production. Only triggers when the mangled string is provably NOT
///    a real Russian word (e.g. «Селви», «Бриво»). Real-word collisions
///    like «молчим» (MailChimp) or «клод/клот» (Claude) are deliberately
///    NOT auto-corrected — risk of breaking legitimate sentences.
///
/// Source data: production meeting transcripts on 2026-05-28 in SwiftData
/// `ZHISTORYITEM` showed Brevo/MailChimp/LLM/Claude/ChatGPT and a number of
/// private brand names being systematically mangled by Whisper-family
/// models. Regression-pinned by `BrandGlossaryTests`.
enum BrandGlossary {

    /// Canonical names that bias the ASR. Only publicly-known, broadly-used
    /// vendor names and industry terms — never a specific user's portfolio
    /// or client list (per repo policy: no identifying names in source).
    /// Per-user brands (own product / customer / colleague names) belong in
    /// `CorrectionDictionary` which the user populates via Settings →
    /// Snippets.
    private static let canonicalTerms: [String] = [
        // App's own brand
        "MetaWhisp",
        // AI vendors / model families
        "Claude", "ChatGPT", "Anthropic", "OpenAI", "Gemini",
        "Deepgram", "Groq", "Cerebras", "Whisper", "Sonnet", "Opus",
        // Public marketing / ESP tools (industry standard)
        "MailChimp", "Mailerlite", "Brevo", "Klaviyo",
        "Campaign Monitor", "GetResponse",
        // SEO tooling (industry standard)
        "Ahrefs", "Semrush", "Reddit",
        // Common acronyms ASR mangles
        "LLM", "RAG", "SEO", "SERP", "CTR", "GSC", "GA4",
        "MCP", "API", "SDK", "AEO", "GEO",
    ]

    /// Returns the canonical-name list as a comma-separated string for use
    /// as Whisper `initial_prompt` and Deepgram `keyterm` hint. Joined with
    /// ", " so engines can split on either the comma or the space.
    static func promptHint() -> String {
        return canonicalTerms.joined(separator: ", ")
    }

    /// Returns the canonical-name list as an array (for callers that want to
    /// concatenate with user-defined dictionary entries before serialising).
    static func canonicalNames() -> [String] {
        return canonicalTerms
    }

    /// Conservative auto-correct map: mangled spelling → canonical spelling.
    /// Each mangle MUST be unambiguous — never a real Russian/English word.
    /// Pattern is `(?i)\bMANGLE\b` so partial matches don't trigger.
    ///
    /// ONLY publicly-known brands here — per-user portfolio / client names
    /// belong in `CorrectionDictionary` (per Settings → Snippets), not in
    /// shipped source. This file ships in the open-source app binary.
    private static let unambiguousMangles: [(mangle: String, canonical: String)] = [
        // Brevo — public ESP. «Бриво» / «бриво». Not a Russian word.
        ("Бриво",  "Brevo"),
        ("бриво",  "Brevo"),
    ]

    /// Surgical post-replace for unambiguous brand mangles. Whole-word
    /// matches only (`\b…\b`). Other ambiguous mangles (молчим/клод/клот/
    /// ОЛМ/LN) deliberately omitted — see file header for rationale.
    static func applyCorrections(_ text: String) -> String {
        var result = text
        for (mangle, canonical) in unambiguousMangles {
            // Build a word-boundary regex per entry. Pre-baking these into
            // static let NSRegularExpression at file init would shave a few
            // ms but the list is tiny and per-call cost is negligible vs
            // an ASR round-trip.
            let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: mangle))\b"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: canonical
            )
        }
        return result
    }
}
