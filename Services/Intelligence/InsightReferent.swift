import Foundation

/// Does this comment name anything, and is what it names actually on screen?
///
/// The prompts do not ask the model for a verbatim quote, so there is no quote
/// to check. Pretending otherwise would be theatre. What can be checked is
/// narrower and still catches the failure that matters: a comment naming a
/// person, a time or a file that does not appear anywhere in what was captured.
/// "Anna is waiting for the deck by 16:00" is a useful thing to say when Anna
/// and 16:00 are on the screen, and a fabrication when they are not.
enum InsightReferent {

    /// Anything concrete enough for the user to act on: a clock time, a number,
    /// a proper noun, a filename, a URL.
    static func anchors(in text: String) -> [String] {
        var found: [String] = []
        let patterns = [
            #"\b\d{1,2}:\d{2}\b"#,                      // 16:00
            #"\b\d+(?:[.,]\d+)?\s*(?:%|\$|€|₽)"#,       // 40%, $50
            #"\b[\w-]+\.(?:swift|md|json|pdf|docx?|xlsx?|png|ts|tsx|py|sh|yml|yaml)\b"#,
            #"https?://[^\s]+"#,
            #"\b\d{2,}\b"#,                             // any multi-digit number
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) { found.append(String(text[r])) }
            }
        }
        found.append(contentsOf: properNouns(in: text))
        return found
    }

    /// Capitalized words that are not simply the start of a sentence. Crude on
    /// purpose: it is a hint that something specific is named, not a parser.
    static func properNouns(in text: String) -> [String] {
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        var out: [String] = []
        for (index, raw) in words.enumerated() {
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            guard word.count > 2, index > 0 else { continue }
            guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first)
            else { continue }
            guard word != word.uppercased() || word.count <= 5 else { continue }  // skip SHOUTING
            out.append(word)
        }
        return out
    }

    /// True when the comment points at something rather than gesturing.
    ///
    /// "Something may need your attention" names nothing and cannot be acted
    /// on; a comment like that is the kind that teaches people to ignore the
    /// feature.
    static func namesSomethingSpecific(_ headline: String) -> Bool {
        !anchors(in: headline).isEmpty
    }

    /// The strongest thing the comment names, for checking against what was
    /// actually captured. Prefers times and numbers over names: they are the
    /// hardest to be accidentally right about.
    static func strongestAnchor(_ headline: String) -> String? {
        let all = anchors(in: headline)
        return all.first { $0.contains(":") || $0.rangeOfCharacter(from: .decimalDigits) != nil }
            ?? all.first
    }
}
