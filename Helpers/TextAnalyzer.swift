import Foundation

/// Utilities for analyzing transcription text: filler words, word frequency.
enum TextAnalyzer {

    // MARK: - Filler Words (слова-паразиты)

    static let russianFillers: Set<String> = [
        "ну", "типа", "вот", "короче", "ээ", "ммм", "блин", "ладно",
        "значит", "слушай", "допустим", "собственно", "кстати",
    ]

    /// Multi-word fillers checked as substrings.
    static let russianMultiFillers: [String] = [
        "как бы", "это самое", "так сказать", "в общем", "на самом деле",
        "то есть", "как сказать", "в принципе",
    ]

    /// Count each filler word/phrase in text. Returns sorted by count descending.
    static func fillerWords(in text: String) -> [(word: String, count: Int)] {
        let lower = text.lowercased()
        let words = lower.split(separator: " ").map(String.init)

        var counts: [String: Int] = [:]

        // Single-word fillers
        for word in words {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            if russianFillers.contains(cleaned) {
                counts[cleaned, default: 0] += 1
            }
        }

        // Multi-word fillers
        for phrase in russianMultiFillers {
            var searchRange = lower.startIndex..<lower.endIndex
            var count = 0
            while let range = lower.range(of: phrase, range: searchRange) {
                count += 1
                searchRange = range.upperBound..<lower.endIndex
            }
            if count > 0 { counts[phrase] = count }
        }

        return counts.sorted { $0.value > $1.value }.map { (word: $0.key, count: $0.value) }
    }

    /// Total filler count in text.
    static func fillerCount(in text: String) -> Int {
        fillerWords(in: text).reduce(0) { $0 + $1.count }
    }

    /// Remove filler words and phrases from text, preserving punctuation and spacing.
    static func removeFillersFromText(_ text: String) -> String {
        var result = text

        // Remove multi-word fillers first (order matters for overlapping matches)
        for phrase in russianMultiFillers {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            result = result.replacingOccurrences(
                of: "\\b\(escaped)\\b", with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Remove single-word fillers
        let pattern = russianFillers.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        result = result.replacingOccurrences(
            of: "\\b(\(pattern))\\b", with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Clean up extra whitespace
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Word Frequency

    static let russianStopWords: Set<String> = [
        "и", "в", "на", "с", "что", "а", "не", "я", "это", "он", "она",
        "мы", "они", "но", "по", "к", "из", "у", "за", "от", "до", "о",
        "для", "так", "же", "то", "бы", "вы", "ты", "мне", "все", "его",
        "её", "их", "как", "да", "нет", "ещё", "уже", "тут", "там", "где",
        "the", "a", "an", "is", "are", "was", "were", "be", "to", "of",
        "and", "in", "that", "it", "for", "i", "you", "he", "she", "we",
    ]

    /// Top N words excluding stop words and short words. Sorted by count descending.
    static func wordFrequency(in text: String, top: Int = 10) -> [(word: String, count: Int)] {
        let words = text.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 && !russianStopWords.contains($0) }

        var freq: [String: Int] = [:]
        for word in words { freq[word, default: 0] += 1 }

        return freq.sorted { $0.value > $1.value }
            .prefix(top)
            .map { ($0.key, $0.value) }
    }
}
