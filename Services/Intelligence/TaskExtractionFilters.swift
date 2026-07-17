import Foundation

/// Shared filters for screen-based task extraction.
///
/// Two-pronged defense against noisy task creation:
/// 1. App-level blacklist — never extract tasks from OCR of AI coding assistants or
///    the app's own UI (recursive noise).
/// 2. Fuzzy dedup — word-overlap similarity catches wording variations that exact
///    case-insensitive match misses ("Fix exampleproject SEO" vs "Fix Example Project SEO issue").
///
/// Used by both `ScreenExtractor` (hourly batch) and `RealtimeScreenReactor` (per-snapshot).
enum TaskExtractionFilters {

    /// ITER-057.5 — WHITELIST (flipped from the old blacklist). Tasks live in
    /// conversations: the reference model allows ONLY messengers, mail, notes and
    /// work-signal browser tabs — everything else (IDEs, system dialogs, dashboards,
    /// AI assistants) produced junk ("Allow keychain access for xctest") that
    /// drowned real commitments. Observations + memories are still extracted from
    /// all apps; this gate governs TASKS only.
    ///
    /// Match is done against both the user-facing app name and the bundle identifier
    /// so different OS versions / localizations all hit.
    static let taskAllowedApps: Set<String> = [
        // Messengers — the primary source of commitments («напишу тебе завтра»).
        "Telegram", "org.telegram.desktop", "ru.keepcoder.Telegram",
        "WhatsApp", "\u{200E}WhatsApp",   // WhatsApp reports its name with a leading LTR mark
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "Messages", "com.apple.MobileSMS", "com.apple.iChat",
        "Slack", "com.tinyspeck.slackmacgap",
        "Discord", "com.hnc.Discord",
        "Signal", "org.whispersystems.signal-desktop",
        "Messenger", "com.facebook.archon.developerID",
        "Mattermost", "Mattermost.Desktop",
        "zoom.us",
        // Mail — requests addressed to the user.
        "Mail", "com.apple.mail",
        "Microsoft Outlook", "com.microsoft.Outlook",
        "Superhuman",
        // Notes — the user's own explicit reminders.
        "Notes", "com.apple.Notes",
    ]

    /// Browsers pass the task gate ONLY when the window title carries a work
    /// signal (webmail, project tools, messenger web apps — see
    /// `browserTitleKeywords`). A browser with an empty/unmatched title is
    /// blocked: articles, videos and dashboards are reading, not commitments.
    static let taskBrowserApps: Set<String> = [
        "Google Chrome", "Arc", "Safari", "Firefox",
        "Microsoft Edge", "Brave Browser", "Opera",
    ]

    /// Case-insensitive substrings matched against a browser window title.
    static let browserTitleKeywords: [String] = [
        // Email
        "gmail", "outlook", "yahoo mail", "protonmail", "superhuman", "fastmail",
        // Messaging web apps
        "slack", "discord", "whatsapp", "telegram", "messenger", "signal", "mattermost",
        // Project management
        "jira", "linear", "trello", "asana", "notion", "monday", "clickup", "basecamp",
        // Calendar
        "google calendar", "outlook calendar", "cal.com", "calendly",
        // Code & collaboration
        "github", "google docs", "google sheets", "google slides",
        // Finance
        "stripe", "paypal", "invoice", "billing", "quickbooks",
        // Forms & signing
        "google forms", "typeform", "docusign",
        // Action words
        "todo", "task", "assign", "review", "approve", "request", "ticket",
        // Inbox patterns
        "inbox", "unread", "notification", "pending",
    ]

    /// System permission/notification dialogs that generated junk tasks before the
    /// whitelist landed. Used by the one-time ITER-057.5 cleanup migration to
    /// dismiss the rows they already produced.
    static let systemDialogSourceApps: Set<String> = [
        "UserNotificationCenter", "SecurityAgent", "loginwindow",
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

    /// ITER-057.5 — the task gate. True when this app/window may produce tasks:
    /// whitelisted conversation app, OR a browser whose window title matches a
    /// work-signal keyword. Everything else → no tasks (observations/memories
    /// are unaffected).
    static func isTaskAllowed(appName: String, windowTitle: String?, bundleId: String? = nil) -> Bool {
        let lowerApp = appName.lowercased()
        // Browsers: title keyword required (Telegram Web / Gmail / Jira pass;
        // YouTube / articles / empty titles don't).
        if taskBrowserApps.contains(appName)
            || taskBrowserApps.contains(where: { $0.lowercased() == lowerApp }) {
            guard let title = windowTitle?.lowercased(),
                  !title.trimmingCharacters(in: .whitespaces).isEmpty
            else { return false }
            return browserTitleKeywords.contains { title.contains($0) }
        }
        if taskAllowedApps.contains(appName) { return true }
        if let bid = bundleId, taskAllowedApps.contains(bid) { return true }
        // Case-insensitive fallback for whatever the OS reports.
        return taskAllowedApps.contains { $0.lowercased() == lowerApp }
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

    /// Internal (not private) — TaskFulfillment reuses the same tokenizer for its
    /// OCR↔task overlap pre-filter so "related" means the same thing everywhere.
    static func normalizedWords(_ s: String) -> Set<String> {
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
