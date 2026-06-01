import Foundation

/// Persistent dictionary of learned word/phrase corrections.
/// Corrections are learned automatically when the user edits pasted text.
@MainActor
final class CorrectionDictionary: ObservableObject {
    static let shared = CorrectionDictionary()

    @Published private(set) var corrections: [String: String] = [:]
    @Published var brands: [String: String] = [:]
    @Published var snippets: [String: String] = [:]

    private let fileURL: URL
    private let brandsURL: URL
    private let snippetsURL: URL

    /// Built-in snippet PRESETS — common "say-this-want-that" triggers shipped
    /// with empty expansions. User-facing copy: «moy LinkedIn» / «my LinkedIn»
    /// → user fills in their actual profile URL. Until filled in, the snippet
    /// is rendered greyed-out and skipped by `apply(...)` (see
    /// `allReplacements`). Reasons for ship-with-empty-value:
    ///   1. Discoverability — without seeing «moy email» as a hint, most
    ///      users never realize they CAN have «when I say X, paste Y».
    ///   2. Naming taxonomy — we standardize trigger phrases so cross-device
    ///      sync (future) and team-shared snippet packs stay consistent.
    /// Loaded via `loadDefaultSnippets()` from the Settings/Dictionary UI.
    /// Order doesn't matter — `apply(...)` sorts longest-first internally.
    static let defaultSnippetPresets: [String: String] = [
        // Russian-language triggers (in case user dictates in RU).
        "моя почта": "",
        "мой email": "",
        "мой телефон": "",
        "мой номер": "",
        "мой LinkedIn": "",
        "мой GitHub": "",
        "мой Twitter": "",
        "мой сайт": "",
        "мой адрес": "",
        "моё имя": "",
        // English-language triggers — used when user dictates in EN. Whisper
        // sometimes translates Russian → English mid-sentence ("мой LinkedIn"
        // → "my LinkedIn"), so both variants need to map to the same
        // expansion. After `loadDefaultSnippets()` the user fills both with
        // the same URL once.
        "my email": "",
        "my phone": "",
        "my LinkedIn": "",
        "my GitHub": "",
        "my Twitter": "",
        "my website": "",
        "my address": "",
        "my name": "",
    ]

    /// Built-in brand corrections (user can toggle these on/off)
    static let defaultBrands: [String: String] = [
        "google": "Google", "youtube": "YouTube", "linkedin": "LinkedIn",
        "whatsapp": "WhatsApp", "facebook": "Facebook", "instagram": "Instagram",
        "twitter": "Twitter", "tiktok": "TikTok", "snapchat": "Snapchat",
        "telegram": "Telegram", "discord": "Discord", "slack": "Slack",
        "spotify": "Spotify", "netflix": "Netflix", "amazon": "Amazon",
        "apple": "Apple", "microsoft": "Microsoft", "openai": "OpenAI",
        "chatgpt": "ChatGPT", "github": "GitHub", "gitlab": "GitLab",
        "notion": "Notion", "figma": "Figma", "canva": "Canva",
        "dropbox": "Dropbox", "trello": "Trello", "asana": "Asana",
        "jira": "Jira", "confluence": "Confluence", "zoom": "Zoom",
        // «metawhisp» REMOVED 2026-05-13 — fuzzy-matching against the app's
        // own name caught Russian words with similar character distance
        // (Levenshtein ≤ 2 on 9-char keys) and replaced them with «MetaWhisp»,
        // which then leaked into MeetingCoach context and generated irrelevant
        // «How does MetaWhisp relate to our project goals?» questions. Apps
        // don't need to autocorrect their own name — the user controls casing
        // directly in the chat / snippet UI.
        "iphone": "iPhone", "ipad": "iPad",
        "macbook": "MacBook", "airpods": "AirPods", "imessage": "iMessage",
        "facetime": "FaceTime", "siri": "Siri", "alexa": "Alexa",
        "uber": "Uber", "airbnb": "Airbnb", "paypal": "PayPal",
        "stripe": "Stripe", "shopify": "Shopify", "wordpress": "WordPress",
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MetaWhisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("corrections.json")
        brandsURL = dir.appendingPathComponent("brands.json")
        snippetsURL = dir.appendingPathComponent("snippets.json")
        load()
        loadBrands()
        loadSnippets()
    }

    /// All active replacements: corrections + brands + snippets merged.
    /// Snippets with empty values are skipped — those are PRESETS the user
    /// hasn't filled in yet (see `defaultSnippetPresets`) and applying them
    /// would clobber the original word with nothing.
    private var allReplacements: [String: String] {
        var merged = corrections
        for (k, v) in brands where !v.isEmpty { merged[k] = v }
        for (k, v) in snippets where !v.isEmpty { merged[k] = v }
        return merged
    }

    /// Apply all known corrections, brands, and snippets to text.
    /// First pass: exact matching (longest-first). Second pass: fuzzy matching per word (Levenshtein ≤ 2).
    func apply(_ text: String) -> String {
        let all = allReplacements
        guard !all.isEmpty else {
            return text
        }

        NSLog("[CorrectionDict] Applying %d replacements to %d chars", all.count, text.count)

        // Pass 1: exact replacement with word boundaries (longest-first to avoid partial matches)
        var result = text
        let sorted = all.sorted { $0.key.count > $1.key.count }
        for (original, replacement) in sorted {
            let before = result
            // Use word boundary regex to avoid replacing inside other words ("the" won't match "then")
            let escaped = NSRegularExpression.escapedPattern(for: original)
            if let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
            if result != before {
                NSLog("[CorrectionDict] ✅ Exact replacement (%d→%d chars)", original.count, replacement.count)
            }
        }

        // Pass 2: fuzzy matching per word for remaining uncorrected words
        let words = result.components(separatedBy: .whitespaces)
        var changed = false
        let fuzzyResult: [String] = words.map { word in
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)
            guard stripped.count >= 4 else { return word }
            let lower = stripped.lowercased()
            // Skip if this word is already a known replacement value
            if all.values.contains(where: { $0.caseInsensitiveCompare(stripped) == .orderedSame }) {
                return word
            }
            // 2026-05-13 — fuzzy ONLY runs on ASCII words. Russian/Cyrillic
            // source words don't fuzzy-match against English brand keys
            // (false positives caused «новые» → «MetaWhisp» chains because
            // Levenshtein distance 2 was hit on 9-char keys). Whisper writes
            // English brand names in ASCII, so we only need fuzzy there.
            guard stripped.unicodeScalars.allSatisfy({ $0.isASCII }) else {
                return word
            }
            for (key, replacement) in sorted {
                guard key.count >= 4 else { continue }
                let dist = Self.levenshtein(lower, key)
                // Tighter thresholds: 1 for short words (4-7 chars), 2 for long words (8+)
                let maxDist = key.count >= 8 ? 2 : 1
                if dist > 0 && dist <= maxDist {
                    // Preserve surrounding punctuation
                    let leadingPunct = String(word.prefix(while: { $0.isPunctuation }))
                    let trailingCount = word.reversed().prefix(while: { $0.isPunctuation }).count
                    let trailingPunct = trailingCount > 0 ? String(word.suffix(trailingCount)) : ""
                    // Preserve case pattern from original word
                    let cased = Self.preserveCase(from: stripped, to: replacement)
                    changed = true
                    NSLog("[CorrectionDict] 🔍 Fuzzy replacement (%d→%d chars, dist=%d)", stripped.count, cased.count, dist)
                    return leadingPunct + cased + trailingPunct
                }
            }
            return word
        }

        if changed {
            let finalResult = fuzzyResult.joined(separator: " ")
            NSLog("[CorrectionDict] Result: %d chars", finalResult.count)
            return finalResult
        }
        return result
    }

    /// Preserve the case pattern of the source word when applying a replacement.
    /// "HELLO" + "world" → "WORLD", "Hello" + "world" → "World", "hello" + "World" → "world"
    private static func preserveCase(from source: String, to replacement: String) -> String {
        if source == source.uppercased() && source.count > 1 {
            return replacement.uppercased()
        }
        if let first = source.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement.lowercased()
    }

    /// Levenshtein edit distance between two strings.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                curr[j] = a[i-1] == b[j-1]
                    ? prev[j-1]
                    : 1 + min(prev[j], curr[j-1], prev[j-1])
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    /// Learn corrections by comparing original pasted text with user-edited version.
    /// Uses word-level diff: finds the single changed region between texts.
    func learn(original: String, corrected: String) {
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corr = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard orig != corr, !orig.isEmpty, !corr.isEmpty else { return }

        // Don't learn if text changed too dramatically (>2x length change)
        let ratio = Double(corr.count) / Double(orig.count)
        guard ratio > 0.3 && ratio < 3.0 else {
            NSLog("[CorrectionDict] Skipping: text changed too much (ratio=%.1f)", ratio)
            return
        }

        let origWords = orig.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let corrWords = corr.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        // Strip punctuation for comparison (don't learn comma/period changes)
        let stripPunct: (String) -> String = { $0.trimmingCharacters(in: .punctuationCharacters) }

        // Find common prefix (matching words from start)
        var prefixLen = 0
        while prefixLen < origWords.count && prefixLen < corrWords.count
              && stripPunct(origWords[prefixLen]).lowercased() == stripPunct(corrWords[prefixLen]).lowercased() {
            prefixLen += 1
        }

        // Find common suffix (matching words from end)
        var suffixLen = 0
        while suffixLen < origWords.count - prefixLen
              && suffixLen < corrWords.count - prefixLen
              && stripPunct(origWords[origWords.count - 1 - suffixLen]).lowercased()
                  == stripPunct(corrWords[corrWords.count - 1 - suffixLen]).lowercased() {
            suffixLen += 1
        }

        let origChanged = Array(origWords[prefixLen ..< (origWords.count - suffixLen)])
        let corrChanged = Array(corrWords[prefixLen ..< (corrWords.count - suffixLen)])

        // Need both sides to have content (replacement, not pure insertion/deletion)
        guard !origChanged.isEmpty, !corrChanged.isEmpty else { return }

        // Only learn short replacements (1-5 words), not whole sentence rewrites
        guard origChanged.count <= 5, corrChanged.count <= 5 else {
            NSLog("[CorrectionDict] Skipping: too many words changed (%d → %d)", origChanged.count, corrChanged.count)
            return
        }

        let origPhrase = origChanged.joined(separator: " ")
        let corrPhrase = corrChanged.joined(separator: " ")

        // Skip trivial corrections (single char, too long)
        guard origPhrase.count >= 2, corrPhrase.count >= 1, origPhrase.count < 80 else { return }

        // Skip if correction just adds words around original (insertion, not replacement)
        let origLower = origPhrase.lowercased()
        let corrLower = corrPhrase.lowercased()
        if corrLower.contains(origLower) || origLower.contains(corrLower) {
            NSLog("[CorrectionDict] Skipping insertion (%d→%d chars)", origPhrase.count, corrPhrase.count)
            return
        }

        corrections[origLower] = corrPhrase
        save()
        NSLog("[CorrectionDict] ✅ Learned correction (%d→%d chars)", origPhrase.count, corrPhrase.count)
    }

    /// Manually add a correction entry.
    func add(original: String, replacement: String) {
        let key = original.lowercased()
        guard !key.isEmpty, !replacement.isEmpty else { return }
        corrections[key] = replacement
        save()
        NSLog("[CorrectionDict] ✅ Manual add (%d→%d chars)", key.count, replacement.count)
    }

    func remove(_ key: String) {
        corrections.removeValue(forKey: key)
        save()
    }

    func removeAll() {
        corrections.removeAll()
        save()
    }

    // MARK: - Brands

    func addBrand(original: String, replacement: String) {
        let key = original.lowercased()
        guard !key.isEmpty, !replacement.isEmpty else { return }
        brands[key] = replacement
        saveBrands()
    }

    func removeBrand(_ key: String) {
        brands.removeValue(forKey: key)
        saveBrands()
    }

    func removeAllBrands() {
        brands.removeAll()
        saveBrands()
    }

    func loadDefaultBrands() {
        for (k, v) in Self.defaultBrands {
            if brands[k] == nil { brands[k] = v }
        }
        saveBrands()
    }

    // MARK: - Snippets

    func addSnippet(trigger: String, expansion: String) {
        // Use original-case key for snippets so triggers preserve their
        // intended capitalization («my LinkedIn» stays «my LinkedIn» rather
        // than «my linkedin»). `apply(...)` matches with .caseInsensitive
        // regex, so the stored case is purely display.
        let key = trigger.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        // Empty expansion is allowed for PRESETS — user-loaded templates the
        // user fills in later. `allReplacements` filters empties out of the
        // active replacement set, so an unfilled preset is a no-op during
        // transcription (but still visible in the Dictionary UI as a hint).
        snippets[key] = expansion
        saveSnippets()
    }

    func removeSnippet(_ key: String) {
        snippets.removeValue(forKey: key)
        saveSnippets()
    }

    func removeAllSnippets() {
        snippets.removeAll()
        saveSnippets()
    }

    /// Seed snippets with the preset triggers (empty values). Mirrors
    /// `loadDefaultBrands()` — idempotent, doesn't clobber a key already set.
    /// Triggered from the Dictionary UI's «LOAD DEFAULTS» button on the
    /// Snippets tab. Surfaces «moy LinkedIn», «moy email», etc. as
    /// fill-in templates so the user discovers the feature.
    func loadDefaultSnippets() {
        for (k, v) in Self.defaultSnippetPresets {
            if snippets[k] == nil { snippets[k] = v }
        }
        saveSnippets()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        corrections = dict
        NSLog("[CorrectionDict] Loaded %d corrections", dict.count)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadBrands() {
        guard let data = try? Data(contentsOf: brandsURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            loadDefaultBrands()
            return
        }
        brands = dict
        NSLog("[CorrectionDict] Loaded %d brands", dict.count)
    }

    private func saveBrands() {
        guard let data = try? JSONEncoder().encode(brands) else { return }
        try? data.write(to: brandsURL, options: .atomic)
    }

    private func loadSnippets() {
        guard let data = try? Data(contentsOf: snippetsURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        snippets = dict
        NSLog("[CorrectionDict] Loaded %d snippets", dict.count)
    }

    private func saveSnippets() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: snippetsURL, options: .atomic)
    }
}
