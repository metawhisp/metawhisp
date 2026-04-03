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
        "metawhisp": "MetaWhisp", "iphone": "iPhone", "ipad": "iPad",
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
    private var allReplacements: [String: String] {
        var merged = corrections
        for (k, v) in brands { merged[k] = v }
        for (k, v) in snippets { merged[k] = v }
        return merged
    }

    /// Apply all known corrections, brands, and snippets to text.
    /// First pass: exact matching (longest-first). Second pass: fuzzy matching per word (Levenshtein ≤ 2).
    func apply(_ text: String) -> String {
        let all = allReplacements
        guard !all.isEmpty else {
            return text
        }

        NSLog("[CorrectionDict] Applying %d replacements to: '%@'", all.count, String(text.prefix(80)))

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
                NSLog("[CorrectionDict] ✅ Exact: '%@' → '%@'", original, replacement)
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
                    NSLog("[CorrectionDict] 🔍 Fuzzy: '%@' → '%@' (dist=%d, key='%@')", stripped, cased, dist, key)
                    return leadingPunct + cased + trailingPunct
                }
            }
            return word
        }

        if changed {
            let finalResult = fuzzyResult.joined(separator: " ")
            NSLog("[CorrectionDict] Result: '%@'", String(finalResult.prefix(80)))
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
            NSLog("[CorrectionDict] Skipping insertion: '%@' → '%@'", origPhrase, corrPhrase)
            return
        }

        corrections[origLower] = corrPhrase
        save()
        NSLog("[CorrectionDict] ✅ Learned: '%@' → '%@'", origPhrase, corrPhrase)
    }

    /// Manually add a correction entry.
    func add(original: String, replacement: String) {
        let key = original.lowercased()
        guard !key.isEmpty, !replacement.isEmpty else { return }
        corrections[key] = replacement
        save()
        NSLog("[CorrectionDict] ✅ Manual add: '%@' → '%@'", key, replacement)
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
        let key = trigger.lowercased()
        guard !key.isEmpty, !expansion.isEmpty else { return }
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
