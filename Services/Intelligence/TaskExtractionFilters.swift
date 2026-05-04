import Foundation

/// Shared filters for screen-based task extraction.
///
/// Two-pronged defense against noisy task creation:
/// 1. App-level blacklist — never extract tasks from OCR of AI coding assistants or
///    the app's own UI (recursive noise).
/// 2. Fuzzy dedup — word-overlap similarity catches wording variations that exact
///    case-insensitive match misses ("Fix Atomicbot SEO" vs "Fix ProjectAlpha SEO issue").
///
/// Used by both `ScreenExtractor` (hourly batch) and `RealtimeScreenReactor` (per-snapshot).
enum TaskExtractionFilters {

    /// Apps whose OCR content is NEVER extracted as tasks. Observations + memories may
    /// still be extracted (screen dashboard context is useful); tasks specifically are
    /// suppressed because the content is either:
    /// - AI-generated (Claude/ChatGPT plans ≠ user's commitments)
    /// - Recursive (MetaWhisp reading its own UI)
    /// - Editor tooling that shows fragments of code, not actionable items
    /// - Chat / messaging UIs — scrolling through conversations produces massive false
    ///   positives ("Reply to X", "Check Y"). Reference pattern shows chat-extraction
    ///   needs dedicated classifier (addressee / unread / explicit @mention); generic
    ///   task LLM on chat OCR is 95% noise. Disable until a messenger-specific flow lands.
    ///
    /// Match is done against both the user-facing app name and the bundle identifier
    /// so different OS versions / localizations all hit.
    static let taskBlacklist: Set<String> = [
        // Self — MetaWhisp can't read its own UI productively.
        "MetaWhisp",
        "com.metawhisp.app",

        // AI coding assistants — their output is PROPOSED actions, not user commitments.
        "Claude",
        "Claude Code",
        "com.anthropic.claudefordesktop",
        "ChatGPT",
        "com.openai.chat",
        "Cursor",
        "com.todesktop.230313mzl4w4u92",
        "Aider",
        "Windsurf",

        // IDEs — editor content is code, not action items.
        "Code",           // VS Code
        "com.microsoft.VSCode",
        "Xcode",          // Apple
        "com.apple.dt.Xcode",

        // Messengers — need specialized @mention / unread-focused flow; generic LLM on
        // chat OCR produces constant noise. Off until that lands.
        "Telegram",
        "org.telegram.desktop",
        "ru.keepcoder.Telegram",
        "Slack",
        "com.tinyspeck.slackmacgap",
        "Discord",
        "com.hnc.Discord",
        "WhatsApp",
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
        "Messages",          // iMessage
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "Messenger",         // FB Messenger
        "com.facebook.archon.developerID",
        "Signal",
        "org.whispersystems.signal-desktop",
        "Linear",            // keeps chat-heavy threads; revisit if we want Linear tasks specifically
        // Live-streaming / casual-browsing UIs
        "Live",
    ]

    /// Post-LLM reject list: task descriptions matching these generic patterns are
    /// always rejected regardless of LLM confidence. Target exactly the noise class
    /// the user reported: "Respond to messages", "Send daily", "Ask about free slots",
    /// "Check password access", etc. — actions without a concrete subject.
    static let genericRejectPatterns: [String] = [
        // Pure generic
        "^respond to messages?$",
        "^reply to messages?$",
        "^send daily$",
        "^send message$",
        "^create music$",
        "^check password access$",
        // Vague "ask about / check / send / create X" where X is generic
        "^ask about [a-z ]{0,20} slots?$",
        "^ask about free slots?$",
        "^respond to [a-z ]{0,3}$",          // "Respond to X" (< 3 chars after "to")
    ]

    /// Returns true if the description matches one of the generic/noise patterns.
    static func isGenericNoise(_ description: String) -> Bool {
        let lower = description
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in genericRejectPatterns {
            if lower.range(of: pattern, options: [.regularExpression]) != nil {
                return true
            }
        }
        return false
    }

    /// ITER-032 — strict title validator. Mirrors reference TaskAssistant's
    /// `validateTaskTitle` (`TaskAssistant.swift:807-833`) used for retry-loop
    /// rejection. We don't have a tool-loop architecture, so the validator runs
    /// post-LLM as an additional reject gate. Captures the same vague-title
    /// classes (single-word / no-noun / banned-verb-alone) that reference fed
    /// back into a retry. Returning a non-nil reason → drop the task.
    static func validateTaskTitle(_ title: String) -> TitleRejectionReason? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let words = trimmed.split { $0 == " " || $0 == "\t" }
        let wordCount = words.count

        // Reference floor: 6 words. We're slightly more permissive (4 words)
        // because RU verbs can pack more meaning per token ("Отправить контракт Майку" = 3 words).
        if wordCount < 4 {
            return .tooShort(wordCount: wordCount)
        }

        // Single-verb actions with no object — straight reject pattern from
        // production: "Investigate", "Check logs", "Look into auth".
        let bannedSoloVerbs: Set<String> = [
            "investigate", "research", "explore", "examine", "look",
            "check", "verify", "review", "track", "monitor",
            "respond", "reply", "follow", "handle", "manage", "process",
            "fix", "update", "modify", "change", "edit",
            "разобраться", "проверить", "посмотреть", "ответить", "поправить",
            "обновить", "изменить", "написать",
        ]
        let firstWordLower = words.first.map { String($0).lowercased() } ?? ""
        if wordCount <= 3 && bannedSoloVerbs.contains(firstWordLower) {
            return .vagueVerb(verb: firstWordLower)
        }

        return nil
    }

    enum TitleRejectionReason: CustomStringConvertible {
        case empty
        case tooShort(wordCount: Int)
        case vagueVerb(verb: String)

        var description: String {
            switch self {
            case .empty: return "title is empty"
            case .tooShort(let n): return "only \(n) words — need 4+ with named subject"
            case .vagueVerb(let v): return "starts with vague solo verb '\(v)' — need concrete object"
            }
        }
    }

    /// Minimum relevance score (0-100) for a screen-extracted task to be surfaced.
    /// Relevance reflects how concrete + addressed-to-user the signal is.
    /// 75 chosen after observing 18-task junk window: most false positives scored 40-65;
    /// the few legit tasks (visible invoice with deadline, explicit PR review request)
    /// scored 80+. Adjustable — move this constant to surface-a-task.
    static let minRelevanceScore: Int = 75

    /// Minimum evidence-quote length (chars). Forces LLM to cite actual OCR text rather
    /// than hallucinate tasks from nothing. Empty / short evidence → reject.
    static let minEvidenceChars: Int = 20

    /// Lowercased bundle IDs / app names that should never produce task items.
    static func isTaskBlacklisted(appName: String, bundleId: String? = nil) -> Bool {
        if taskBlacklist.contains(appName) { return true }
        if let bid = bundleId, taskBlacklist.contains(bid) { return true }
        // Case-insensitive fallback for whatever OS reports.
        let lowerApp = appName.lowercased()
        return taskBlacklist.contains { $0.lowercased() == lowerApp }
    }

    /// Check if `candidate` is a near-duplicate of any string in `against`.
    /// Threshold 0.6 — 60% word overlap counts as a duplicate.
    /// Empty strings treated as non-matching.
    static func isNearDuplicate(_ candidate: String,
                                against existing: [String],
                                threshold: Double = 0.6) -> Bool {
        let candidateWords = normalizedWords(candidate)
        guard !candidateWords.isEmpty else { return false }
        for other in existing {
            let otherWords = normalizedWords(other)
            guard !otherWords.isEmpty else { continue }
            let overlap = candidateWords.intersection(otherWords).count
            let size = max(candidateWords.count, otherWords.count)
            guard size > 0 else { continue }
            if Double(overlap) / Double(size) >= threshold {
                return true
            }
        }
        return false
    }

    /// Tokenize: lowercase, strip punctuation, drop stopwords, keep only 3+ char tokens.
    /// Stopwords chosen for English + Russian since that's the corpus.
    private static let stopwords: Set<String> = [
        // English
        "the", "and", "for", "with", "to", "of", "in", "on", "at", "a", "an",
        "is", "are", "be", "was", "were", "it", "this", "that", "from",
        // Russian
        "и", "в", "на", "с", "по", "к", "у", "о", "об", "от", "до", "за",
        "для", "про", "при", "над", "под", "без", "через", "это", "то", "же",
    ]

    private static func normalizedWords(_ s: String) -> Set<String> {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = s.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character(" ") }
        let tokens = String(cleaned)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        return Set(tokens)
    }
}
